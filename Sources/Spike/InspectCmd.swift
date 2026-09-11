import Foundation
import AVFoundation

// 統合テスト用: 録画ファイルのトラック構成と音声レベルを機械判定可能な形で出力する
//   spike inspect <file>
//   → video: present 2560x1440 duration=8.08s fps=51.1
//     audio[0]: duration=8.10s rms=0.0873 peak=0.6100

struct InspectCmd {
    let args: Args

    func run() {
        guard let path = args.bare.first else { fail("usage: spike inspect <file>") }
        guard FileManager.default.fileExists(atPath: path) else { fail("ファイルなし: \(path)") }
        let url = URL(fileURLWithPath: path)
        do {
            let lines = try awaitSync { try await inspectAsync(url: url) }
            print("file: \(path)")
            print("size: \(fileSizeString(url))")
            for line in lines { print(line) }
        } catch {
            fail("inspect 失敗: \(error)")
        }
    }

    private func inspectAsync(url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        var lines: [String] = []

        let total = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let v = videoTracks.first {
            let size = try await v.load(.naturalSize)
            lines.append(String(format: "video: present %dx%d duration=%.2fs",
                                Int(size.width), Int(size.height), total.seconds))
        } else {
            lines.append("video: absent")
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if audioTracks.isEmpty { lines.append("audio: absent") }
        for (i, t) in audioTracks.enumerated() {
            if let st = analyzeAudioTrack(t, asset: asset, duration: total.seconds) {
                lines.append(String(format: "audio[%d]: duration=%.2fs rms=%.4f peak=%.4f",
                                    i, st.duration, st.rms, st.peak))
            } else {
                lines.append("audio[\(i)]: unreadable")
            }
        }
        return lines
    }
}
