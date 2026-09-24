import Foundation
import KildeCore

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
        /// nil は «端末の言語設定»。実行時に CLI と同じ `.bcp47` 表記へ解決する
        /// (kilde-cli-swift の TranscribeCommand.swift と同じ規約)
        let localeID: String?
    }

    /// 実行 1 件の段階と進捗 (0...1)。
    /// preparingModel の progress 0 は «まだ総サイズが取れていない» ので
    /// UI は不定長表示にする
    enum RunPhase: Equatable {
        case preparingModel(progress: Double)
        case transcribing(progress: Double)
    }

    /// 最後の失敗。再試行のためにジョブごと覚える (オフラインでのモデル取得
    /// 失敗は、ネットワークが戻れば同じジョブの再実行で成功する)
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let job: Job
        let message: String
    }

    /// 最後の完了。«サイドカーを書きました» の表示と «Finder で表示» に使う
    struct Completion: Equatable {
        let job: Job
        let sidecarURL: URL
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

    /// 録画完了時に AppDelegate から呼ぶ。実行は pump() が担当し、
    /// 先に走っている文字起こしがあれば待ち行列に入るだけ
    func enqueue(_ job: Job) {
        queue.append(job)
        pump()
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
                // TranscriptWriter.write は **最後に 1 回だけ原子的に書く**
                // (一時ファイル + rename)。キャンセルでここへ届かなければサイドカーは
                // 残らない — «キャンセルで出力ファイルが残らない» の根拠
                let writtenURL = try TranscriptWriter.write(
                    segments, as: job.format, besideRecording: job.recordingURL)
                self?.finish(job: job, sidecarURL: writtenURL)
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

    private func finish(job: Job, sidecarURL: URL) {
        guard running?.id == job.id else { return }
        running = nil
        runPhase = nil
        task = nil
        // 完了したら前回の失敗表示を消す — このジョブの成功が «回復» の証拠なのに
        // 失敗が出続けると «まだ壊れている» 誤解を招く
        lastFailure = nil
        lastCompletion = Completion(job: job, sidecarURL: sidecarURL)
        pump()
    }

    private func fail(job: Job, error: Error) {
        guard running?.id == job.id else { return }
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
            lastFailure = Failure(job: job, message: Self.describe(error))
        }
        // 失敗してもキューは続ける — 1 件の失敗で後続の録画の文字起こしまで
        // 落とす理由がない。後続が無ければ pump は何もしない
        pump()
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
}
