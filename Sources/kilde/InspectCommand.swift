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
                // **`values=` は行の末尾に足す (issue #108)。** 統合テストは
                // `grep -o 'rms=[0-9.]*'` や `grep -c '^audio\['` のように
                // **行頭と既存キーで**読んでいるので、並びを変えず末尾に付ける限り壊れない。
                // `rms` は `%.4f` で丸まる (0.00005 までが 0.0000) ため、
                // 「サンプルが来たか」はこちらでしか判定できない
                // **`values` は `%ld` で出す (cubic の指摘)。** `valueCount` は 64 ビットの
                // `Int` だが `%d` は 32 ビットしか読まない。ステレオ 48kHz は 1 秒で
                // 96,000 値なので、**約 6.2 時間を超えると 2^31 を越えて負数になる**。
                // `values=-1234…` と出れば「サンプルが来たか」の判定が壊れ、
                // T18b は `-le 0` で見ているので**長時間録画をサンプル 0 と誤判定**する
                print(String(format: "audio[%d]: duration=%.2fs rms=%.4f peak=%.4f values=%ld",
                             i, a.duration, a.rms, a.peak, a.valueCount))
            }
        } catch {
            cliError(error)
        }
    }
}
