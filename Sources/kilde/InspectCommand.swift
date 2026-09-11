import Foundation
import ArgumentParser
import KildeCore

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "録画ファイルのトラック構成と音声レベルを表示"
    )

    @Argument(help: "録画/録音ファイルのパス")
    var file: String

    func run() {
        let url = URL(fileURLWithPath: NSString(string: file).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            cliError(KilError.failed("ファイルがありません: \(url.path)"))
        }
        do {
            let r = try FileInspection.report(url: url)
            print("file: \(url.path)")
            print("size: \(fileSizeString(url))")
            if let size = r.videoSize {
                print(String(format: "video: present %dx%d duration=%.2fs",
                             Int(size.width), Int(size.height), r.duration))
            } else {
                print("video: absent")
            }
            if r.audioTracks.isEmpty {
                print("audio: absent")
            }
            for (i, a) in r.audioTracks.enumerated() {
                print(String(format: "audio[%d]: duration=%.2fs rms=%.4f peak=%.4f",
                             i, a.duration, a.rms, a.peak))
            }
        } catch {
            cliError(error)
        }
    }
}
