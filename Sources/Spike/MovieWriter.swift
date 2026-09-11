import Foundation
import AVFoundation
import CoreMedia

/// AVAssetWriter ラッパ。
/// - 映像は最初の映像サンプル PTS をセッション開始 (アンカー) にする
/// - 音声のみモードでは最初の音声サンプル PTS をアンカーにする
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
         audioLabels: [String], anchor: Anchor) throws {
        self.url = url
        self.anchor = anchor
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        if video {
            // macOS 26 の AVFoundation は init 時に幅・高さが必須
            guard let size = videoSize else {
                throw SpikeError("video: videoSize が必要")
            }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
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

    // MARK: 追加

    func appendVideo(_ sb: CMSampleBuffer) {
        guard let input = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts) else { return }
        if !sessionStarted {
            startSession(at: pts) // anchor == .firstVideo を想定
        }
        guard sessionStarted, input.isReadyForMoreMediaData else {
            lock.lock(); videoDropped += 1; lock.unlock()
            return
        }
        let fixed = Self.withValidVideoTiming(sb)
        if input.append(fixed) {
            lock.lock()
            videoAppended += 1
            if firstVideoPTS == nil { firstVideoPTS = pts }
            lastVideoPTS = pts
            lock.unlock()
        } else {
            lock.lock(); videoDropped += 1; lock.unlock()
        }
    }

    func appendAudio(_ sb: CMSampleBuffer, label: String) {
        guard let input = audioInputs[label] else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts) else { return }
        if !sessionStarted, anchor == .firstAudio {
            startSession(at: pts)
        }
        guard sessionStarted else {
            lock.lock(); audioDropped[label, default: 0] += 1; lock.unlock()
            return
        }
        if let start = sessionStartTime, CMTimeCompare(pts, start) < 0 {
            // アンカー前の音声はドロップ (カウントは S2 の PTS 計測で別途記録)
            lock.lock(); audioDropped[label, default: 0] += 1; lock.unlock()
            return
        }
        guard input.isReadyForMoreMediaData else {
            lock.lock(); audioDropped[label, default: 0] += 1; lock.unlock()
            return
        }
        if input.append(sb) {
            lock.lock()
            audioAppended[label, default: 0] += 1
            if firstAudioPTS[label] == nil { firstAudioPTS[label] = pts }
            lastAudioPTS[label] = pts
            lock.unlock()
        } else {
            lock.lock(); audioDropped[label, default: 0] += 1; lock.unlock()
        }
    }

    private func startSession(at t: CMTime) {
        guard !sessionStarted else { return }
        sessionStarted = true
        sessionStartTime = t
        writer.startSession(atSourceTime: t)
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

    // MARK: 終了

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
            throw SpikeError("AVAssetWriter 失敗: \(String(describing: writer.error))")
        }
    }

    // MARK: レポート

    private static func s(_ t: CMTime?) -> String {
        guard let t, CMTIME_IS_NUMERIC(t) else { return "-" }
        return String(format: "%.3fs", t.seconds)
    }

    func reportLines() -> [String] {
        var lines: [String] = []
        if videoInput != nil {
            lines.append("video: appended=\(videoAppended) dropped=\(videoDropped) first=\(Self.s(firstVideoPTS)) last=\(Self.s(lastVideoPTS))")
        }
        for (label, _) in audioInputs {
            let n = audioAppended[label] ?? 0
            let d = audioDropped[label] ?? 0
            let off: String
            if let fa = firstAudioPTS[label], let fv = firstVideoPTS,
               CMTIME_IS_NUMERIC(fa), CMTIME_IS_NUMERIC(fv) {
                off = String(format: " (video との first-PTS 差: %+0.3fs)", fa.seconds - fv.seconds)
            } else if let fa = firstAudioPTS[label], CMTIME_IS_NUMERIC(fa) {
                off = ""
            } else {
                off = " ← 音声サンプルなし"
            }
            lines.append("audio[\(label)]: appended=\(n) dropped=\(d) first=\(Self.s(firstAudioPTS[label])) last=\(Self.s(lastAudioPTS[label]))\(off)")
        }
        return lines
    }
}
