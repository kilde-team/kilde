import Foundation
import AVFoundation
import CoreMedia

// MARK: - 基本ユーティリティ

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("ERROR: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

private final class ResultBox<T> {
    var result: Result<T, Error>?
}

func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    switch box.result! {
    case .success(let v): return v
    case .failure(let e): throw e
    }
}

struct Args {
    private let v: [String]
    init(_ argv: [String]) { v = argv }
    func flag(_ name: String) -> Bool { v.contains(name) }
    func option(_ name: String) -> String? {
        guard let i = v.firstIndex(of: name), i + 1 < v.count else { return nil }
        return v[i + 1]
    }
    var bare: [String] { v.filter { !$0.hasPrefix("-") } }
}

func parseDuration(_ s: String?) -> TimeInterval {
    guard let s, !s.isEmpty else { return 6 }
    let numStr = String(s.prefix { $0.isNumber || $0 == "." })
    guard var n = Double(numStr) else { return 6 }
    if s.hasSuffix("m") { n *= 60 }
    else if s.hasSuffix("h") { n *= 3600 }
    return n
}

func defaultOutputName(_ prefix: String, _ ext: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return "\(prefix)-\(f.string(from: Date())).\(ext)"
}

func fileSizeString(_ url: URL) -> String {
    let b = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(b ?? 0), countStyle: .file)
}

// MARK: - シグナル (S5)

private var signalSources: [DispatchSourceSignal] = []

func installStopSignalHandler(_ handler: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let q = DispatchQueue(label: "spike.signal")
    for sig in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - 出力ファイル解析 (音声が本当に録えたかの客観検証)

struct AVFileStats { var duration: Double; var rms: Double; var peak: Double }

func analyzeAudio(url: URL) -> AVFileStats? {
    (try? awaitSync { try await analyzeAudioAsync(url: url) }) ?? nil
}

private func analyzeAudioAsync(url: URL) async throws -> AVFileStats? {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else { return nil }
    let duration = try await asset.load(.duration)
    guard let reader: AVAssetReader = try? AVAssetReader(asset: asset) else { return nil }
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
    return AVFileStats(duration: duration.seconds, rms: rms, peak: peak)
}
