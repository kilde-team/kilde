import Foundation
import AVFoundation
import CoreMedia

/// 録画ファイルの内容検証 (kilde inspect / 統合テストが使用)
public enum FileInspection {

    public struct AudioStats {
        public let duration: Double
        public let rms: Double
        public let peak: Double
    }

    public struct Report {
        public let videoPresent: Bool
        public let videoSize: CGSize?
        public let duration: Double
        public let audioTracks: [AudioStats]
    }

    public static func report(url: URL) throws -> Report {
        try awaitSync { try await reportAsync(url: url) }
    }

    private static func reportAsync(url: URL) async throws -> Report {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        var videoSize: CGSize?
        if let v = videoTracks.first {
            videoSize = try await v.load(.naturalSize)
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let stats = audioTracks.compactMap { analyzeAudioTrack($0, asset: asset, duration: total.seconds) }
        return Report(
            videoPresent: !videoTracks.isEmpty,
            videoSize: videoSize,
            duration: total.seconds,
            audioTracks: stats
        )
    }

    /// 指定オーディオトラックを PCM にデコードして RMS / peak を測る
    static func analyzeAudioTrack(_ track: AVAssetTrack, asset: AVAsset, duration: Double) -> AudioStats? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum = 0.0, count = 0, peak = 0.0
        while let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            guard len > 0 else { continue }
            var floats = [Float](repeating: 0, count: len / MemoryLayout<Float>.size)
            let ok = floats.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: ptr.baseAddress!) == kCMBlockBufferNoErr
            }
            guard ok else { continue }
            for v in floats {
                let d = Double(v)
                sum += d * d
                count += 1
                peak = max(peak, abs(d))
            }
        }
        let rms = count > 0 ? sqrt(sum / Double(count)) : 0
        return AudioStats(duration: duration, rms: rms, peak: peak)
    }
}
