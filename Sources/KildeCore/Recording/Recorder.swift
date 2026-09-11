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

/// 録画セッションの指揮 (DESIGN.md §4 RecorderController)
public final class Recorder {

    public struct Progress {
        public let elapsed: TimeInterval
        public let outputURL: URL
        public let outputBytes: Int64
        public let peaks: [String: Float]
        public let videoAppended: Int
        public let audioAppended: [String: Int]
    }

    public struct Summary {
        public let outputURL: URL
        public let videoAppended: Int
        public let videoDropped: Int
        public let audioAppended: [String: Int]
        public let audioDropped: [String: Int]
        public let firstPTSOffsets: [String: Double]
    }

    private let options: RecordOptions
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopRequested = false
    private var startDate = Date()
    private var outputURL: URL?
    private var writer: MovieWriter?
    private var mixer: AudioMixer?
    private var audioLabels: [String] = []
    private var peaks: [String: Float] = [:]

    public init(options: RecordOptions) {
        self.options = options
    }

    /// 早期停止を要求する (SIGINT / duration と同じ経路)
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopRequested else { return }
        stopRequested = true
        stopSemaphore.signal()
    }

    /// 録画を実行し、完了までブロックする
    public func run() throws -> Summary {
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
            let summary = try runRecording(url: url)
            if monitorCreatedByUs { _ = MonitorDevice.teardown() }
            return summary
        } catch {
            if monitorCreatedByUs { _ = MonitorDevice.teardown() }
            throw error
        }
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

    // MARK: - 内部

    private func runRecording(url: URL) throws -> Summary {
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

        startDate = Date()
        for m in micStreams { m.start() }
        try sck?.start()

        let timeout: DispatchTime = options.duration.map { .now() + $0 } ?? .distantFuture
        _ = stopSemaphore.wait(timeout: timeout)

        sck?.stop()
        for m in micStreams { m.stop() }
        try awaitSync { try await w.finish() }

        return Summary(
            outputURL: url,
            videoAppended: w.videoAppended,
            videoDropped: w.videoDropped,
            audioAppended: w.audioAppended,
            audioDropped: w.audioDropped,
            firstPTSOffsets: w.firstPTSOffsets
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
            for chunk in mixer.push(label, sb) {
                writer?.appendAudio(chunk, label: "mixed")
            }
        } else {
            if let decoded = AudioConversion.decode(sb) {
                lock.lock(); peaks[label] = decoded.peak; lock.unlock()
            }
            writer?.appendAudio(sb, label: label)
        }
    }
}
