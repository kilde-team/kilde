import Foundation
// report(url:) async は AVAssetTrack / AVAsset を解析用のキューへ渡す。受け渡し後に触るのは
// そのキューだけで並行アクセスはないため、AVFoundation 由来の Sendable 警告は抑止する
@preconcurrency import AVFoundation
import CoreMedia

/// 録画ファイルの内容検証 (kilde inspect / 統合テストが使用)
public enum FileInspection {

    public struct AudioStats {
        public let duration: Double
        public let rms: Double
        public let peak: Double
        /// デコードできた **PCM 値の個数** (issue #108)。
        ///
        /// **フレーム数ではない。** ステレオなら 1 フレームで 2 増える — `rms` を
        /// 求めるときの分母そのもので、意味を変えずに外へ出すためこの定義にしている。
        ///
        /// **なぜ要るか**: `rms` だけでは「サンプルが 1 つも無い」と「完全な無音」が
        /// 区別できない (どちらも 0)。さらに `inspect` は `%.4f` で出すため、
        /// **実測で 0.00005 までが `0.0000` に丸まる** — 無音に近い正常な録音と
        /// 空のファイルが同じ見た目になる。統合テスト T18b は
        /// 「ファイナライズ済みだが中身が無い」出力を弾きたいので、
        /// 丸めの影響を受けないこの値で判定する
        public let valueCount: Int
    }

    public struct Report {
        public let videoPresent: Bool
        public let videoSize: CGSize?
        public let duration: Double
        public let audioTracks: [AudioStats]
    }

    /// 同期版 (CLI の inspect / rec のサマリ用)。内部で awaitSync するので同期コンテキスト専用
    @available(*, noasync, message: "async コンテキストでは try await FileInspection.report(url:) を使ってください")
    public static func report(url: URL) throws -> Report {
        try awaitSync { try await report(url: url) }
    }

    /// async 版 (GUI の録画完了後の検証などで使う — issue #35)
    public static func report(url: URL) async throws -> Report {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        var videoSize: CGSize?
        if let v = videoTracks.first {
            videoSize = try await v.load(.naturalSize)
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        // 解析失敗は「音声トラックなし」と区別するため、エラーを伝播させる
        // 全サンプルのデコードは長い録画だと数秒以上 CPU を使う。async 版を GUI の .task {} 等から
        // 呼んだときに協調プールのスレッドを占有しないよう、専用のキューで回して結果だけを await する
        let seconds = total.seconds
        let stats = try await withCheckedThrowingContinuation { (done: CheckedContinuation<[AudioStats], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result {
                    try audioTracks.map { try analyzeAudioTrack($0, asset: asset, duration: seconds) }
                })
            }
        }
        return Report(
            videoPresent: !videoTracks.isEmpty,
            videoSize: videoSize,
            duration: total.seconds,
            audioTracks: stats
        )
    }

    /// 指定オーディオトラックを PCM にデコードして RMS / peak を測る
    static func analyzeAudioTrack(_ track: AVAssetTrack, asset: AVAsset, duration: Double) throws -> AudioStats {
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw KilError.failed("AVAssetReader の生成に失敗しました")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw KilError.failed("音声トラックの読み取り開始に失敗: \(String(describing: reader.error))")
        }
        var sum = 0.0, count = 0, peak = 0.0
        var firstPTS: CMTime?
        var lastEnd: CMTime?
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let dur = CMSampleBufferGetDuration(sb)
            if CMTIME_IS_NUMERIC(pts) {
                if firstPTS == nil { firstPTS = pts }
                let end = CMTIME_IS_NUMERIC(dur) ? CMTimeAdd(pts, dur) : pts
                if lastEnd == nil || CMTimeCompare(end, lastEnd!) > 0 { lastEnd = end }
            }
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
        if reader.status == .failed {
            throw KilError.failed("音声トラックの読み取りに失敗: \(String(describing: reader.error))")
        }
        // トラック自身の長さはデコードしたサンプルの PTS から求める
        // (AVAssetTrack.load(.duration) は macOS 26 のツールチェーンで壊れているため)
        var trackDuration = duration
        if let f = firstPTS, let e = lastEnd, CMTIME_IS_NUMERIC(f), CMTIME_IS_NUMERIC(e) {
            trackDuration = max(0, e.seconds - f.seconds)
        }
        let rms = count > 0 ? sqrt(sum / Double(count)) : 0
        // `count` は rms の分母。捨てずに外へ出す — これが 0 かどうかだけが
        // 「サンプルが来なかった」と「無音だった」を分ける (issue #108)
        return AudioStats(duration: trackDuration, rms: rms, peak: peak, valueCount: count)
    }
}
