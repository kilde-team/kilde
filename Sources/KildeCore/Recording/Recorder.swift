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
    public var audioSources: [AudioSourceSpec] = [.system]
    public var trackPolicy: AudioTrackPolicy = .mixed
    public var wantsVideo = true
    public var outputURL: URL?
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
public enum RecorderState: String, Equatable, Sendable {
    case idle
    /// 権限確認・デバイス解決・ストリーム構築中
    case preparing
    /// 構築完了・キャプチャ開始直前 (カウントダウン等を挟めるタイミング)
    case armed
    case recording
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

    /// run() 完了後に同じスレッドから読むだけなので、追加のロックは不要
    public private(set) var cleanupWarnings: [String] = []

    public struct Progress: Sendable {
        public let elapsed: TimeInterval
        public let outputURL: URL
        public let outputBytes: Int64
        public let peaks: [String: Float]
        public let videoAppended: Int
        public let audioAppended: [String: Int]
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

    // MARK: イベント駆動 (issue #8)

    /// 状態遷移・進捗・完了・失敗の通知ストリーム。
    /// バッファは新しい方を 16 件だけ保持する — 購読前に流れた progress が古い順に
    /// 捨てられ、consumer 未接続のまま長時間録画してもメモリが膨らまない。
    /// 最後の .completed / .failed は常に最新側に来るため失われない。
    /// start() の前に購読すること (未購録の初期状態は currentState で補間できる)。
    /// 購読側 Task を cancel するとストリーム自体が終端する (再購読はできない)
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

    /// 録画を実行し、完了までブロックする (CLI 互換の同期 API — start() のラッパ)。
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
        let elapsed = Date().timeIntervalSince(startDate)
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
            audioAppended: counters?.audioAppended ?? [:]
        )
    }

    // MARK: - セッション本体

    /// start() から Task 上で実行される一本道のセッション。
    /// すべての失敗を catch して error に遷移させ、どの経路でも完了通知を出す
    private func runSession() async {
        setState(.preparing)
        let result: Result<Summary, Error>
        do {
            result = .success(try await performSession())
        } catch {
            result = .failure(error)
        }
        eventContinuation.finish()
        storeCompletion(result)
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
        let ext = options.wantsVideo ? "mov" : "m4a"
        let url = options.outputURL ?? URL(fileURLWithPath: defaultOutputName(ext: ext))
        outputURL = url

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
        if needsMicPermission && !Permissions.requestMic() {
            throw KilError.permission("マイク (入力) の権限がありません")
        }

        // 既存の kilde Monitor (手動で setup されたもの) は勝手に解体しない
        var monitorCreatedByUs = false
        if options.autoMonitor && !MonitorDevice.exists {
            _ = try MonitorDevice.setup()  // BlackHole がなければ deviceNotFound
            monitorCreatedByUs = true
        }

        do {
            let summary = try await recordAndFinalize(url: url)
            teardownMonitorIfNeeded(monitorCreatedByUs)
            setState(.done)
            eventContinuation.yield(.completed(summary))
            return summary
        } catch {
            // 後始末の失敗で録画本体のエラーと終了コードを上書きしない
            teardownMonitorIfNeeded(monitorCreatedByUs)
            setState(.error)
            // 部分ファイルは「このセッションが writer を作った後」の失敗だけを報告する。
            // writer 生成前に失敗した場合、出力先に既存の無関係ファイルがあっても
            // 部分ファイルとは呼べないため含めない
            let writerCreated = writer != nil
            eventContinuation.yield(
                .failed(Self.asKilError(error), partialFileExists: writerCreated && fileExists(url)))
            throw error
        }
    }

    private func recordAndFinalize(url: URL) async throws -> Summary {
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
                let win = try DisplayCatalog.resolveWindow(matching: match)
                if options.wantsVideo {
                    cfg.width = Int(win.frame.width)
                    cfg.height = Int(win.frame.height)
                    videoSize = CGSize(width: win.frame.width, height: win.frame.height)
                }
                filter = SCContentFilter(desktopIndependentWindow: win)
            } else {
                let display = try DisplayCatalog.display(at: options.displayIndex)
                if options.wantsVideo {
                    cfg.width = Int(display.width)
                    cfg.height = Int(display.height)
                    videoSize = CGSize(width: display.width, height: display.height)
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
            anchor: options.wantsVideo ? .firstVideo : .firstAudio
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
            // この時点で writer は startWriting 済みなので、未完成ファイルを残さないよう破棄する
            w.cancel()
            throw error
        }

        setState(.armed)
        startDate = Date()
        for m in micStreams { m.start() }
        do {
            try sck?.start()
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
        // cancel だけでなく終了まで待つ — sleep 起き直し直後の yield と
        // finalizing 遷移の間にプリエンプション窓があると、progress が
        // .completed より後に届いてイベントの順序が崩れるため
        progressTask.cancel()
        _ = await progressTask.value

        setState(.finalizing)
        sck?.stop()
        for m in micStreams { m.stop() }
        if let mixer {
            // チャンク境界に満たない末尾を含め、残データを吐き切ってから完了する
            for chunk in mixer.flush() {
                w.appendAudio(chunk, label: "mixed")
            }
        }
        try await w.finish()

        return Summary(
            outputURL: url,
            videoAppended: w.videoAppended,
            videoDropped: w.videoDropped,
            audioAppended: w.audioAppended,
            audioDropped: w.audioDropped,
            firstPTSOffsets: w.firstPTSOffsets,
            mixedDecodeFailures: mixer?.decodeFailures ?? 0
        )
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
                guard let self, !Task.isCancelled, self.currentState == .recording else { continue }
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
        guard monitorCreatedByUs, !MonitorDevice.teardown() else { return }
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
