import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

public enum AudioSourceSpec: Equatable {
    case system
    case mic
    case device(String)
}

public enum AudioTrackPolicy: Equatable {
    /// 複数ソースを 1 トラックに合成 (既定 — どのプレイヤーでも全ソース聞こえる)
    case mixed
    /// ソースごとにトラック分離 (編集向け)
    case separate
}

public enum VideoCodecKind: String, CaseIterable {
    case h264
    case hevc
    case prores
}

/// 出力コンテナ (issue #12)。音声のみのモードは従来どおり M4A 固定で、ここには関与しない
public enum ContainerKind: String, CaseIterable {
    case mov
    case mp4

    public var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }

    /// MP4 は ProRes を入れられない (QuickTime コンテナ専用のコーデックのため)
    public func supports(_ codec: VideoCodecKind) -> Bool {
        self == .mov || codec != .prores
    }
}

public struct RecordOptions {
    public var displayIndex = 0
    /// 収録するウィンドウの指定 (title / bundleID / windowID)。空ならディスプレイ収録。
    /// 2 つ以上指定すると、そのウィンドウ群だけを 1 本にまとめて収録する (issue #13)
    public var windowMatches: [String] = []
    /// ディスプレイ収録から除外するアプリの bundleID (issue #13)。
    /// ウィンドウ収録とは併用しない (収録対象を選ぶ指定と除外する指定が矛盾するため)
    public var excludedBundleIDs: [String] = []
    /// 収録する矩形領域 (ポイント座標、ディスプレイ左上が原点)。nil ならディスプレイ全体。
    /// ウィンドウ収録 (windowMatches) や音声のみ (wantsVideo = false) とは併用しない
    public var region: CGRect?
    public var audioSources: [AudioSourceSpec] = [.system]
    public var trackPolicy: AudioTrackPolicy = .mixed
    public var wantsVideo = true
    public var outputURL: URL?
    /// CLI の位置引数 / --output で指定されたパスだけは従来どおり上書きを許可する。
    /// false の既定名は原子的に予約され、既存の録画を保護する。
    public var outputPathIsExplicit = false
    /// 呼び出し側が事前に予約済みの出力 (CLI は表示のために開始前に確定させ、GUI の
    /// makeOptions もこれを渡す)。無い場合は Recorder が outputPathIsExplicit に従って
    /// 予約する — 録画の挙動はどちらの経路でも同じになる
    public var outputReservation: OutputFileReservation?
    public var duration: TimeInterval?
    public var codec: VideoCodecKind = .h264
    /// 映像ありのときの出力コンテナ (issue #12)。音声のみは M4A 固定
    public var container: ContainerKind = .mov
    public var fps: Int?
    public var showsCursor = true
    /// HDR で収録する (issue #16)。macOS 15+ かつ HDR ディスプレイのときだけ有効で、
    /// 満たさない環境では警告を出して SDR に落とす (黙って SDR にすると
    /// 「HDR で録れたつもりのファイル」ができてしまう)。コーデックは HEVC のみ
    public var hdr = false
    /// HDR を出せるディスプレイの ID (issue #16)。**呼び出し側が埋める。**
    /// 判定には `NSScreen` = メインスレッドが要るが、`Recorder` は CLI の同期経路
    /// (`run()` がメインスレッドを塞ぐ) からも呼ばれるため、セッションの中で
    /// MainActor へディスパッチするとデッドロックする。`DisplayHDR.capableDisplayIDs()` を
    /// CLI の起動時 / GUI の MainActor 上で呼んで、その結果をここに載せること。
    ///
    /// **nil は「まだ判定していない」で、空集合 (「判定した結果 HDR 対応が無い」) とは別。**
    /// 同じ値で表すと、呼び出し側の載せ忘れが「黙って SDR で録る」に化ける —
    /// しかも HDR ディスプレイを持つ人にしか再現しないので、まず気づけない。
    /// そのため `--hdr` を指定して nil のときは握り潰さず失敗させる
    public var hdrCapableDisplayIDs: Set<CGDirectDisplayID>?
    /// 録音セッションに BlackHole マルチ出力デバイスの setup/teardown を紐付ける
    public var autoMonitor = false

    public init() {}

    /// ScreenCaptureKit を使う構成か (映像を録るか、システム音声を録るか)。
    ///
    /// **この判定を各所に書き写さない。** 画面収録権限の要否・SCStream の構築・
    /// GUI の開始ガードがすべて同じ条件を見ており、手で揃える前提だと必ずずれる
    /// (issue #72)。GUI が扱う `RecordRequest` にも同名の property があり、
    /// `RecordRequestTests` が両者の一致を縛っている。
    ///
    /// **この判定の内側に処理を足すときは、それが本当に「SCK を使う構成に限られる」のかを
    /// 確認すること。** ユーザーの要求に対する応答 (警告・エラー・フォールバックの通知) は、
    /// たいてい**条件の外**で行う必要がある — 内側に置くと、その構成に入らなかったときに
    /// 要求が黙殺される。issue #16 では HDR 可否の判定をこの条件の内側に置いたため、
    /// `--no-video` かつシステム音声なしの構成で `--hdr` が理由も示されず無視された
    public var usesScreenCapture: Bool {
        wantsVideo || audioSources.contains(.system)
    }
}

/// 録画セッションの状態 (DESIGN.md §4)。
/// idle → preparing → armed → recording → finalizing → done | error の一直線。
/// recording ⇄ paused だけが往復し、paused からも停止 (finalizing) できる。
public enum RecorderState: String, Equatable, Sendable {
    case idle
    /// 権限確認・デバイス解決・ストリーム構築中
    case preparing
    /// 構築完了・キャプチャ開始直前 (カウントダウン等を挟めるタイミング)
    case armed
    case recording
    /// 一時停止中 (issue #11)。サンプルは破棄し、再開時にその区間を
    /// タイムラインから詰めるので、出力ファイルには一時停止区間が残らない。
    /// GUI は events の stateChanged でこの状態を受け取る
    case paused
    /// 停止後のファイナライズ中 (AVAssetWriter の完了待ち)
    case finalizing
    case done
    case error
}

/// Recorder が events ストリームに流す通知 (issue #8)。
/// GUI は状態遷移・進捗・完了・失敗をこのイベントで受け取る。
public enum RecorderEvent: Sendable {
    case stateChanged(RecorderState)
    case progress(Recorder.Progress)
    /// 録画自体は成立したが後始末に問題があった (monitor の既定出力復元失敗等)。
    /// .completed の前に流れる。CLI は同じ状態を cleanupWarnings + 終了コード 1 として
    /// 扱う (DESIGN.md §6) ので、購読側もユーザーに復旧を案内すること
    case cleanupWarning(String)
    case completed(Recorder.Summary)
    /// 失敗。finalizing での失敗 (ディスク満杯等) を含み、
    /// 部分ファイルが出力先に残っているかどうかを添える (DESIGN.md §4)
    case failed(KilError, partialFileExists: Bool)

    /// stateChanged だけに関心がある呼び出し元向けの便宜アクセサ
    public var state: RecorderState? {
        if case .stateChanged(let s) = self { return s }
        return nil
    }
}

/// 録画セッションの指揮 (DESIGN.md §4 RecorderController)
public final class Recorder {

    /// セッション完了後の読み取り専用 (CLI が run() の後に表示する)。
    /// 書き込みはセッション Task 上で行われるが、run() の返却は storeCompletion の
    /// NSCondition 経由でその後に行われるため、ロック無しで読める。
    /// 完了後に追記する経路を足す場合はロックかイベント経由に寄せること
    public private(set) var cleanupWarnings: [String] = []
    /// `--hdr` を指定したが SDR で録ることになった理由 (issue #16)。
    /// 失敗ではないので cleanupWarnings とは別に持ち、Summary に載せて伝える
    private var hdrFallback: String?
    private var hdrPresetDescription: String?
    /// 書き出し側の色タグを切り替える方式。SDR (hdr 要求なし・フォールバック) は nil
    private var hdrModeForWriter: MovieWriter.HDRMode?

    public struct Progress: Sendable {
        /// 録画開始からの経過 (一時停止した区間を含まない — 出力ファイルの長さに対応する)
        public let elapsed: TimeInterval
        public let outputURL: URL
        public let outputBytes: Int64
        public let peaks: [String: Float]
        public let videoAppended: Int
        public let audioAppended: [String: Int]
        /// 一時停止中か (issue #11)
        public let isPaused: Bool
    }

    public struct Summary: Sendable {
        public let outputURL: URL
        public let videoAppended: Int
        public let videoDropped: Int
        public let audioAppended: [String: Int]
        public let audioDropped: [String: Int]
        public let firstPTSOffsets: [String: Double]
        /// ミックスできず破棄したバッファ数 (0 以外なら非対応フォーマットの疑い)
        public let mixedDecodeFailures: Int
        /// 一時停止していた合計時間 (issue #11)。出力ファイルの長さには含まれない
        public let pausedDuration: TimeInterval
        /// `--hdr` を指定したが SDR で録った場合の理由 (issue #16)。nil なら該当なし。
        /// 失敗ではないので cleanupWarnings ではなくここに載せる (終了コードは 0 のまま)
        public let hdrFallback: String?
        /// HDR で録ったときの方式の表示名 (issue #76)。例: "HDR10 (SDR 保護付き)"。
        /// SDR のときと HDR を指定していないときは nil
        public let hdrPreset: String?
    }

    /// 録画が 1 フレームも成立しないまま、準備の途中で停止されたか (issue #56)。
    /// CLI はこれを見て「失敗」ではなく正常終了 (exit 0) として扱う —
    /// Ctrl+C は kilde の正規の停止操作なので、準備中に押しても 0 を返す (DESIGN.md §6)
    public private(set) var cancelledBeforeRecording = false

    private let options: RecordOptions
    private let lock = NSLock()
    private var stopRequested = false
    private var startDate = Date()
    private var outputURL: URL?
    private var writer: MovieWriter?
    private var mixer: AudioMixer?
    private var audioLabels: [String] = []
    private var peaks: [String: Float] = [:]
    /// mixed トラックへの push → append を直列化する (複数コールバックキュー対策)
    private let mixedAppendLock = NSLock()

    /// 一時停止の判定とサンプルの書き込みを 1 つの区間にまとめるゲート (issue #11)。
    /// 判定と書き込みが別々だと、判定を通った直後に pause() が走ったコールバックが
    /// 一時停止中のサンプルを書き、再開後は詰めた PTS と混ざって時刻が逆行する
    private let sampleGate = NSLock()

    // MARK: 一時停止 (issue #11)。すべて lock 保護
    /// 一時停止中か。キャプチャのコールバックはこれを見てサンプルを捨てる
    private var paused = false
    /// 現在の一時停止が始まった時刻 (再開時に区間の長さを測る)
    private var pausedSince: Date?
    /// これまでに一時停止していた合計 (サマリと経過時間の補正に使う)
    private var pausedTotal: TimeInterval = 0

    // MARK: イベント駆動 (issue #8)

    /// 状態遷移・進捗・完了・失敗の通知ストリーム。
    /// バッファは新しい方を 16 件だけ保持する — 購読前に流れた progress や、
    /// consumer が 8 秒以上 drain しない間に溜まった古いイベント (stateChanged を
    /// 含む) は古い順に捨てられうる。失われた状態は currentState で補間すること。
    /// 最後の .completed / .failed は常に最新側に来るため失われない。
    /// start() の前に購読すること。購読側 Task を cancel するとストリーム自体が
    /// 終端する (再購読はできない)
    public let events: AsyncStream<RecorderEvent>
    private let eventContinuation: AsyncStream<RecorderEvent>.Continuation

    /// stop() の要求を非同期セッション本体へ伝える (最新 1 件だけ保持できれば十分)
    private let stopSignal: AsyncStream<Void>
    private let stopSignalContinuation: AsyncStream<Void>.Continuation

    /// 同期 run() のための完了通知。NSCondition にすることで複数の waiter が
    /// 同時に待て、完了時に全員が起こる (semaphore では 2 回目の run() が固まる)
    private let completionCondition = NSCondition()
    private var completionResult: Result<Summary, Error>?

    /// start() / run() の二重実行ガード
    private var sessionLaunched = false

    /// 現在の状態 (遷移は events にも配信される)
    private var state: RecorderState = .idle

    /// 同期 run() ラッパ経由では progress イベントを流さない
    /// (CLI は従来どおり progress() をポーリングするため)。
    /// start() 済みセッションへの後からの run() では並行セッション Task との
    /// 競合を避けるため触らない — lock 下で読み書きする
    private var emitsProgressEvents = true

    public init(options: RecordOptions) {
        self.options = options
        (events, eventContinuation) = AsyncStream.makeStream(
            of: RecorderEvent.self, bufferingPolicy: .bufferingNewest(16))
        (stopSignal, stopSignalContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// 現在の状態
    public var currentState: RecorderState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// 録画を非同期に開始する。即座に返り、経過は events で通知される。
    /// 二重呼び出しは無視される。
    /// セッション Task は self を強参照で捕まえる — start() 後に呼び出し元が参照を
    /// 手放しても「開始したのに何も起きない」ことを避けるため (停止は stop() で明示的に)
    public func start() {
        lock.lock()
        guard !sessionLaunched else { lock.unlock(); return }
        sessionLaunched = true
        lock.unlock()
        Task { await self.runSession() }
    }

    /// 早期停止を要求する (SIGINT / duration と同じ経路)。冪等
    public func stop() {
        lock.lock()
        guard !stopRequested else { lock.unlock(); return }
        stopRequested = true
        lock.unlock()
        stopSignalContinuation.yield()
    }

    /// 停止が要求済みか (準備フェーズの中断判定に使う — issue #56)
    private var isStopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    /// 停止されていなければ `.recording` に入る。**判定と遷移を 1 つのロック区間で行う** —
    /// 分けると「停止を確認した直後・遷移の直前」に `stop()` が割り込む窓ができ、
    /// そのセッションは録画扱いのまま 0 フレームで終わって exit 1 になる
    /// (Ctrl+C は正規の停止なので 0、という §6 の契約に反する)
    private func enterRecordingUnlessStopped() -> Bool {
        lock.lock()
        if stopRequested {
            lock.unlock()
            return false
        }
        state = .recording
        lock.unlock()
        // イベントはロックの外で流す (購読側を待たせない)
        eventContinuation.yield(.stateChanged(.recording))
        return true
    }

    /// 準備フェーズの中断点。停止済みなら後片付けを呼び出し側に任せて抜ける。
    /// `preparing` / `armed` の各ステップの合間に挟むことで、
    /// 「停止を頼んだのに準備が終わるまで止まらない」状態をなくす
    private func checkCancelledDuringPreparation() throws {
        guard isStopRequested else { return }
        cancelledBeforeRecording = true
        throw KilError.failed(Self.cancelledDuringPreparationMessage)
    }

    /// 準備中の停止で投げるメッセージ。CLI / GUI が「失敗ではない」と判別する目印も兼ねる
    public static let cancelledDuringPreparationMessage =
        "録画は開始されませんでした (準備中に停止しました)"

    /// writer を作った後の中断を畳む。開始済みのストリームを止め、出力を消してから抜ける。
    /// **削除に失敗してファイルが残ったときは「正常な停止」にしない** — 部分ファイルを
    /// 残したまま exit 0 にすると、壊れたファイルを残さないという最重要要件と、
    /// CLI 側の失敗検出の両方を壊すため
    private func cancelBeforeRecording(writer w: MovieWriter, url: URL,
                                       sck: ScreenAudioStream?,
                                       micStreams: [MicStream]) async throws -> Never {
        await sck?.stop()
        for m in micStreams { m.stop() }
        w.cancel(removingOutput: true)
        if fileExists(url) {
            throw KilError.failed(
                "停止しましたが、書きかけのファイルを削除できませんでした: \(url.path)")
        }
        cancelledBeforeRecording = true
        throw KilError.failed(Self.cancelledDuringPreparationMessage)
    }

    /// 中断できない処理を停止要求と競走させ、停止が先なら nil を返す。
    /// SCK の列挙や TCC ダイアログは外から止められないので、**結果を捨てて先に進む**
    /// (待ち続けると停止要求に応えられない)。放置したタスクは完了後に破棄される。
    ///
    /// stopSignal ではなくフラグのポーリングで待つ理由: stopSignal は
    /// `waitForStopOrDuration()` が単独で消費する前提の AsyncStream で、
    /// ここで for await すると停止イベントを奪ってしまい、録画中の停止が効かなくなる
    /// (テストから直接叩けるよう internal にしている — セッション経由では
    /// マイク権限の状態に左右されて、この経路を確実に通せないため)
    func awaitOrStop<T: Sendable>(
        _ body: @escaping @Sendable () async -> T,
        onWatcherWaiting: (@Sendable () -> Void)? = nil
    ) async -> T? {
        // **structured (withTaskGroup) では実現できない**: タスクグループはスコープを抜けるときに
        // 未完了の子を暗黙に待つため、`cancelAll()` しても TCC ダイアログの応答まで戻れず、
        // 「待つのをやめる」という目的を果たせない。そこで unstructured な Task で走らせ、
        // 先に結果を出した方を採る
        // **oldest** を保持する — 先に届いた方を採るのが競走の趣旨で、`newest` だと
        // 停止と本体の完了が近接したときに後から届いた方が先着を上書きしてしまう
        // (停止したのに TCC の結果を採って録画を続ける、逆に完了した権限結果を捨てる)
        let (stream, continuation) = AsyncStream.makeStream(
            of: Optional<T>.self, bufferingPolicy: .bufferingOldest(1))
        let work = Task.detached { continuation.yield(await body()) }
        let watcher = Task.detached { [weak self] in
            // `Task.isCancelled` も見る — 見ないと、本体が先に終わったときにこのループが
            // 回り続ける (`try?` が sleep のキャンセル例外を握り潰すため)。
            // 回り続けると待ち側が永久に解放されず、準備フェーズがそこで止まる
            while let self, !self.isStopRequested, !Task.isCancelled {
                // 初回の待機に入ったことをテストに知らせる — 停止と本体完了の順序を
                // 決定的に作るための同期フック (本番コードからは使わない)
                onWatcherWaiting?()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            continuation.yield(nil)
        }
        defer {
            work.cancel()
            watcher.cancel()
            continuation.finish()
        }
        for await value in stream {
            // **採用の直前に停止要求を見直す。** `watcher` は 100ms 周期のポーリングなので、
            // `stop()` がフラグを立ててから yield するまでに最大 100ms の窓がある。
            // その間に `body()` が終わると `work` が先に yield し、`bufferingOldest(1)` は
            // 「先に届いた方」を保持するので**停止要求が負ける** — 準備中キャンセルのはずが
            // 権限エラーになり、終了コードが 0 ではなく 2 になる。
            // ストリームへの到着順ではなく、**停止を要求した事実**で決める
            if isStopRequested { return nil }
            return value
        }
        return nil
    }

    /// 録画を一時停止する (issue #11)。冪等で、recording 以外の状態では何もしない。
    /// 一時停止中に届いたサンプルは破棄され、再開時にその区間をタイムラインから詰めるので、
    /// 出力ファイルには一時停止区間が残らない
    public func pause() {
        // サンプルの受け入れと同じゲートで状態を確定する。ゲートの外で切り替えると、
        // 判定を通過済みのコールバックが一時停止中の絵や音を書き込んでしまう
        sampleGate.lock()
        lock.lock()
        guard state == .recording, !paused else { lock.unlock(); sampleGate.unlock(); return }
        paused = true
        pausedSince = Date()
        state = .paused
        lock.unlock()
        // イベントもゲートの中で流す。外に出すと、pause と resume が短時間に続いたときに
        // 配信順が入れ替わり、購読側が最終状態を取り違える
        eventContinuation.yield(.stateChanged(.paused))
        sampleGate.unlock()
    }

    /// 一時停止から再開する (issue #11)。冪等で、一時停止していなければ何もしない。
    /// 一時停止していた長さぶん、writer の出力 PTS を詰め、mixer のアンカーを進める —
    /// 片方だけだと、出力が一時停止ぶん伸びるか、音声が無音で埋まるかのどちらかになる
    public func resume() {
        // pause() と同じく、サンプルの受け入れを止めた状態でタイムラインを詰めて状態を戻す。
        // ゲートの外で詰めると、その隙間に届いたサンプルが古いアンカー / オフセットで
        // 処理され、mixed トラックに一時停止ぶんの無音が入る
        sampleGate.lock()
        lock.lock()
        // 停止後 (finalizing / done / error) は再開しない。'p' キーと SIGUSR1 の
        // ハンドラはプロセスが終わるまで生きているため、ファイナライズ中に再開されると
        // 書き込み済みより前の PTS を作ったり、完了済みの状態を .recording に戻してしまう
        guard paused, state == .paused else { lock.unlock(); sampleGate.unlock(); return }
        paused = false
        let gap = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        pausedSince = nil
        pausedTotal += gap
        state = .recording
        lock.unlock()
        // writer と mixer のロックはリーフなので、この順序で取っても逆順は生じない
        if gap > 0 {
            writer?.addPauseGap(seconds: gap)
            mixer?.advanceAnchor(by: gap)
        }
        // pause() と同じく、配信順を守るためゲートの中で流す
        eventContinuation.yield(.stateChanged(.recording))
        sampleGate.unlock()
    }

    /// 一時停止したまま停止されたときに、その区間を確定する (停止時に 1 回だけ呼ぶ)。
    /// 確定しないとファイナライズ中も計測し続けて合計が過大になり、
    /// 完了後も isPaused が true のまま残る
    private func finalizePauseIfNeeded() {
        // 排出中も「一時停止中」を維持したままここへ来る。ゲートを取ってから解除することで、
        // 解除の瞬間に走っているコールバックが排出済みのサンプルを書き足すのを防ぐ
        sampleGate.lock(); defer { sampleGate.unlock() }
        lock.lock(); defer { lock.unlock() }
        guard paused else { return }
        paused = false
        pausedTotal += pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        pausedSince = nil
    }

    /// 一時停止中か (CLI のステータス表示用)
    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// 一時停止していた合計 (進行中の一時停止も含む)。
    /// async なセッション本体から安全に読むための同期ヘルパ
    private func pausedDurationSnapshot() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return pausedTotal + (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// 録画を実行し、完了までブロックする (CLI 互換の同期 API — start() のラッパ)。
    /// 呼び出しスレッドをセッション終了まで拘束する (数時間にもなりうる) ので、
    /// GUI はこの API を使わず start() + events 購読を使うこと。
    /// この経路では progress イベントを流さないので、進捗は progress() で取得すること。
    /// 完了後の再呼び出しや、セッション進行中の並行呼び出しも同じ結果を返す
    @discardableResult
    public func run() throws -> Summary {
        // 未起動のときだけ progress 抑制を決める (start() 済みセッションへの後からの
        // run() では、セッション Task が並行して flag を読むため lock 下で判定する)
        lock.lock()
        let notLaunched = !sessionLaunched
        if notLaunched {
            emitsProgressEvents = false
        }
        lock.unlock()
        start()
        completionCondition.lock()
        while completionResult == nil {
            completionCondition.wait()
        }
        let result = completionResult!
        completionCondition.unlock()
        return try result.get()
    }

    /// CLI のステータス表示用 (0.5 秒周期で呼ばれる)
    public func progress() -> Progress? {
        guard let url = outputURL else { return nil }
        let now = Date()
        // 一時停止していた区間は出力ファイルに入らないので、経過時間からも差し引く
        // (ファイルの長さと表示がずれないようにする — issue #11)
        lock.lock()
        let pausedNow = paused
        let pausedSoFar = pausedTotal + (pausedSince.map { now.timeIntervalSince($0) } ?? 0)
        lock.unlock()
        let elapsed = max(0, now.timeIntervalSince(startDate) - pausedSoFar)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
        var pk: [String: Float] = [:]
        if let mixer {
            for label in audioLabels { pk[label] = mixer.peak(label) }
        } else {
            lock.lock(); pk = peaks; lock.unlock()
        }
        // 辞書の同時読み書きを避けるため、ロック下で一貫したスナップショットを取得する
        let counters = writer?.countersSnapshot()
        return Progress(
            elapsed: elapsed,
            outputURL: url,
            outputBytes: Int64(bytes),
            peaks: pk,
            videoAppended: counters?.videoAppended ?? 0,
            audioAppended: counters?.audioAppended ?? [:],
            isPaused: pausedNow
        )
    }

    // MARK: - セッション本体

    /// start() から Task 上で実行される一本道のセッション。
    /// 失敗イベントと error 遷移はここで一律に出す — 権限・monitor セットアップ・
    /// 録画中のどの段階で失敗しても、イベント消費者が .failed を必ず受け取るため
    private func runSession() async {
        setState(.preparing)
        do {
            let summary = try await performSession()
            storeCompletion(.success(summary))
        } catch {
            let partial = writer != nil && fileExists(outputURL)
            // 録画本体が失敗した経路でも monitor 復元の警告は発生し得る —
            // .failed の前に配信して、購読側が復旧を案内できるようにする
            for warning in cleanupWarnings {
                eventContinuation.yield(.cleanupWarning(warning))
            }
            setState(.error)
            eventContinuation.yield(
                .failed(Self.asKilError(error), partialFileExists: partial))
            storeCompletion(.failure(error))
        }
        eventContinuation.finish()
    }

    /// run() の waiter 全員に完了を通知する。同期ヘルパに切り出しているのは、
    /// NSCondition の操作を async コンテキストで直接行うと警告になるため
    /// (待つのは既に結果が出た後の短区間で、長時間のブロックは無い)
    private func storeCompletion(_ result: Result<Summary, Error>) {
        completionCondition.lock()
        completionResult = result
        completionCondition.broadcast()
        completionCondition.unlock()
    }

    private func performSession() async throws -> Summary {
        cleanupWarnings.removeAll()
        // 予約の清掃はこの 1 本の defer で賄う。region/window の入力検証は予約の解決より
        // 前で throw しうるため、関数冒頭から登録する。activeReservation は後段 (注入の
        // 一致確認・自前予約) で差し替わるので、defer の実行時点で実際の予約を見る —
        // 二重登録すると削除失敗時に警告が 2 回出る (書き出し側は消費後 inode が変わり
        // 完成ファイルには触れない)
        var activeReservation = options.outputReservation
        defer {
            if let r = activeReservation, !r.removeIfStillReserved() {
                cleanupWarnings.append("予約した出力ファイルを削除できませんでした: \(r.url.path)")
            }
        }
        // 入力の矛盾は副作用 (権限ダイアログ・monitor の既定出力変更) より前に弾く。
        // CLI でも弾いているが、GUI (M3) や HotkeyRecordingController も同じ RecordOptions を
        // 組み立てるため、ここで止めないと「指定した領域と違う範囲を無警告で録る」ことになる
        if options.region != nil {
            guard options.wantsVideo else {
                throw KilError.failed("領域指定 (region) は音声のみのモードでは使えません")
            }
            guard options.windowMatches.isEmpty else {
                throw KilError.failed("領域指定 (region) はウィンドウ収録とは併用できません")
            }
        }
        // 除外 (excludedBundleIDs) はディスプレイ収録の絞り込みなので、収録対象を選ぶ
        // ウィンドウ収録とは両立しない。region と同じく副作用より前に弾く
        if !options.excludedBundleIDs.isEmpty {
            guard options.wantsVideo else {
                throw KilError.failed("アプリ除外 (exclude-app) は音声のみのモードでは使えません")
            }
            guard options.windowMatches.isEmpty else {
                throw KilError.failed("アプリ除外 (exclude-app) はウィンドウ収録とは併用できません")
            }
        }
        // #12 (MP4 コンテナ) と #59 (出力名予約) の統合: 拡張子はコンテナ種別に従い、
        // 既定名は予約を挟んで確定させる
        let ext = options.wantsVideo ? options.container.rawValue : "m4a"
        let preferredURL = options.outputURL ?? URL(fileURLWithPath: defaultOutputName(ext: ext))
        // 呼び出し側の予約を優先し、無ければ既定名 (非明示) のときここで予約する。
        // 明示パスは従来どおり予約なしの上書き
        let reservation: OutputFileReservation?
        if let injected = options.outputReservation {
            guard injected.url == preferredURL else {
                throw KilError.failed("予約済みの出力と解決された出力が一致しません: \(preferredURL.path)")
            }
            reservation = injected
        } else if options.outputPathIsExplicit {
            reservation = nil
        } else {
            reservation = try OutputFileReservation.reserve(preferredURL: preferredURL)
        }
        let url = reservation?.url ?? preferredURL
        outputURL = url
        // 権限・デバイス解決など writer 構築前のどの失敗経路でも予約ゴミを残さないのは
        // 冒頭の defer (activeReservation) の役割。writer が予約を消費した後は inode が
        // 変わるため、完成中/完成済みファイルには触れない
        activeReservation = reservation

        // 権限ダイアログや monitor の既定出力変更といった**副作用を起こす前**に、
        // 既に停止が要求されていないか確かめる (issue #56)
        try checkCancelledDuringPreparation()

        if options.usesScreenCapture && !Permissions.hasScreenCapture {
            throw KilError.permission(
                "画面収録の権限がありません。`kilde doctor` を実行して許可 → 再実行してください"
            )
        }
        let needsMicPermission = options.audioSources.contains { source in
            if case .mic = source { return true }
            if case .device = source { return true }
            return false
        }
        // async 版を使う — TCC ダイアログの応答待ちで協調プールのスレッドを塞がないため (issue #35)。
        // `a && await b` は && の autoclosure 内で await できないので guard に分けている
        if needsMicPermission {
            // TCC ダイアログはこちらからは閉じられないので、停止要求と競走させて
            // 「待つのをやめる」ことで応答する (issue #56)。ダイアログは画面に残るが、
            // ユーザーが後で許可すれば次回の録画で使われる
            guard let granted = await awaitOrStop({ await Permissions.requestMic() }) else {
                try checkCancelledDuringPreparation()
                throw KilError.failed(Self.cancelledDuringPreparationMessage)
            }
            guard granted else {
                throw KilError.permission("マイク (入力) の権限がありません")
            }
        }

        // 既定出力を書き換える前にもう一度確かめる — ここを過ぎると teardown が要る
        try checkCancelledDuringPreparation()

        // 既存の kilde Monitor (手動で setup されたもの) は勝手に解体しない
        var monitorCreatedByUs = false
        if options.autoMonitor && !MonitorDevice.exists {
            _ = try MonitorDevice.setup()  // BlackHole がなければ deviceNotFound
            monitorCreatedByUs = true
        }

        do {
            // monitor の setup 中に停止されていたら、ここで抜けて catch 側の
            // teardownMonitorIfNeeded に既定出力を戻させる
            try checkCancelledDuringPreparation()
            let summary = try await recordAndFinalize(url: url, reservation: reservation)
            teardownMonitorIfNeeded(monitorCreatedByUs)
            // 復元失敗は録画の失敗ではないが、購読側が気づけないと既定出力が
            // kilde Monitor のまま残る — 完了の前に警告イベントで伝える
            for warning in cleanupWarnings {
                eventContinuation.yield(.cleanupWarning(warning))
            }
            setState(.done)
            eventContinuation.yield(.completed(summary))
            return summary
        } catch {
            // 後始末の失敗で録画本体のエラーと終了コードを上書きしない。
            // 失敗イベントと error 遷移は runSession の収束点で出す
            teardownMonitorIfNeeded(monitorCreatedByUs)
            throw error
        }
    }

    private func recordAndFinalize(url: URL, reservation: OutputFileReservation?) async throws -> Summary {
        audioLabels = try labeledSources().map { $0.label }
        let useMixer = options.trackPolicy == .mixed && options.audioSources.count > 1

        // SCStream (映像またはシステム音声が必要な場合)
        var sck: ScreenAudioStream?
        var videoSize: CGSize?
        // capturesAudio の設定にも使うので、条件とは別に残す
        let captureAudio = options.audioSources.contains(.system)
        if options.usesScreenCapture {
            // 収録対象を先に解決する — HDR 可否は「実際にどの画面に写るか」で決まるので、
            // ウィンドウ収録では --display ではなくそのウィンドウが載っている画面を見る。
            // 複数ウィンドウ (issue #13) はディスプレイ座標系へ合成するので、
            // 単一ウィンドウと違って合成先ディスプレイの解決が要る
            let resolvedWindows: [SCWindow]
            let resolvedDisplay: SCDisplay?
            if !options.windowMatches.isEmpty {
                resolvedWindows = try await DisplayCatalog.resolveWindows(matching: options.windowMatches)
                resolvedDisplay = resolvedWindows.count == 1
                    ? nil   // desktopIndependentWindow で切り出すのでディスプレイは要らない
                    : try await DisplayCatalog.display(at: options.displayIndex)
            } else {
                resolvedWindows = []
                resolvedDisplay = try await DisplayCatalog.display(at: options.displayIndex)
            }
            // HDR 可否はここで 1 回だけ決めて持ち回す。都度評価すると SCShareableContent を
            // 引き直すことになり、ストリーム側と書き出し側で答えが割れうる (issue #16)
            let targetDisplayID: CGDirectDisplayID?
            if resolvedWindows.count == 1, let soleWindow = resolvedWindows.first {
                // 単一ウィンドウはそのウィンドウが最も大きく重なっている画面で判定する
                targetDisplayID = displayID(containing: soleWindow.frame)
            } else {
                // 複数ウィンドウは合成先、ディスプレイ収録はその画面
                targetDisplayID = resolvedDisplay?.displayID
            }
            let hdr = try hdrDecision(targetDisplayID: targetDisplayID)
            hdrPresetDescription = hdr.presetDescription
            hdrModeForWriter = hdr.mode
            // HDR を指定したのに SDR へ落ちたときは、必ず理由を伝える。黙って落とすと
            // 「HDR で録れたつもりのファイル」ができ、再生して初めて気づくことになる。
            // ただし cleanupWarnings には載せない — あれは「録画は成立したが後始末に失敗した」
            // 印で、CLI が終了コード 1 に変換する (DESIGN.md §6)。SDR へのフォールバックは
            // 録画自体は完全に成功しているので、Summary に載せて 0 のまま伝える
            hdrFallback = hdr.fallbackReason
            // HDR のときはプリセットが作った configuration をそのまま土台にする
            // (pixelFormat / colorSpace / colorMatrix が整合した組で入っている)。
            // init(preset:) は macOS 15+ だが、mode が nil (SDR) のときは
            // availability の外でも素の SCStreamConfiguration() を使う
            let cfg: SCStreamConfiguration
            if #available(macOS 15.0, *) {
                if let prepared = hdr.configuration {
                    cfg = prepared
                } else if hdr.isHDR {
                    // mode が HDR なのに configuration が作れない = hdrDecision の OS 分岐と
                    // ここで食い違った (プログラミングエラー)。黙って SDR 化すると
                    // 「HDR と表示された SDR ファイル」ができるので失敗させる
                    throw KilError.failed("HDR 方式 (\(hdr.presetDescription ?? "?"))の構築に失敗しました")
                } else {
                    cfg = SCStreamConfiguration()
                }
            } else {
                cfg = SCStreamConfiguration()
            }
            cfg.capturesAudio = captureAudio
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.showsCursor = options.showsCursor
            if let fps = options.fps, fps > 0 {
                cfg.minimumFrameInterval = CMTime(seconds: 1.0 / Double(fps), preferredTimescale: 600)
            }
            let filter: SCContentFilter
            if !resolvedWindows.isEmpty {
                // 解決は冒頭で済ませてある (HDR 可否の判定に「どの画面に写るか」が要るため)。
                // ここで引き直すと SCShareableContent を二重に列挙することになる
                let windows = resolvedWindows
                if let win = windows.first, windows.count == 1 {
                    if options.wantsVideo {
                        // H.264 / HEVC では偶数へ丸める (420v の 4:2:0 制約。ProRes は丸めない —
                        // captureSize を参照)。ウィンドウは 1 ポイント単位でリサイズできるので
                        // 普通に奇数になる (issue #15)
                        let (w, h) = Self.captureSize(win.frame.size, codec: options.codec)
                        guard w >= 2, h >= 2 else {
                            throw KilError.failed(
                                "ウィンドウが小さすぎて収録できません "
                                + "(\(Int(win.frame.width))x\(Int(win.frame.height))、2x2 以上が必要)")
                        }
                        cfg.width = w
                        cfg.height = h
                        videoSize = CGSize(width: w, height: h)
                    }
                    filter = SCContentFilter(desktopIndependentWindow: win)
                } else {
                    // 複数ウィンドウはディスプレイ座標系のまま合成される (ウィンドウごとに
                    // 切り出されるわけではない) ので、出力はディスプレイ全体の大きさになる。
                    // 対象外の領域は黒で埋まる。合成先のディスプレイも冒頭で解決済み
                    let display = resolvedDisplay!
                    // 別のディスプレイにあるウィンドウを混ぜると、合成先の座標系の外に出て
                    // 黙って黒く消える。録画を見返すまで気づけないのでここで止める
                    let bounds = CGDisplayBounds(display.displayID)
                    let offDisplay = windows.filter { !bounds.intersects($0.frame) }
                    if !offDisplay.isEmpty {
                        let names = offDisplay.map { "\"\($0.title ?? "?")\"" }.joined(separator: ", ")
                        throw KilError.failed(
                            "複数ウィンドウの収録では同じディスプレイのウィンドウだけを指定してください "
                            + "(ディスプレイ \(options.displayIndex) の外: \(names)。"
                            + "--display で収録するディスプレイを選べます)")
                    }
                    if options.wantsVideo {
                        // 複数ウィンドウでもディスプレイ全体の大きさになるので、
                        // 単一ウィンドウと同じく偶数へ丸める (issue #15 の 4:2:0 制約)
                        let (w, h) = Self.captureSize(
                            CGSize(width: display.width, height: display.height),
                            codec: options.codec)
                        guard w >= 2, h >= 2 else {
                            throw KilError.failed(
                                "ディスプレイが小さすぎて収録できません (\(display.width)x\(display.height))")
                        }
                        cfg.width = w
                        cfg.height = h
                        videoSize = CGSize(width: w, height: h)
                    }
                    filter = SCContentFilter(display: display, including: windows)
                }
            } else {
                let display = resolvedDisplay!
                if options.wantsVideo {
                    if let region = options.region {
                        // region はポイント座標なので、比較もポイントで行う。
                        // CGDisplayBounds はポイント寸法を返すのでこれを基準にする
                        // (SCDisplay の width/height と取り違えると Retina で範囲判定がずれる)
                        let pointSize = CGDisplayBounds(display.displayID).size
                        let bounds = CGRect(origin: .zero,
                                            size: pointSize.width > 0 && pointSize.height > 0
                                                ? pointSize
                                                : CGSize(width: CGFloat(display.width),
                                                         height: CGFloat(display.height)))
                        guard bounds.contains(region) else {
                            throw KilError.failed(
                                "--region がディスプレイの範囲外です: "
                                + "\(Int(region.origin.x)),\(Int(region.origin.y)),"
                                + "\(Int(region.width)),\(Int(region.height)) "
                                + "(display[\(options.displayIndex)] は \(Int(bounds.width))x\(Int(bounds.height)) ポイント)")
                        }
                        // H.264 は偶数サイズしか扱えないので切り捨てる。sourceRect も同じ大きさに
                        // 揃える — 揃えないと切り捨てたぶんだけ引き伸ばされ、指定と違う絵になる
                        let w = Int(region.width) & ~1
                        let h = Int(region.height) & ~1
                        guard w >= 2, h >= 2 else {
                            throw KilError.failed("--region の幅と高さは 2 ポイント以上にしてください")
                        }
                        cfg.sourceRect = CGRect(x: region.origin.x, y: region.origin.y,
                                                width: CGFloat(w), height: CGFloat(h))
                        cfg.width = w
                        cfg.height = h
                        videoSize = CGSize(width: w, height: h)
                    } else {
                        // ディスプレイ全体も H.264 / HEVC では偶数へ丸める — Retina の
                        // 非整数スケーリングでは奇数ピクセルになりうるため (captureSize を参照)
                        let (w, h) = Self.captureSize(
                            CGSize(width: display.width, height: display.height),
                            codec: options.codec)
                        guard w >= 2, h >= 2 else {
                            throw KilError.failed(
                                "ディスプレイが小さすぎて収録できません (\(display.width)x\(display.height))")
                        }
                        cfg.width = w
                        cfg.height = h
                        videoSize = CGSize(width: w, height: h)
                    }
                }
                let excluded = try await DisplayCatalog.resolveApplications(bundleIDs: options.excludedBundleIDs)
                filter = SCContentFilter(display: display,
                                         excludingApplications: excluded,
                                         exceptingWindows: [])
            }
            // HDR のときは上書きしない — プリセットが pixelFormat / colorSpace /
            // colorMatrix を整合した組で設定済みで、ここで上書きすると
            // 10-bit と PQ の情報が落ちて HDR にならない (issue #16)
            if options.wantsVideo && !hdr.isHDR {
                // 非圧縮のピクセル形式を明示する (既定に任せない — SPIKE-NOTES F-D.1)。
                // 値はコーデックのクロマに合わせる (SPIKE-NOTES F-G)
                switch options.codec {
                case .h264, .hevc:
                    // エンコーダ入力がどのみち 4:2:0 なので、BGRA を渡すと色変換が
                    // 1 回余計に入る。実測で CPU -24%、うち sys はほぼ半減する
                    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                case .prores:
                    // ProRes 422 は 4:2:2。ここで 4:2:0 にするとクロマを半分捨てたまま
                    // エンコーダが 4:2:2 へ戻すだけで、失った情報は復元できない。
                    // 編集用の中間ファイルという用途に反するので BGRA のままにする
                    cfg.pixelFormat = kCVPixelFormatType_32BGRA
                }
            }
            let mode: ScreenAudioStream.Mode = options.wantsVideo ? .screenAndAudio : .audioOnly
            sck = try ScreenAudioStream(filter: filter, configuration: cfg, mode: mode) { [weak self] sb, type in
                self?.handleSCK(sb, type)
            }
        } else {
            // SCK を使わない構成 (マイクや入力デバイスだけの録音) でも HDR 要求は来うる —
            // GUI や HotkeyRecordingController は CLI の validate() を通らず直接
            // RecordOptions を組むため。ここで処理しないと「HDR を指定したのに理由も出ずに
            // SDR になる」ことになり、この機能の「黙って SDR にしない」契約を破る。
            // 収録対象のディスプレイは無いので nil を渡す (映像なしの時点で SDR に落ちる)
            let hdr = try hdrDecision(targetDisplayID: nil)
            hdrPresetDescription = hdr.presetDescription
            hdrModeForWriter = hdr.mode
            hdrFallback = hdr.fallbackReason
        }

        // 対象の解決 (SCShareableContent の列挙) に時間がかかる間に停止されていたら、
        // writer を作る前に抜ける — ここまでならファイルは 1 つも作られていない
        try checkCancelledDuringPreparation()

        let w = try MovieWriter(
            url: url,
            fileType: options.wantsVideo ? options.container.fileType : .m4a,
            video: options.wantsVideo,
            videoSize: videoSize,
            codec: options.codec,
            hdrMode: hdrModeForWriter,
            audioLabels: useMixer ? ["mixed"] : audioLabels,
            anchor: options.wantsVideo ? .firstVideo : .firstAudio,
            outputFilePolicy: reservation.map(MovieWriter.OutputFilePolicy.reserved) ?? .overwrite
        )
        writer = w
        if useMixer {
            let m = AudioMixer()
            for label in audioLabels { m.register(label) }
            mixer = m
        }

        // マイク系ストリーム (SCK より先に開始して開始遅延を吸収 — SPIKE-NOTES F-D.6)
        var micStreams: [MicStream] = []
        do {
            for (label, source) in try labeledSources() {
                switch source {
                case .system:
                    continue
                case .mic:
                    micStreams.append(try MicStream(deviceUniqueID: nil) { [weak self] sb in
                        self?.handleAudio(sb, label: label)
                    })
                case .device(let spec):
                    let dev = try AudioDeviceCatalog.resolveInput(spec)
                    micStreams.append(try MicStream(deviceUniqueID: dev.uid) { [weak self] sb in
                        self?.handleAudio(sb, label: label)
                    })
                }
            }
        } catch {
            // この時点で writer は startWriting 済みなので、書き込みセッションを破棄する。
            // cancelWriting は出力ファイル自体は削除しない (不完全なまま残る) —
            // 残ったファイルは .failed イベントの partialFileExists で呼び出し元に伝わる
            w.cancel()
            throw error
        }

        // ここから先は writer が startWriting 済み。停止するなら必ず cancel して
        // 書きかけのファイルを残さない — 「writer が作られる瞬間は状態イベントから
        // 判別できない」ために GUI の終了猶予を撤廃した (PR #47)、その根本側の対処
        if isStopRequested {
            // micStreams はまだ start() していないので stop() は呼ばない
            try await cancelBeforeRecording(writer: w, url: url, sck: sck, micStreams: [])
        }

        setState(.armed)
        startDate = Date()
        for m in micStreams { m.start() }
        do {
            try await sck?.start()
        } catch {
            // 停止を要求された後に SCK の起動が失敗した場合は、通常の失敗ではなく
            // 準備中キャンセルとして畳む。この経路を分けないと SCK が起動したまま残り、
            // 出力も削除されない (`w.cancel()` は既定ではファイルを消さない)
            if isStopRequested {
                try await cancelBeforeRecording(writer: w, url: url, sck: sck, micStreams: micStreams)
            }
            // マイクのみ起動済みのまま失敗するとリソースが残るため後始末する
            for m in micStreams { m.stop() }
            w.cancel()
            throw error
        }
        // `.armed` から `.recording` へ入る途中 (mic / SCK の起動中) に停止された場合も、
        // 録画は 1 フレームも成立していないので準備中キャンセルとして畳む。
        // 判定と遷移はロック下で不可分に行う — 分けると、この確認を抜けた直後に stop() が
        // 割り込んだセッションが録画扱いのまま 0 フレームで終わり、exit 1 になる
        guard enterRecordingUnlessStopped() else {
            try await cancelBeforeRecording(writer: w, url: url, sck: sck, micStreams: micStreams)
        }

        // 進捗イベントの定期配信 (同期 run() 経由では無効)
        let progressTask = startProgressEmissionIfNeeded()
        // 停止要求と duration のどちらか早い方を待つ
        await waitForStopOrDuration()
        // 録画経過はこの時点で確定させる — 以降のファイナライズ (SCK の drain、
        // mixer の flush) に時間がかかると elapsed が伸び、短時間録画を誤って
        // 消灯・ロック扱いの案内にしてしまうため
        let recordedElapsed = Date().timeIntervalSince(startDate)
        // cancel だけでなく終了まで待つ — sleep 起き直し直後の yield と
        // finalizing 遷移の間にプリエンプション窓があると、progress が
        // .completed より後に届いてイベントの順序が崩れるため
        progressTask.cancel()
        _ = await progressTask.value

        setState(.finalizing)
        // SCK のコールバックを吐き切ってから writer を閉じる (stop() が drain まで待つ)。
        // 一時停止のまま停止された場合、排出中のサンプルも捨てたいので、
        // 一時停止の解除は排出が終わってから行う
        await sck?.stop()
        for m in micStreams { m.stop() }
        finalizePauseIfNeeded()
        if let mixer {
            // チャンク境界に満たない末尾を含め、残データを吐き切ってから完了する
            for chunk in mixer.flush() {
                w.appendAudio(chunk, label: "mixed")
            }
        }
        do {
            try Self.validateVideoFrameCount(
                wantsVideo: options.wantsVideo,
                videoAppended: w.countersSnapshot().videoAppended,
                elapsed: recordedElapsed
            )
        } catch {
            // 映像アンカーが立たない空振りを成功扱いせず、空の出力も残さない。
            // finishWriting ではなく cancel 経路にすることで未成立セッションを閉じる
            w.cancel(removingOutput: true)
            throw error
        }
        try await w.finish()

        // 一時停止したまま停止された場合も、その区間を合計に含める。
        // async 文脈で NSLock を直接触ると警告になるため同期ヘルパ経由で読む (countersSnapshot と同じ)
        let pausedDuration = pausedDurationSnapshot()
        return Summary(
            outputURL: url,
            videoAppended: w.videoAppended,
            videoDropped: w.videoDropped,
            audioAppended: w.audioAppended,
            audioDropped: w.audioDropped,
            firstPTSOffsets: w.firstPTSOffsets,
            mixedDecodeFailures: mixer?.decodeFailures ?? 0,
            pausedDuration: pausedDuration,
            hdrFallback: hdrFallback,
            hdrPreset: hdrPresetDescription
        )
    }

    /// 映像ありモードでは、停止までに 1 フレームも書けなければ録画不成立とする。
    /// 純粋な判定として切り出し、権限や実ディスプレイなしでも回帰テストできるようにする。
    /// 経過時間で案内を分ける — 初回フレーム到着前に止めた短時間録画 (`--duration 0.5s` や
    /// 開始直後の Ctrl+C) は「消灯・ロック」と断定しない
    static func validateVideoFrameCount(wantsVideo: Bool, videoAppended: Int,
                                        elapsed: TimeInterval) throws {
        guard !wantsVideo || videoAppended > 0 else {
            if elapsed < 2 {
                throw KilError.failed(
                    "録画が短すぎて映像を 1 フレームも取得できませんでした (経過 \(String(format: "%.1f", elapsed)) 秒)。もう少し長い時間を指定してください"
                )
            }
            throw KilError.failed(
                "録画が 1 フレームも取得できませんでした — ディスプレイの消灯・ロック中に開始した可能性があります。画面を表示した状態で再実行してください"
            )
        }
    }

    /// HDR 収録の可否を 1 回だけ決めた結果 (issue #16 / #76)。
    /// `mode` が nil なら SDR で録る。`fallbackReason` が入っていれば、
    /// 「HDR を求められたが応えられなかった」ので必ず利用者に伝える
    private struct HDRDecision {
        /// HDR の方式。nil なら SDR (要求なしまたはフォールバック)。
        /// isHDR / configuration / presetDescription はすべてここから導く —
        /// 並列で持つと HDR 側の 2 箇所で食い違ったときに「タグは HDR10 なのに
        /// 色は P3」のような混在が黙って通ってしまうため
        let mode: MovieWriter.HDRMode?
        let fallbackReason: String?

        static let sdr = HDRDecision(mode: nil, fallbackReason: nil)

        /// SDR に落ちる理由つきの結果。`--hdr` を求められたのに応えられなかった場合に使う
        static func fallback(_ reason: String) -> HDRDecision {
            HDRDecision(mode: nil, fallbackReason: reason)
        }

        var isHDR: Bool { mode != nil }
        var presetDescription: String? {
            switch mode {
            case .hdr10: return "HDR10 (SDR 保護付き)"
            case .streamLocalDisplay: return "HDR (Stream Local Display)"
            case nil: return nil
            }
        }
        /// プリセットが作った configuration。SDR は nil (呼び出し側が素の SCStreamConfiguration を使う)。
        /// hdrDecision は OS を確認してから mode を作るため、ここに来る mode は
        /// 実行 OS で使えるものに限られる — それでも API の可用性はコンパイラが
        /// 保証しないので一元化の価値を残しつつ availability を付ける
        @available(macOS 15.0, *)
        var configuration: SCStreamConfiguration? {
            switch mode {
            case .hdr10:
                // hdrDecision は macOS 26+ でのみ .hdr10 を作るため、ここに .hdr10 が
                // 来るのに 26 未満という組み合わせは論理矛盾 (プログラミングエラー)。
                // 黙って Stream Local Display に置き換えると「HDR10 と表示された P3 の
                // ファイル」ができるので、要求どおりにできないなら失敗させる
                guard #available(macOS 26.0, *) else {
                    return nil
                }
                return SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10)
            case .streamLocalDisplay:
                return SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            case nil:
                return nil
            }
        }
    }

    /// HDR で録れるかを判定し、方式 (mode) を 1 つに決める (issue #16 / #76)。
    ///
    /// **セッション開始時に 1 回だけ呼ぶこと。** 判定のたびに `SCShareableContent` を引くと
    /// 結果が食い違いうる。ストリーム側と書き出し側で答えが割れると、たとえば
    /// 「P3 のバッファに BT.2020 プライマリのタグを付けたファイル」ができてしまい、
    /// まさにこの機能が防ごうとしている「HDR で録れたつもりのファイル」になる。
    ///
    /// 判定材料は 4 つ: 映像を録るか / macOS 15 以上か / **解決後の**コーデックが HEVC か /
    /// 収録対象が写るディスプレイが HDR を出せるか。コーデックを CLI 引数ではなく
    /// 解決後の値で見るのは、`--codec` 省略時や設定ファイル由来でも同じ契約を守るため
    /// (`performSession()` 冒頭の region チェックと同じ理由)
    private func hdrDecision(targetDisplayID: CGDirectDisplayID?) throws -> HDRDecision {
        // --hdr を指定していなければ判定自体が不要。hdrCapableDisplayIDs が未設定でも
        // ここで抜けるので、HDR を使わない呼び出し側 (GUI・単体テスト) は載せなくてよい
        guard options.hdr else { return .sdr }
        guard options.wantsVideo else {
            return .fallback("HDR の指定は音声のみのモードでは効きません。SDR で録画します")
        }
        // 未判定 (nil) を空集合と同じ「対応ディスプレイが無い」に倒すと、呼び出し側の
        // 載せ忘れが「黙って SDR で録る」に化ける。しかも HDR ディスプレイを持つ人しか
        // 遭遇せず、警告文は「ディスプレイが非対応」と嘘ではないが原因を指さない。
        // プログラミングエラーなので握り潰さず失敗させる
        guard let capableDisplays = options.hdrCapableDisplayIDs else {
            throw KilError.failed(
                "HDR 可否が判定されていません (RecordOptions.hdrCapableDisplayIDs が未設定)。"
                + "DisplayHDR.capableDisplayIDs() をメインスレッドで呼び、その結果を設定してください")
        }
        guard options.codec == .hevc else {
            return .fallback(
                "HDR は HEVC でのみ書き出せます (現在のコーデック: \(options.codec.rawValue))。"
                + "SDR で録画します — --codec hevc を指定するか、設定ファイルの codec を hevc にしてください")
        }
        guard #available(macOS 15.0, *) else {
            return .fallback("HDR 収録は macOS 15 以降でのみ使えます。SDR で録画します")
        }
        guard displaySupportsHDR(targetDisplayID, capableDisplays: capableDisplays) else {
            return .fallback(
                "収録対象のディスプレイが HDR に対応していないため SDR で録画します"
                + " (HDR には HDR 対応ディスプレイが必要です)")
        }
        // captureDynamicRange / pixelFormat / colorSpace / colorMatrix を自分で組み合わせるのは
        // 間違えやすいので、Apple が「これなら HDR になる」と保証している組を使う。
        //
        // macOS 26 は録画向けの HDR10 プリセット (SDR 範囲の見え方を保ち、HDR10 メタデータが
        // 付く) を使う。CI の SDK の壁は PR #81 でランナーを macos-26 に上げて解消済み。
        // 15 では引き続き Stream Local Display (メタデータ無し・見た目は SDR 側に寄る)
        if #available(macOS 26.0, *) {
            return HDRDecision(mode: .hdr10, fallbackReason: nil)
        }
        return HDRDecision(mode: .streamLocalDisplay, fallbackReason: nil)
    }

    /// 指定したディスプレイが HDR を出せるか。
    ///
    /// **判定そのものは呼び出し側が済ませている** (`DisplayHDR.capableDisplayIDs()`)。
    /// ここで `NSScreen` を読まないのは、それがメインスレッドを要求する一方、
    /// `Recorder` は CLI の同期経路 (`run()` がメインスレッドを塞ぐ) からも呼ばれるためで、
    /// セッションの中で MainActor へディスパッチするとデッドロックする。
    /// **`KildeCore.Recorder` は MainActor を要求しない** (CLAUDE.md §6)。
    ///
    /// **ID が分からないときは false を返す** — 「最初の画面」で代用すると、
    /// マルチディスプレイで収録対象と違う画面を見て判定してしまう
    private func displaySupportsHDR(_ displayID: CGDirectDisplayID?,
                                    capableDisplays: Set<CGDirectDisplayID>) -> Bool {
        guard let displayID else { return false }
        return capableDisplays.contains(displayID)
    }

    /// ウィンドウが最も大きく重なっているディスプレイ (issue #16)。
    /// ウィンドウ収録では `--display` ではなく「実際に写っている画面」で HDR を判定する。
    /// `CGGetDisplaysWithRect` は CoreGraphics なのでスレッドの制約がない
    /// (`NSScreen` だとメインスレッドが要り、セッションから呼べない)
    private func displayID(containing frame: CGRect) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(frame, 0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetDisplaysWithRect(frame, count, &ids, &count) == .success else { return nil }
        // 重なりが最も大きいものを選ぶ (CGGetDisplaysWithRect は交差する全部を返す)
        return ids.max { a, b in
            let oa = CGDisplayBounds(a).intersection(frame)
            let ob = CGDisplayBounds(b).intersection(frame)
            let areaA = oa.isNull ? 0 : oa.width * oa.height
            let areaB = ob.isNull ? 0 : ob.width * ob.height
            return areaA < areaB
        }
    }

    /// 収録サイズを決める (issue #15)。
    ///
    /// H.264 / HEVC は 420v で受けるので、4:2:0 のクロマ面 (w/2 × h/2) を作るために
    /// 幅・高さとも偶数でなければならない。ウィンドウは 1 ポイント単位でリサイズでき、
    /// ディスプレイも Retina の非整数スケーリングで奇数になりうるので丸める。
    ///
    /// **ProRes は丸めない。** 4:2:2 で BGRA を受けるので偶数制約が無く、丸めると
    /// 奇数サイズのウィンドウで不要に 1px 削ることになる。「ProRes ではクロマを落とさない」
    /// というこの issue の方針に反するため、コーデックで分ける
    private static func captureSize(_ size: CGSize,
                                    codec: VideoCodecKind) -> (width: Int, height: Int) {
        switch codec {
        case .prores: return (Int(size.width), Int(size.height))
        case .h264, .hevc: return (Int(size.width) & ~1, Int(size.height) & ~1)
        }
    }

    /// recording 中 0.5 秒周期で progress イベントを流す (GUI 向け)。
    /// 経過時間・出力サイズ・レベルは progress() と同じ計算経路を使う。
    /// チェックから yield までのわずかな競合窓は残るが、sleep 起き直し後の
    /// isCancelled と recording 状態の二重チェックで実質的に finalizing 以降には流さない
    private func startProgressEmissionIfNeeded() -> Task<Void, Never> {
        lock.lock()
        let emits = emitsProgressEvents
        lock.unlock()
        guard emits else { return Task {} }
        return Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return  // キャンセルされた
                }
                // 一時停止中も流す — 購読側 (GUI) が isPaused とレベルを更新できるように
                guard let self, !Task.isCancelled,
                      self.currentState == .recording || self.currentState == .paused else { continue }
                guard let p = self.progress() else { continue }
                self.eventContinuation.yield(.progress(p))
            }
        }
    }

    /// stop() の要求か options.duration の経過のどちらか早い方を待つ
    private func waitForStopOrDuration() async {
        if let duration = options.duration {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [stopSignal] in
                    for await _ in stopSignal { return }
                }
                group.addTask { await Self.sleepForDuration(duration) }
                await group.next()
                group.cancelAll()
            }
        } else {
            for await _ in stopSignal { return }
        }
    }

    /// duration 分だけ sleep する。極端に大きな値 (parseDuration は 999…s も通す) での
    /// UInt64 変換 trap を避けるため 1 年で飽和させる — 旧実装の DispatchTime 加算が
    /// saturate していた挙動に相当する。trap はキャプチャ開始後に起きると
    /// 未ファイナライズの壊れたファイルを残す (最重要要件) ので許容しない
    private static func sleepForDuration(_ duration: TimeInterval) async {
        let capped = min(max(duration, 0), 31_536_000)  // 1 年 = 365 日 (秒)
        try? await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000))
    }

    private func setState(_ next: RecorderState) {
        lock.lock()
        state = next
        lock.unlock()
        eventContinuation.yield(.stateChanged(next))
    }

    private static func asKilError(_ error: Error) -> KilError {
        error as? KilError ?? .failed(String(describing: error))
    }

    private func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func teardownMonitorIfNeeded(_ monitorCreatedByUs: Bool) {
        guard monitorCreatedByUs else { return }
        // 録画の成否とは独立した後始末なので、失敗は警告に落として録画結果は壊さない
        do {
            if try MonitorDevice.teardown() { return }
        } catch {
            cleanupWarnings.append("\(error)")
            return
        }
        cleanupWarnings.append(
            "既定出力の復元に失敗しました。`kilde audio monitor teardown` を実行してください"
        )
    }

    private func labeledSources() throws -> [(label: String, source: AudioSourceSpec)] {
        var out: [(String, AudioSourceSpec)] = []
        for s in options.audioSources {
            switch s {
            case .system:
                out.append(("system", s))
            case .mic:
                out.append(("mic", s))
            case .device(let spec):
                let dev = try AudioDeviceCatalog.resolveInput(spec)
                out.append(("dev:\(dev.name)", s))
            }
        }
        return out
    }

    private func handleSCK(_ sb: CMSampleBuffer, _ type: SCStreamOutputType) {
        switch type {
        case .screen:
            // 一時停止の判定と書き込みを同じゲートで行う (issue #11)。判定だけを先に済ませると、
            // 直後に pause() が走ったときに一時停止中のフレームが書き込まれ、
            // 再開後に詰めた PTS と混ざって時刻が逆行する
            sampleGate.lock(); defer { sampleGate.unlock() }
            guard !isPaused else { return }
            writer?.appendVideo(sb)
        case .audio:
            handleAudio(sb, label: "system")
        case .microphone:
            break  // SCK 自身のマイク取得は未使用 (AVCapture 経由を使う)
        @unknown default:
            break
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer, label: String) {
        // マイク (AVCapture) からは handleSCK を通らず直接届くので、ここでもゲートを取る
        sampleGate.lock(); defer { sampleGate.unlock() }
        guard !isPaused else { return }
        if let mixer {
            // SCK とマイクは別のコールバックキューから来るため、
            // push → append を直列化して mixed 入力への追加上順を保つ
            mixedAppendLock.lock()
            let chunks = mixer.push(label, sb)
            for chunk in chunks {
                writer?.appendAudio(chunk, label: "mixed")
            }
            mixedAppendLock.unlock()
        } else {
            if let decoded = AudioConversion.decode(sb) {
                lock.lock(); peaks[label] = decoded.peak; lock.unlock()
            }
            writer?.appendAudio(sb, label: label)
        }
    }
}
