import Foundation
import KildeCore
import os

/// 録画後の文字起こしの実行と状態の持ち主 (issue #146)。
///
/// AppDelegate が 1 つだけ持つ (RecordingController と同じ持ち主 — CLAUDE.md §5-3)。
/// 進捗を見るために開いたパネルを閉じた瞬間に処理が死ぬのは «閉じても録画が続く»
/// (issue #18) と同じ事故なので、寿命をビュー (NSPopover の contentViewController)
/// に結び付けない。パネルを閉じても文字起こしは完了まで続く。
///
/// 録画完了 (`RecordingController.Phase.finished`) を AppDelegate が受けて
/// enqueue() する。実行は **1 件ずつ直列** — SpeechTranscriber の文字起こしは
/// 長時間音声で CPU とメモリを大きく使うため並行実行せず、文字起こし中に次の
/// 録画が終わってもキューに積んで順に処理する。**録画は文字起こしの完了を
/// 待たない** — 会議を録り逃す方が大きい問題なので、録画開始の可否に
/// 文字起こしの状態は関与しない。
@MainActor
final class TranscriptionCoordinator: ObservableObject {

    /// 文字起こし 1 件の指示。録画完了時点の選択 (RecordingSetup) を
    /// AppDelegate がスナップショットして作る — 実行までに設定を変えても
    /// «録画したときの設定» で処理する
    struct Job: Identifiable, Equatable {
        let id = UUID()
        /// 元の録画ファイル。サイドカーは TranscriptWriter がこの URL の隣に書く
        let recordingURL: URL
        let format: TranscriptOutputFormat
        /// 録画後の要約 (issue #163)。nil は «要約しない»。非 nil のときは文字起こし後に
        /// 指定テンプレートで要約を生成し、**出力は .md に強制される**
        /// (要約は Markdown の先頭側に載る — TranscriptWriter の契約)。
        /// 録画完了時点の選択 (RecordingSetup) をスナップショットして入れる
        let summaryTemplate: MeetingTemplate?
        /// nil は «端末の言語設定»。実行時に CLI と同じ `.bcp47` 表記へ解決する
        /// (kilde-cli-swift の TranscribeCommand.swift と同じ規約)
        let localeID: String?
        /// 録画の長さ (秒)。利用状況計測 (issue #153) の区分だけに使い、UI には出さない。
        /// nil は «不明» (セルフテストの直接 enqueue など) — 計測のパラメータを省略する。
        /// 値そのものは送らない (UsageAnalytics が区分にしてから送る)
        let recordingDuration: TimeInterval?
    }

    /// 実行 1 件の段階と進捗 (0...1)。
    /// preparingModel の progress 0 は «まだ総サイズが取れていない» ので
    /// UI は不定長表示にする
    enum RunPhase: Equatable {
        case preparingModel(progress: Double)
        case transcribing(progress: Double)
        /// 要約の生成中 (issue #163)。文字起こし完了後に走る
        case summarizing(progress: Double)
    }

    /// 最後の失敗。再試行のためにジョブごと覚える (オフラインでのモデル取得
    /// 失敗は、ネットワークが戻れば同じジョブの再実行で成功する)
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let job: Job
        let message: String
        /// 生のエラー (NSError) 由来の失敗における診断情報 (domain / code / userInfo)。
        /// localizedDescription だけでは «操作を完了できませんでした。（OSStatusエラー-12203）»
        /// のように出自が落ちる (issue #221) ための足場で、UI では選択可能に表示し
        /// バグ報告にそのまま貼れるようにする。**TranscriptionError は nil** —
        /// 説明 (description) を自前で持ち、診断の対象が無いため
        let detail: String?
    }

    /// 最後の完了。«サイドカーを書きました» の表示と «Finder で表示» に使う
    struct Completion: Equatable {
        let job: Job
        let sidecarURL: URL
        /// 要約を生成したときの結果。nil は «要約なし» (トグルオフ)
        let summary: MeetingSummary?
        /// 要約を生成しなかった理由 (Apple Intelligence 無効など)。
        /// **文字起こし自体は成功している**ので失敗にはせず、案内として通知に載せる (issue #163)
        let summaryNote: String?
    }

    @Published private(set) var running: Job?
    @Published private(set) var runPhase: RunPhase?
    @Published private(set) var queue: [Job] = []
    @Published private(set) var lastFailure: Failure?
    @Published private(set) var lastCompletion: Completion?

    /// 実行中または待機中。メニューバー表示の分岐に使う
    var isBusy: Bool { running != nil || !queue.isEmpty }

    private var task: Task<Void, Never>?
    /// 実行の世代。pump が新しいジョブを始めるたびに増える。Task は同一性比較
    /// (===) できないため、cancelAll の hung 観測が «自分が cancel した実行»
    /// か «猶予中に始まった次の実行» かを区別するのに使う
    private var runGeneration = 0
    /// 現在の実行を始めた時刻 (pump で設定)。処理時間の計測 (issue #153) 用。
    /// ContinuousClock — «かかった時間» の区分には単調時計が適する
    /// (Date は NTP 等で跳ねうる)。計測値そのものは UsageAnalytics で区分化し、
    /// 生の秒数は送らない
    private var runStartedAt: ContinuousClock.Instant?

    /// 完了 1 件ごとに呼ばれる (issue #147)。AppDelegate が «文字起こしを保存しました»
    /// 通知 (RecordingNotifier) につなぐためのフック。**@Published の lastCompletion を
    /// Combine で監視しない** — willSet で流れるので sink の場で読む値は前の完了で、
    /// «この呼び出しがどの完了に対応するか» の対応を取るには delayed な間接参照になる。
    /// 1 対 1 のコールバックの方が «完了したら確実に 1 回呼ばれる» 契約になる
    var onCompletion: ((Completion) -> Void)?

    /// 録画完了時に AppDelegate から呼ぶ。実行は pump() が担当し、
    /// 先に走っている文字起こしがあれば待ち行列に入るだけ。
    ///
    /// **同じ録画のジョブが既に実行中・待機中なら捨てる。** «後から文字起こしする»
    /// (issue #147) が加わって、録画完了の自動投入と手動投入が、あるいは手動投入の
    /// 連打が同じ録画を 2 回走らせる経路ができた。TranscriptWriter は上書きせず
    /// 連番退避するため、2 回走ると `kilde-….md` と `kilde-…-2.md` が並び、
    /// «どちらが正しい文字起こしか» 分からなくなる。«同じ録画のジョブは最大 1 件»
    /// に絞る。録画完了の自動投入は新規ファイルなので影響しない
    func enqueue(_ job: Job) {
        guard running?.recordingURL != job.recordingURL,
              !queue.contains(where: { $0.recordingURL == job.recordingURL }) else { return }
        queue.append(job)
        pump()
    }

    /// «後から文字起こしする» ボタン (issue #147) の無効化判定。
    /// 同じ録画のジョブが実行中か待機中なら true — enqueue が捨てるので、
    /// «押せるのに押しても何も起きない» ではなく «押せない» を見せる
    func isQueuedOrRunning(_ recordingURL: URL) -> Bool {
        running?.recordingURL == recordingURL
            || queue.contains { $0.recordingURL == recordingURL }
    }

    /// «中止»。待機中のジョブを捨て、実行中は Task.cancel() で止める。
    /// running/runPhase は execute の catch 経由でクリアされるまで残す —
    /// ここで即 nil にすると «止まっている途中» に UI が «何もしていない» に見え、
    /// 中止が実際に効いたか分からなくなる。
    ///
    /// 例外: エンジンの SpeechAnalyzer 初期化 (prepareSession) はキャンセルの
    /// 通知窓の外で走るため、この初期化中に cancel すると Task は CancellationError
    /// を投げず await で止まり続ける (実測 — エンジンは pin 固定で直せない)。
    /// Task は強制終了できないので、猶予を過ぎても running が同じ Task のまま
    /// 戻らなければ hung とみなして UI 状態だけ手動で戻す。execute の
    /// finish/fail は `running?.id == job.id` の guard で弾かれるため、hung の
    /// Task が後から戻ってきても状態を壊さない
    func cancelAll() {
        queue.removeAll()
        let cancelledGeneration = runGeneration
        let hadRunningTask = task != nil
        task?.cancel()
        guard hadRunningTask else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            // 猶予中に catch 経由で running が空になり、後続ジョブが pump で
            // 始まっていれば世代が進んでいる — 次の実行は触らず何もしない
            guard self.running != nil, self.runGeneration == cancelledGeneration else { return }
            // hung の経路は execute の catch を通らないため、«中止» の計測 (issue #153)
            // をここで送る。通常の中止は fail() が送る — 世代の guard のおかげで
            // 同じ実行から両方が送られることはない
            UsageAnalytics.transcriptionCancelled(
                recordingDuration: self.running?.recordingDuration,
                processingTime: self.takeProcessingTime())
            self.running = nil
            self.runPhase = nil
            self.task = nil
            self.pump()
        }
    }

    /// 最後の失敗ジョブを先頭に戻して再実行する。
    /// 実行中に押されても待ち行列に入るだけで壊れない (insert 後の pump は
    /// running == nil でなければ何もしない)
    func retryLastFailure() {
        guard let job = lastFailure?.job else { return }
        lastFailure = nil
        queue.insert(job, at: 0)
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = job
        runGeneration += 1
        runStartedAt = .now
        // «開始» は «キューに積まれた時点» ではなく «実行に取りかかった時点» を
        // 数える (issue #153)。積まれたまま実行されなかったジョブは開始にも
        // 終了にも数えない — 前の録画が長時間で、後続が処理されないうちに
        // アプリが終わったケースを «完了率 0%» と誤認させないため
        UsageAnalytics.transcriptionStarted(recordingDuration: job.recordingDuration)
        // 最初の進捗が届くまでの仮表示。モデル取得なのか文字起こしなのかは
        // execute が modelAssetStatus の結果で確定させる
        runPhase = .preparingModel(progress: 0)
        execute(job)
    }

    private func execute(_ job: Job) {
        // ロケールの解決は **enqueue 時ではなく実行時** に CLI と同じ
        // `Locale.current.identifier(.bcp47)` で行う (TranscribeCommand.swift と同じ規約)
        let localeID = job.localeID ?? Locale.current.identifier(.bcp47)
        task = Task { [weak self] in
            // この Task は MainActor を引き継ぐので、await の後もメインスレッドで動く
            do {
                // モデル状態を先に確認する — unsupportedLocale を文字起こし本体より
                // 先に分かりやすいエラーにするため (CLI と同じ順序)
                let status = try await Transcriber.modelAssetStatus(localeIdentifier: localeID)
                if !status.installed {
                    // .installed 以外は取得を試みる。**.unknown も未取得扱い** —
                    // エンジンの `installed` 計算プロパティ (TranscriberSync.swift) と
                    // 同じ判断 «取得を試みる側に倒す»
                    switch status {
                    case .unsupported:
                        // installModelAsset も最終的に unsupportedLocale を投げるが、
                        // ここで先に弾くことで «ダウンロードを試みて失敗» を避ける
                        throw TranscriptionError.unsupportedLocale(localeID)
                    default:
                        try await Transcriber.installModelAsset(
                            localeIdentifier: localeID,
                            onProgress: { progress in
                                // onProgress は @Sendable (別スレッド) から呼ばれるため
                                // MainActor へ非同期で転送する。直接触ると競合になる
                                Task { @MainActor in
                                    self?.setPhase(.preparingModel(progress: progress), for: job)
                                }
                            })
                    }
                }
                self?.setPhase(.transcribing(progress: 0), for: job)
                // エンジンの SpeechAnalyzer 初期化は withTaskCancellationHandler
                // の登録前に走り、**この窓で cancel されると中止が届かず
                // CancellationError も投げずに await で止まり続ける** (実測)。
                // cancel 済みの Task が初期化に入るのをここで防ぐ — 初期化
                // 実行中に cancel された場合の残りは cancelAll 側の hung 観測
                // タイムアウトで閉じる
                try Task.checkCancellation()
                let transcriber = Transcriber(localeIdentifier: localeID)
                // speakers: nil — トラック数からエンジン側が自動判定する
                // (1 トラック / 合成 = ラベルなし、2 トラック (separate) = 0: 相手 / 1: 自分)
                let segments = try await transcriber.transcribeWithSpeakers(
                    fileURL: job.recordingURL,
                    onProgress: { progress in
                        Task { @MainActor in
                            self?.setPhase(.transcribing(progress: progress), for: job)
                        }
                    })
                // transcribeWithSpeakers は Task.cancel() を見て CancellationError で
                // 中止するが、キャンセル直後に正常完了して返る狭いレースも排除できない。
                // «中止» したのにサイドカーが書かれる経路を write の直前で閉じる
                try Task.checkCancellation()

                // 要約の生成 (issue #163)。文字起こしの後に、サイドカーの**書き出しの前**に
                // 行う — 失敗・キャンセル時に «要約の無い» 中途半端なファイルを残さないため
                // (エンジンの TranscriptionRun と同じ順序)。
                var summary: MeetingSummary?
                var summaryNote: String?
                if let template = job.summaryTemplate {
                    // Apple Intelligence 無効などの環境では録画・文字起こしを成功させたまま
                    // 要約だけをスキップし、理由を案内として運ぶ (issue #163 «無効な環境での案内»)
                    if let reason = MeetingSummarizer.unsupportedReason {
                        summaryNote = "要約は生成できませんでした (\(reason))"
                    } else {
                        self?.setPhase(.summarizing(progress: 0), for: job)
                        try Task.checkCancellation()
                        summary = try await MeetingSummarizer.summarize(
                            transcript: segments,
                            template: template,
                            onProgress: { progress in
                                Task { @MainActor in
                                    self?.setPhase(.summarizing(progress: progress), for: job)
                                }
                            })
                    }
                }

                // TranscriptWriter.write は **最後に 1 回だけ原子的に書く**
                // (一時ファイル + rename)。キャンセルでここへ届かなければサイドカーは
                // 残らない — «キャンセルで出力ファイルが残らない» の根拠。
                // 要約ありのときは出力を .md に強制する (要約は Markdown の先頭側に載る)
                let outputFormat = job.summaryTemplate != nil ? .markdown : job.format
                let writtenURL = try TranscriptWriter.write(
                    segments, as: outputFormat, besideRecording: job.recordingURL,
                    summary: summary)
                self?.finish(job: job, sidecarURL: writtenURL,
                             summary: summary, summaryNote: summaryNote)
            } catch {
                self?.fail(job: job, error: error)
            }
        }
    }

    /// 進捗を反映する。**自分がまだ実行中のときだけ** — @Sendable の onProgress
    /// からの MainActor 転送は非同期なので、キャンセル後や次ジョブ開始後に古い
    /// 更新が遅れて届く。それが新しいジョブの進捗を上書きしないよう id で確認する
    private func setPhase(_ phase: RunPhase, for job: Job) {
        guard running?.id == job.id else { return }
        runPhase = phase
    }

    private func finish(
        job: Job, sidecarURL: URL, summary: MeetingSummary?, summaryNote: String?
    ) {
        guard running?.id == job.id else { return }
        // 処理時間は状態を戻す前に読む — runStartedAt はこの実行のもの
        let processingTime = takeProcessingTime()
        UsageAnalytics.transcriptionCompleted(
            recordingDuration: job.recordingDuration, processingTime: processingTime)
        running = nil
        runPhase = nil
        task = nil
        // 完了したら前回の失敗表示を消す — このジョブの成功が «回復» の証拠なのに
        // 失敗が出続けると «まだ壊れている» 誤解を招く
        lastFailure = nil
        let completion = Completion(
            job: job, sidecarURL: sidecarURL, summary: summary, summaryNote: summaryNote)
        lastCompletion = completion
        // 通知 (issue #147) は **@Published 更新の後に** 呼ぶ — フック側が
        // coordinator の状態 (isQueuedOrRunning 等) を読んでも整合する順序にする
        onCompletion?(completion)
        pump()
    }

    private func fail(job: Job, error: Error) {
        guard running?.id == job.id else { return }
        let processingTime = takeProcessingTime()
        running = nil
        runPhase = nil
        task = nil
        // キャンセル («中止» / Task.cancel()) は失敗に数えない — ユーザーが意図して
        // 止めた正規の経路であり、«失敗しました» と見せると誤報になる。
        // 中途半端なサイドカーは TranscriptWriter が原子的に書くため残らない
        var cancelled = false
        switch error {
        case is CancellationError:
            cancelled = true
        case let transcriptionError as TranscriptionError:
            if case .cancelled = transcriptionError { cancelled = true }
        default:
            break
        }
        if !cancelled {
            let detail = Self.diagnosticDetail(error, includeUserInfo: true)
            if let detail {
                // «-12203 の出自が分からない» (issue #221) を繰り返さないため、
                // domain / code を統合ログにも残す。Console.app では
                // `log show --predicate 'category == "transcription"'` で追える。
                // **ログに載せるのは domain / code の連鎖まで** — userInfo の値には
                // 録画ファイルのパスが入るおそれがあり、統合ログに public で
                // 書くのは避ける (CWE-532 / CodeRabbit 指摘)。privacy .private にすると
                // 機種内の log show でも <private> に潰れて診断にならないため、
                // 載せる値を絞る。userInfo 付きの全量は UI (選択可能表示) と
                // セルフテスト出力が担う
                Self.logger.error(
                    "transcription failed: \(Self.diagnosticDetail(error, includeUserInfo: false) ?? detail, privacy: .public)")
            }
            lastFailure = Failure(job: job, message: Self.describe(error), detail: detail)
        }
        // «キャンセルは失敗に数えない» (上) と同じ分類で計測のイベントも分ける
        // (issue #153)。失敗に «キャンセル» が混ざると «どこで壊れているか» の
        // 解析が誤る。hung 観測で止まった実行は fail を通らないため
        // cancelAll 側で送る
        if cancelled {
            UsageAnalytics.transcriptionCancelled(
                recordingDuration: job.recordingDuration, processingTime: processingTime)
        } else {
            UsageAnalytics.transcriptionFailed(
                error: error, recordingDuration: job.recordingDuration,
                processingTime: processingTime)
        }
        // 失敗してもキューは続ける — 1 件の失敗で後続の録画の文字起こしまで
        // 落とす理由がない。後続が無ければ pump は何もしない
        pump()
    }

    /// 現在の実行を始めてからの時間 (秒)。計測 (issue #153) 用で、runStartedAt を
    /// 消費する (nil に戻す) — finish / fail / hung 観測のどれか 1 か所でしか
    /// 読めない。nil は «時刻が取れなかった» で、その場合はパラメータを省略する
    private func takeProcessingTime() -> TimeInterval? {
        guard let started = runStartedAt else { return nil }
        runStartedAt = nil
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// エラーを表示用の 1 行にする。TranscriptionError は CustomStringConvertible で
    /// 日本語文言を持つ。AVFoundation 等の生のエラー (NSError) は localizedDescription
    /// だけだと «The operation couldn't be completed…» で終わるので、
    /// 原因を _underlyingError から掘って見せる
    private static func describe(_ error: Error) -> String {
        if let e = error as? TranscriptionError { return e.description }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.localizedDescription
        }
        return nsError.localizedDescription
    }

    /// 文字起こし失敗の統合ログ。subsystem は Debug と Release でバンドル ID が
    /// 分かれている (CLAUDE.md §5-21) ため、実行中の構成そのものを使う
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.takezou621.KildeGUI",
        category: "transcription")

    /// 失敗の診断情報 (issue #221)。生の NSError は localizedDescription だけだと
    /// domain / code が落ちるため、**エラーの連鎖 (_underlyingError) に沿って
    /// domain / code / userInfo を掘って 1 行にする**。TranscriptionError は
    /// description で説明を自前で持つため nil を返す。
    ///
    /// `includeUserInfo: false` は統合ログ用 — domain / code だけを返し、
    /// パスなどが含まれうる userInfo をログに載せない (CodeRabbit 指摘 — CWE-532)。
    /// userInfo の値は打ち切る — ここは UI 表示に載るもので、フレームワークが
    /// 添付する長い文字列をそのまま出すと表示が崩れるため。
    /// **計測 (UsageAnalytics) には載せない** — userInfo にロケール ID やパスが
    /// 入るおそれがあり、計測側は «値は列挙に閉じる» 規約 (UsageAnalytics.errorKind)
    private static func diagnosticDetail(_ error: Error, includeUserInfo: Bool) -> String? {
        if error is TranscriptionError { return nil }
        var parts: [String] = []
        var current: NSError = error as NSError
        // 連鎖は実運用で 2〜3 段。上限は異常な連鎖 (循環は通常あり得ないが) に対する防御
        for _ in 0..<5 {
            var part = "domain=\(current.domain) code=\(current.code)"
            if includeUserInfo {
                let entries = current.userInfo
                    .filter { $0.key != NSUnderlyingErrorKey }  // 連鎖として別に掘るので重複させない
                    .sorted { $0.key < $1.key }
                    .map { key, value in "\(key)=\(trimmed(String(describing: value)))" }
                if !entries.isEmpty {
                    part += " {\(entries.joined(separator: ", "))}"
                }
            }
            parts.append(part)
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else {
                break
            }
            current = underlying
        }
        return parts.joined(separator: " / underlying: ")
    }

    /// 診断 1 値の整形。改行は空白に潰し、長い値は打ち切る (上のコメント参照)
    private static func trimmed(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if flattened.count <= 120 { return flattened }
        return flattened.prefix(120) + "…"
    }
}
