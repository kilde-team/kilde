import Foundation
import ArgumentParser
import KildeCore

struct DevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "ディスプレイ / ウィンドウ / オーディオ機器の一覧"
    )

    @Flag(help: "ウィンドウ一覧を省略する")
    var noWindows: Bool = false

    func run() {
        do {
            let snapshot = try DisplayCatalog.snapshot()
            print("== displays ==")
            for d in snapshot.displays {
                print("  \(d)")
            }
            if !noWindows {
                print("== windows (on-screen) ==")
                for w in snapshot.windows.filter({ $0.isOnScreen && $0.bundleIdentifier != nil }) {
                    print("  \(w)")
                }
            }
            print("== audio devices ==")
            let defOut = AudioDeviceCatalog.defaultOutput
            let defIn = AudioDeviceCatalog.defaultInput
            for d in AudioDeviceCatalog.devices {
                var marks: [String] = []
                if d.uid == defOut?.uid { marks.append("←既定出力") }
                if d.uid == defIn?.uid { marks.append("←既定入力") }
                if d.isBlackHole { marks.append("←BlackHole") }
                if d.uid == MonitorDevice.uid { marks.append("←kilde Monitor") }
                print("  id=\(d.id) \(d.kind) in=\(d.inputChannels) out=\(d.outputChannels) \"\(d.name)\" \(marks.joined(separator: " "))")
                print("      uid=\(d.uid)")
            }
            print("")
            print("使い方: kilde rec --display <番号> / --window <title|bundleID の一部> / --audio device:<名前>")
        } catch {
            cliError(error)
        }
    }
}
