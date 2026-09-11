import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

/// AVAssetWriter ラッパ。
/// - 映像あり: 最初の映像サンプル PTS をセッション開始 (アンカー) にする
/// - 音声のみ: 最初の音声サンプル PTS をアンカーにする
/// - macOS 26 の AVFoundation は outputSettings に幅・高さが必須 (SPIKE-NOTES F-D.2)
final class MovieWriter {

    enum Anchor { case firstVideo, firstAudio }

    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput?
    let audioInputs: [String: AVAssetWriterInput]
    let anchor: Anchor
    let url: URL

    private let lock = NSLock()
    private(set) var sessionStarted = false
    private var sessionStartTime: CMTime?
    private(set) var videoAppended = 0
    private(set) var videoDropped = 0
    private(set) var audioAppended: [String: Int] = [:]
    private(set) var audioDropped: [String: Int] = [:]
    private(set) var firstVideoPTS: CMTime?
    private(set) var lastVideoPTS: CMTime?
    private(set) var firstAudioPTS: [String: CMTime] = [:]
    private(set) var lastAudioPTS: [String: CMTime] = [:]

    init(url: URL, fileType: AVFileType, video: Bool, videoSize: CGSize?,
         codec: VideoCodecKind, audioLabels: [String], anchor: Anchor) throws {
        self.url = url
        self.anchor = anchor
        // AVAssetWriter は出力先ディレクトリが無くても init / startWriting を失敗させず
        // status が failed になるだけなので、ここで先に弾く。弾かないと「何も録れていない
        // ファイルが無いまま録画成功」扱いになり、セッションも停止待ちで迷子になる
        let dir = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            throw KilError.failed("出力先ディレクトリが存在しません: \(dir.path)")
        }
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        if video {
            guard let size = videoSize else {
                throw KilError.failed("video: サイズが不明です")
            }
            var settings: [String: Any] = [:]
            switch codec {
            case .h264:
                settings[AVVideoCodecKey] = AVVideoCodecType.h264
                settings[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            case .hevc:
                settings[AVVideoCodecKey] = AVVideoCodecType.hevc
                settings[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: 10_000_000,
                ]
            case .prores:
                settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
            }
            settings[AVVideoWidthKey] = Int(size.width)
            settings[AVVideoHeightKey] = Int(size.height)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            v.expectsMediaDataInRealTime = true
            writer.add(v)
            videoInput = v
        } else {
            videoInput = nil
        }

        var inputs: [String: AVAssetWriterInput] = [:]
        for label in audioLabels {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            inputs[label] = a
        }
        audioInputs = inputs
        writer.startWriting()
    }

    // MARK: - 追加
    // 複数ソース (SCK / AVCapture) のコールバックキューから並行して呼ばれるため、
    // すべての入口を lock で直列化する。

    func appendVideo(_ sb: CMSampleBuffer) {
        guard let input = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts) else { return }
        lock.lock(); defer { lock.unlock() }
        if !sessionStarted {
            startSessionLocked(at: pts)
        }
        guard sessionStarted, input.isReadyForMoreMediaData else {
            videoDropped += 1
            return
        }
        let fixed = Self.withValidVideoTiming(sb)
        if input.append(fixed) {
            videoAppended += 1
            if firstVideoPTS == nil { firstVideoPTS = pts }
            lastVideoPTS = pts
        } else {
            videoDropped += 1
        }
    }

    func appendAudio(_ sb: CMSampleBuffer, label: String) {
        guard let input = audioInputs[label] else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts) else { return }
        lock.lock(); defer { lock.unlock() }
        if !sessionStarted, anchor == .firstAudio {
            startSessionLocked(at: pts)
        }
        guard sessionStarted else {
            audioDropped[label, default: 0] += 1
            return
        }
        if let start = sessionStartTime, CMTimeCompare(pts, start) < 0 {
            // アンカー前の音声はドロップ (A/V 同期のため)
            audioDropped[label, default: 0] += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            audioDropped[label, default: 0] += 1
            return
        }
        if input.append(sb) {
            audioAppended[label, default: 0] += 1
            if firstAudioPTS[label] == nil { firstAudioPTS[label] = pts }
            lastAudioPTS[label] = pts
        } else {
            audioDropped[label, default: 0] += 1
        }
    }

    private func startSessionLocked(at t: CMTime) {
        guard !sessionStarted else { return }
        sessionStarted = true
        sessionStartTime = t
        writer.startSession(atSourceTime: t)
    }

    /// セッション開始前に中断するときの後始末
    func cancel() {
        writer.cancelWriting()
    }

    /// SCK の映像バッファは duration が無効のことがあるため 1/600s を与え直す
    static func withValidVideoTiming(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        let dur = CMSampleBufferGetDuration(sb)
        if CMTIME_IS_NUMERIC(dur), dur.value > 0 { return sb }
        guard let pb = CMSampleBufferGetImageBuffer(sb),
              let fd = CMSampleBufferGetFormatDescription(sb) else { return sb }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &out
        )
        return status == noErr ? (out ?? sb) : sb
    }

    // MARK: - 終了

    func finish() async throws {
        lock.lock()
        let started = sessionStarted
        lock.unlock()
        guard started else {
            writer.cancelWriting()
            return
        }
        videoInput?.markAsFinished()
        for a in audioInputs.values { a.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed {
            throw KilError.failed("出力ファイルのファイナライズに失敗: \(String(describing: writer.error))")
        }
    }

    // MARK: - レポート

    struct Counters {
        let videoAppended: Int
        let audioAppended: [String: Int]
    }

    /// ロック下で一貫したカウンタのスナップショットを返す (ステータス表示用)。
    /// キャプチャコールバックが並行して更新するため、生プロパティの直接読みはしない。
    func countersSnapshot() -> Counters {
        lock.lock(); defer { lock.unlock() }
        return Counters(videoAppended: videoAppended, audioAppended: audioAppended)
    }

    static func string(_ t: CMTime?) -> String {
        guard let t, CMTIME_IS_NUMERIC(t) else { return "-" }
        return String(format: "%.3fs", t.seconds)
    }

    /// 音声各トラックの「映像 first PTS との差」(A/V 同期の指標)
    var firstPTSOffsets: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard let fv = firstVideoPTS, CMTIME_IS_NUMERIC(fv) else { return [:] }
        var out: [String: Double] = [:]
        for (label, fa) in firstAudioPTS where CMTIME_IS_NUMERIC(fa) {
            out[label] = fa.seconds - fv.seconds
        }
        return out
    }
}
