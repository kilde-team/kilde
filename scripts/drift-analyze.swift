// A/V ドリフト計測 (issue #3) の解析。drift-marker のマーカー (点滅 + ビープ) を
// 録画ファイルの映像・各音声トラックから検出し、マーカーごとのずれと、その経時変化を出す。
//
// 使い方: drift-analyze <録画ファイル> [マーカー間隔秒 (既定 30)]
//
// - 基準は映像の点滅: フレームの平均輝度が (最小 + 最大) / 2 を下から上へ越えた最初のフレームの PTS。
//   音声のみのファイルは audio[0] の立ち上がりを基準にする
// - 音声のオンセットは**基準マーカーの周辺 (−0.5〜+1.0 秒) だけを探す**。窓内の雑音レベル (中央値) と
//   最大値の間の 30% を越えた最初の 1 ms ブロックをオンセットとする。
//   トラック全体の最大値で閾値を決めると、マイクに入った 1 回の大きな物音で全マーカーを取り逃すため
// - 各トラックの「音声 − 映像」を ms で出す。ドリフトは経時変化で、
//   (1) 最後のずれ − 最初のずれ と (2) 最小二乗の傾き × 計測時間 (推定ドリフト) を出す。
//   マーカーごとに映像 1 フレーム (~16 ms) 程度の揺れがあるため、(2) を主指標にする
// - separate の音声トラックの順序は `--audio` の指定順 (drift-test.sh は system, mic)
//
// 時刻はすべてファイル上の PTS (秒)。AVAssetTrack.load(.duration) は macOS 26 で
// 壊れているため使わない (FileInspection と同じ理由)。
import AVFoundation
import CoreMedia

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("使い方: drift-analyze <録画ファイル> [マーカー間隔秒]\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
// guidedOffset の探索窓は −0.5〜+1.0 秒 (幅 1.5 秒)。間隔がこれ以下だと隣のマーカーのビープが窓に入り、
// 欠落・遅延したマーカーの代わりに拾ってしまうので受け付けない (不正値を既定値に置き換えることもしない)
let interval: Double
if args.count > 2 {
    guard let v = Double(args[2]), v.isFinite, v > 1.5 else {
        FileHandle.standardError.write("ERROR: マーカー間隔は 1.5 秒より大きい数値を指定してください: \(args[2])\n".data(using: .utf8)!)
        exit(2)
    }
    interval = v
} else {
    interval = 30
}
// 1 回のマーカーの残響や点滅の戻りを次のマーカーと取り違えないための不感時間
let minGap = max(1.0, interval * 0.5)

typealias Series = [(t: Double, v: Double)]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("ERROR: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// 閾値を越えた立ち上がりを、不感時間を空けて拾う
func risingEdges(_ series: Series, threshold: Double) -> [Double] {
    var edges: [Double] = []
    var previous = Double.infinity
    for (t, v) in series {
        if v > threshold, previous <= threshold, (edges.last.map { t - $0 >= minGap } ?? true) {
            edges.append(t)
        }
        previous = v
    }
    return edges
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func videoSeries(_ track: AVAssetTrack, _ asset: AVAsset) throws -> Series {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    guard reader.startReading() else { fail("映像の読み取り開始に失敗: \(String(describing: reader.error))") }
    var series: Series = []
    while let sb = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts), let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // 全画素は不要なので 8 画素おきに間引いて平均輝度を取る
        var sum = 0.0, n = 0
        for y in stride(from: 0, to: height, by: 8) {
            let row = bytes + y * rowBytes
            for x in stride(from: 0, to: width, by: 8) {
                let p = row + x * 4
                sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                n += 1
            }
        }
        if n > 0 { series.append((pts.seconds, sum / Double(n) / 255)) }
    }
    if reader.status == .failed { fail("映像の読み取りに失敗: \(String(describing: reader.error))") }
    return series
}

/// 1 ms ブロックごとのピーク (全チャンネルの絶対値の最大)
func audioSeries(_ track: AVAssetTrack, _ asset: AVAsset) throws -> Series {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { fail("音声の読み取り開始に失敗: \(String(describing: reader.error))") }
    var series: Series = []
    while let sb = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts),
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let sampleRate = asbd.mSampleRate
        let length = CMBlockBufferGetDataLength(bb)
        var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let copied = floats.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { continue }
        let frames = floats.count / channels
        let block = max(1, Int(sampleRate / 1000))  // 1 ms
        var start = 0
        while start < frames {
            let end = min(frames, start + block)
            var peak: Float = 0
            for i in (start * channels)..<(end * channels) { peak = max(peak, abs(floats[i])) }
            series.append((pts.seconds + Double(start) / sampleRate, Double(peak)))
            start = end
        }
    }
    if reader.status == .failed { fail("音声の読み取りに失敗: \(String(describing: reader.error))") }
    return series.sorted { $0.t < $1.t }
}

/// 基準時刻 r の周辺 [r − 0.5, r + 1.0] で音声のオンセットを探し、r との差を返す。
/// 窓内の最大値が雑音レベルの 4 倍 (かつ 0.005) に届かなければ「マーカーなし」
func guidedOffset(_ series: Series, around r: Double) -> Double? {
    // series は時刻順なので二分探索で窓の先頭を探す
    var lo = 0, hi = series.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if series[mid].t < r - 0.5 { lo = mid + 1 } else { hi = mid }
    }
    var window: Series = []
    var i = lo
    while i < series.count, series[i].t <= r + 1.0 { window.append(series[i]); i += 1 }
    guard let peak = window.map(\.v).max() else { return nil }
    let noise = median(window.map(\.v))
    guard peak >= max(0.005, noise * 4) else { return nil }
    let threshold = noise + 0.3 * (peak - noise)
    return window.first(where: { $0.v > threshold }).map { $0.t - r }
}

/// (時刻, ずれ) の最小二乗の傾き
func slope(_ points: [(Double, Double)]) -> Double? {
    guard points.count >= 2 else { return nil }
    let n = Double(points.count)
    let mx = points.map(\.0).reduce(0, +) / n
    let my = points.map(\.1).reduce(0, +) / n
    let sxx = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
    guard sxx > 0 else { return nil }
    return points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +) / sxx
}

func ms(_ seconds: Double) -> String { String(format: "%+8.1f", seconds * 1000) }

let asset = AVURLAsset(url: url)
let videoTracks = try await asset.loadTracks(withMediaType: .video)
let audioTracks = try await asset.loadTracks(withMediaType: .audio)
guard !audioTracks.isEmpty else { fail("音声トラックがありません") }

let audio = try audioTracks.map { try audioSeries($0, asset) }
let names = audio.indices.map { "audio[\($0)]" }
let referenceName: String
let reference: [Double]
if let v = videoTracks.first {
    referenceName = "video"
    let series = try videoSeries(v, asset)
    guard let lo = series.map(\.v).min(), let hi = series.map(\.v).max(), hi - lo > 0.2 else {
        fail("映像に点滅が見つかりません (drift-marker のウィンドウを収録していますか)")
    }
    reference = risingEdges(series, threshold: (lo + hi) / 2)
} else {
    referenceName = "audio[0]"
    let peak = audio[0].map(\.v).max() ?? 0
    reference = risingEdges(audio[0], threshold: peak * 0.3)
}
guard reference.count >= 2 else {
    fail("\(referenceName) のマーカーが \(reference.count) 個しか見つかりません (録画時間とマーカー間隔を確認)")
}

let offsets = audio.map { series in reference.map { guidedOffset(series, around: $0) } }

print("file: \(url.path)")
print("基準: \(referenceName)  マーカー: \(reference.count) 個  間隔: \(interval)s")
for (i, series) in audio.enumerated() {
    let found = offsets[i].compactMap { $0 }.count
    print(String(format: "%@: 最大ピーク %.3f / 雑音レベル (中央値) %.4f / マーカー検出 %d/%d",
                 names[i], series.map(\.v).max() ?? 0, median(series.map(\.v)), found, reference.count))
}
print("ずれ = 各音声トラックのオンセット − \(referenceName) のオンセット [ms]")
print("")
print("  #   \(referenceName) [s]  " + names.map { $0.padding(toLength: 10, withPad: " ", startingAt: 0) }.joined())
for (k, t) in reference.enumerated() {
    let cols = offsets.map { $0[k].map(ms) ?? "     n/a" }.map { $0 + "  " }.joined()
    print(String(format: "%3d  %10.3f    ", k + 1, t) + cols)
}
print("")
print("---- 集計 ----")
func summarize(_ label: String, _ values: [Double?]) {
    let points = zip(reference, values).compactMap { t, v in v.map { (t, $0) } }
    guard points.count >= 2, let first = points.first, let last = points.last else {
        print("\(label): 対応するマーカーが 2 個未満")
        return
    }
    let span = last.0 - first.0
    let deviations = points.map(\.1)
    let spread = (deviations.max() ?? 0) - (deviations.min() ?? 0)
    let s = slope(points) ?? 0
    print(label)
    print(String(format: "  推定ドリフト (傾き × 計測時間) %+.1f ms  — 傾き %+.2f ms/分、%.1f 分間、n=%d",
                 s * span * 1000, s * 1000 * 60, span / 60, points.count))
    print("  最初 \(ms(first.1)) ms / 最後 \(ms(last.1)) ms / 差 \(ms(last.1 - first.1)) ms / 変動幅 \(String(format: "%.1f", spread * 1000)) ms")
}
for (i, name) in names.enumerated() where referenceName != name {
    summarize("\(name) − \(referenceName)", offsets[i])
}
// 音声基準 (音声のみのファイル) では audio[1] − audio[0] を上のループで出し済みなので、映像基準のときだけ足す
if referenceName == "video", offsets.count >= 2 {
    let between = zip(offsets[1], offsets[0]).map { b, a -> Double? in
        guard let a, let b else { return nil }
        return b - a
    }
    summarize("\(names[1]) − \(names[0])", between)
}
