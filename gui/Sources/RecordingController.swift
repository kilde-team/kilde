import Foundation
import KildeCore

/// 録画セッションの GUI 側の持ち主 (issue #18)。
///
/// AppDelegate が 1 つだけ持ち、ポップオーバー (ContentView) は状態を表示して操作を渡すだけ。
/// Recorder への参照とイベント購読をビューから切り離しているので、ポップオーバーを閉じても
/// 録画は続く (issue #18 の受け入れ条件)。録画そのものは CLI と同じ `Recorder` が行う
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// 権限確認・デバイス解決・ストリーム構築中
        case starting
        case recording
        /// 停止後のファイナライズ中
        case finalizing
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var outputBytes: Int64 = 0
    /// ソースのラベル (system / mic / dev:<名前>) ごとの直近のピーク (0...1)
    @Published private(set) var peaks: [String: Float] = [:]
    @Published private(set) var warnings: [String] = []
    @Published private(set) var outputURL: URL?

    private var recorder: Recorder?
    /// 終了ハンドラと、登録された時点のセッション。
    /// セッションを持たないと、別のセッションのハンドラまで発火させてしまう
    private var sessionEndHandlers: [(session: Recorder?, handler: () -> Void)] = []

    /// 録画完了の通知先 (issue #20)。AppDelegate が生成して渡す。
    /// GUI 専用の機能なので Recorder / KildeCore には持たせない
    var notifier: RecordingNotifier?

    /// 実際に収録が始まった時刻 (.recording に入った瞬間) と、
    /// 停止して finalizing に入った時刻。
    ///
    /// 通知に出す長さを **progress の最終値から取らない**ために持つ — progress は
    /// 0.5 秒周期なので、短い録画では 1 度も届かず `00:00` になってしまう。
    /// 起点を `start()` の呼び出しではなく `.recording` への遷移にしているのは、
    /// **準備フェーズ (権限確認・デバイス解決・ストリーム構築) を長さに混ぜないため** —
    /// 準備は数秒かかることがあり (issue #70)、そのぶん «実収録時間» が水増しされる。
    /// 終点を `.finalizing` にしているのも同じ理由で、writer の finish は収録ではない
    private var recordingStartedAt: Date?
    private var stoppedAt: Date?
    /// 収録開始前に stop() が呼ばれたか (準備中の失敗が自発的な停止かの判定に使う)
    private var stopRequestedDuringPreparation = false

    /// 録画が進行中か。
    ///
    /// **通知の登録待ち (`awaitingNotification`) はここに含めない。** `phase` は
    /// `.finished` / `.failed` を先に立ててから通知を出すので、含めると録画が
    /// 終わっているのに «進行中» の 2 秒ができてしまう — ポップオーバーが
    /// 「準備中…」のまま固まり、停止直後の再開が二重起動ガードに掛かり、
    /// ホットキーが「停止」側へ分岐する。終了を待たせたいのは
    /// `applicationShouldTerminate` だけなので、そこで個別に見る
    var isActive: Bool {
        switch phase {
        case .starting, .recording, .finalizing: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// 通知の登録完了 (またはタイムアウト) を待っている最中か。
    /// アプリ終了の保留判定にだけ使う (`isActive` とは別物)
    @Published private(set) var awaitingNotification = false

    func start(_ options: RecordOptions) {
        guard !isActive else {
            // 既に録画中で options を使わないとき、makeOptions が確保した予約だけが
            // 0 バイトのファイルとして残る — Recorder に渡らないため誰も消さない
            if let r = options.outputReservation, !r.removeIfStillReserved() {
                // この経路は Recorder に渡らないため cleanupWarnings も出ない —
                // 残留予約が黙らないよう stderr に直接出す
                FileHandle.standardError.write(
                    "WARNING: 予約した出力ファイルを削除できませんでした: \(r.url.path)\n"
                        .data(using: .utf8)!)
            }
            return
        }
        recordingStartedAt = nil
        stoppedAt = nil
        stopRequestedDuringPreparation = false
        let recorder = Recorder(options: options)
        self.recorder = recorder
        phase = .starting
        elapsed = 0
        outputBytes = 0
        peaks = [:]
        warnings = []
        outputURL = options.outputURL
        // Recorder.events は start() の前に購読する契約 (購読前のイベントは捨てられうる)。
        // この Task は MainActor を引き継ぐので、handle は常にメインスレッドで走る
        let events = recorder.events
        Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        recorder.start()
    }

    /// 停止を要求する (SIGINT / --duration と同じ経路。冪等)。完了は phase の変化で分かる
    func stop() {
        // 収録が始まる前の停止要求を覚えておく。準備中の失敗が «ユーザーが止めた»
        // のか «デバイス解決などに失敗した» のかは、これが無いと区別できない
        if recordingStartedAt == nil { stopRequestedDuringPreparation = true }
        recorder?.stop()
    }

    /// 経過時間の表示 (mm:ss、1 時間以上は h:mm:ss)。メニューバーとポップオーバーで共用
    nonisolated static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 次のセッション終了 (成功・失敗) で 1 回だけ呼ぶ。アプリ終了時のファイナライズ待ちとセルフテストが使う。
    ///
    /// **登録時点のセッションに紐付ける。** 紐付けないと、旧セッションの通知が
    /// 完了したときに新セッション用のハンドラまで実行してしまい、
    /// `applicationShouldTerminate` が登録した終了応答が**ファイナライズ前に返って
    /// プロセスが落ちる** — 「停止しても必ずファイナライズする」に反する
    func whenSessionEnds(_ handler: @escaping () -> Void) {
        sessionEndHandlers.append((session: recorder, handler: handler))
    }

    private func handle(_ event: RecorderEvent) {
        switch event {
        case .stateChanged(let state):
            switch state {
            case .preparing, .armed: phase = .starting
            // 一時停止中も「録画中」として扱う — GUI にはまだ一時停止を始める操作がなく
            // (issue #11 は CLI のみ)、この状態には入らない。GUI に操作を足すときは
            // Phase に .paused を足して、メニューバーとポップオーバーの表示を分ける
            case .recording, .paused:
                // 収録が実際に始まった瞬間。準備フェーズを長さに含めない
                if recordingStartedAt == nil { recordingStartedAt = Date() }
                phase = .recording
            case .finalizing:
                // 収録が止まった時刻。ここから先 (writer の finish) は録画時間ではない
                if stoppedAt == nil { stoppedAt = Date() }
                phase = .finalizing
            // 結果は .completed / .failed で確定させる (done / error の遷移は必ずその直前に来る)
            case .idle, .done, .error: break
            }
        case .progress(let progress):
            elapsed = progress.elapsed
            outputBytes = progress.outputBytes
            peaks = progress.peaks
        case .cleanupWarning(let warning):
            // monitor の既定出力の復元失敗など。録画は成立しているので結果と一緒に見せる
            warnings.append(warning)
        case .completed(let summary):
            phase = .finished(summary.outputURL)
            // 通知は endSession の前に出す — endSession はハンドラ経由でアプリを
            // 終了させることがあり (applicationShouldTerminate の待ち)、
            // 後に置くと «終了時に録画を止めた» 場合に通知が出ないまま消える
            // .recording に到達しないまま完了することはないはずだが、到達していなければ
            // 収録時間 0 として扱う (準備中に止めた場合など)
            let recorded = recordingStartedAt.map { started in
                max(0, (stoppedAt ?? Date()).timeIntervalSince(started) - summary.pausedDuration)
            } ?? 0
            notifyThenEndSession { [weak self] done in
                self?.notifier?.notifyCompleted(url: summary.outputURL, elapsed: recorded,
                                                bytes: self?.outputBytes ?? 0, completion: done)
            }
        case .failed(let error, let partialFileExists):
            var message = "\(error)"
            if partialFileExists, let outputURL {
                message += "\n不完全なファイルが残っています: \(outputURL.path)"
            }
            phase = .failed(message)
            // ホットキーで他アプリの前面から始めた録画は、失敗しても画面上に何も出ない。
            // 失敗こそ気づかせる必要があるので通知する (issue #20)
            // 準備中に**ユーザーが自分で止めた**場合だけ失敗通知を抑止する。
            // 映像を 1 フレームも書けずに止めた録画は validateVideoFrameCount により
            // .failed になるが、意図的な即停止まで「録画に失敗しました」と通知するのは
            // 誤報になる。ただし **.recording 未到達というだけで抑止してはいけない** —
            // デバイス解決や SCStream 構築の失敗も同じ条件を満たすので、
            // 本物の失敗まで黙殺してしまう (画面を見ていないユーザーには何も届かない)
            // **`.recording` 未到達では判定できない。** `Recorder.stop()` は停止要求を
            // 積むだけでセッションを中断しないので、準備中に押しても Recorder は
            // 準備を続けて `.recording` を通知し、その直後の `waitForStopOrDuration()`
            // で積まれた要求を受け取って止まる。つまり `recordingStartedAt` は必ず
            // 設定される。抑止の根拠は「収録が始まる前に停止を要求したか」だけ
            let suppress = stopRequestedDuringPreparation
            notifyThenEndSession { [weak self] done in
                guard !suppress else { done(); return }
                self?.notifier?.notifyFailed(message: message, completion: done)
            }
        }
    }

    /// 通知の登録が終わってから `endSession()` を呼ぶ。
    ///
    /// `endSession` は `applicationShouldTerminate` のハンドラ経由で
    /// `NSApp.reply(toApplicationShouldTerminate: true)` を呼ぶことがあり、そこで
    /// プロセスが終わる。`UNUserNotificationCenter.add` は非同期 (XPC) なので、
    /// 待たずに進むと**「録画中にアプリを終了」経路で完了通知が消える**。
    ///
    /// 通知が返らないせいでアプリが終われなくなるのは本末転倒なので、短い上限を置く。
    /// 二重に呼ばれても `endSession` は 1 回だけ走らせる
    private func notifyThenEndSession(_ notify: (@escaping () -> Void) -> Void) {
        // タイムアウトは **このセッションにだけ効かせる**。フラグだけで多重呼び出しを
        // 防いでも、2 秒を超えた後に次の録画が始まっていると、遅れて発火した
        // タイムアウトが**新しいセッションの recorder を破棄**してしまう
        // (停止できない録画が残り、sessionEndHandlers も失われる)
        let session = recorder
        var finished = false
        // 通知の登録を待っている間は awaitingNotification を立てる。
        // applicationShouldTerminate がこれを見て終了を保留する (isActive には
        // 含めない — 含めると «録画が終わっているのに進行中» の 2 秒ができる)
        awaitingNotification = true
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            guard let self else { return }
            self.awaitingNotification = false
            if self.recorder === session {
                self.endSession()
            } else {
                // 別のセッションが始まっているので recorder は破棄しない。
                // **このセッションに紐付いたハンドラだけは必ず呼ぶ** — 素通りさせると
                // applicationShouldTerminate が待っている終了応答が永久に来ず
                // アプリが終了できなくなる。一方で全部を呼ぶと、進行中の録画の
                // ファイナライズ待ちまで発火してファイルが壊れる
                self.flushSessionEndHandlers(for: session)
            }
        }
        notify(finish)
        // 通知の登録が 2 秒で返らなければ諦めて先へ進む (ファイナライズは済んでいる)。
        // DispatchQueue.asyncAfter に渡すと Sendable 変換の警告 (Swift 6 でエラー) に
        // なるので、MainActor の Task で待つ
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            finish()
        }
    }

    /// 指定したセッションに紐付く終了ハンドラだけを 1 回実行する。
    /// **他のセッションのハンドラは残す** — 進行中の録画のファイナライズ待ちを
    /// 横から発火させないため
    private func flushSessionEndHandlers(for session: Recorder?) {
        let matched = sessionEndHandlers.filter { $0.session === session }
        sessionEndHandlers.removeAll { $0.session === session }
        matched.forEach { $0.handler() }
    }

    private func endSession() {
        let ended = recorder
        recorder = nil
        peaks = [:]
        flushSessionEndHandlers(for: ended)
    }
}
