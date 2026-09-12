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

public struct RecordOptions {
    public var displayIndex = 0
    public var windowMatch: String?
    /// 収録する矩形領域 (ポイント座標、ディスプレイ左上が原点)。nil ならディスプレイ全体。
    /// ウィンドウ収録 (windowMatch) や音声のみ (wantsVideo = false) とは併用しない
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
    public var fps: Int?
    public var showsCursor = true
    /// 録音セッションに BlackHole マルチ出力デバイスの setup/teardown を紐付ける
    public var autoMonitor = false

    public init() {}
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
    }

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
            guard options.windowMatch == nil else {
                throw KilError.failed("領域指定 (region) はウィンドウ収録とは併用できません")
            }
        }
        let ext = options.wantsVideo ? "mov" : "m4a"
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

        let wantsSCK = options.wantsVideo || options.audioSources.contains(.system)
        if wantsSCK && !Permissions.hasScreenCapture {
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
            guard await Permissions.requestMic() else {
                throw KilError.permission("マイク (入力) の権限がありません")
            }
        }

        // 既存の kilde Monitor (手動で setup されたもの) は勝手に解体しない
        var monitorCreatedByUs = false
        if options.autoMonitor && !MonitorDevice.exists {
            _ = try MonitorDevice.setup()  // BlackHole がなければ deviceNotFound
            monitorCreatedByUs = true
        }

        do {
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
        let captureAudio = options.audioSources.contains(.system)
        if options.wantsVideo || captureAudio {
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = captureAudio
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.showsCursor = options.showsCursor
            if let fps = options.fps, fps > 0 {
                cfg.minimumFrameInterval = CMTime(seconds: 1.0 / Double(fps), preferredTimescale: 600)
            }
            let filter: SCContentFilter
            if let match = options.windowMatch {
                let win = try await DisplayCatalog.resolveWindow(matching: match)
                if options.wantsVideo {
                    cfg.width = Int(win.frame.width)
                    cfg.height = Int(win.frame.height)
                    videoSize = CGSize(width: win.frame.width, height: win.frame.height)
                }
                filter = SCContentFilter(desktopIndependentWindow: win)
            } else {
                let display = try await DisplayCatalog.display(at: options.displayIndex)
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
                        cfg.width = Int(display.width)
                        cfg.height = Int(display.height)
                        videoSize = CGSize(width: display.width, height: display.height)
                    }
                }
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }
            if options.wantsVideo {
                // AVAssetWriter で再圧縮するため非圧縮 BGRA を要求 (SPIKE-NOTES F-D.1)
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
            }
            let mode: ScreenAudioStream.Mode = options.wantsVideo ? .screenAndAudio : .audioOnly
            sck = try ScreenAudioStream(filter: filter, configuration: cfg, mode: mode) { [weak self] sb, type in
                self?.handleSCK(sb, type)
            }
        }

        let w = try MovieWriter(
            url: url,
            fileType: options.wantsVideo ? .mov : .m4a,
            video: options.wantsVideo,
            videoSize: videoSize,
            codec: options.codec,
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

        setState(.armed)
        startDate = Date()
        for m in micStreams { m.start() }
        do {
            try await sck?.start()
        } catch {
            // マイクのみ起動済みのまま失敗するとリソースが残るため後始末する
            for m in micStreams { m.stop() }
            w.cancel()
            throw error
        }
        setState(.recording)

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
            pausedDuration: pausedDuration
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

    /// recording 中 0.5 秒周期で progress イベントを流ぶ (GUI 向け)。
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
