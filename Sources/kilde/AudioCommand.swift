import Foundation
import ArgumentParser
import KildeCore

struct AudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "オーディオ設定",
        subcommands: [MonitorCommand.self]
    )

    func run() throws {
        throw CleanExit.helpRequest()
    }
}

struct MonitorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "「聞きながら録る」ためのマルチ出力デバイス (既定出力 + BlackHole) の管理"
    )

    enum Action: String, ExpressibleByArgument {
        case status
        case setup
        case teardown
    }

    @Argument(help: "status | setup | teardown")
    var action: Action = .status

    func run() {
        switch action {
        case .status:
            status()
        case .setup:
            do {
                let dev = try MonitorDevice.setup()
                print("作成しました: \"\(dev.name)\" (既定出力に設定)")
                print("元に戻すには: kilde audio monitor teardown")
            } catch {
                cliError(error)
            }
        case .teardown:
            do {
                if try MonitorDevice.teardown() {
                    print("既定出力を復元し、kilde Monitor を削除しました")
                } else {
                    print("復元すべき状態が見つかりません (kilde audio monitor setup を実行しましたか?)")
                }
            } catch {
                cliError(error)
            }
        }
    }

    private func status() {
        print("== audio devices ==")
        let defOut = AudioDeviceCatalog.defaultOutput
        for d in AudioDeviceCatalog.devices {
            var marks: [String] = []
            if d.uid == defOut?.uid { marks.append("←既定出力") }
            if d.isBlackHole { marks.append("←BlackHole") }
            if d.uid == MonitorDevice.uid { marks.append("←kilde Monitor") }
            print("  \(d.kind) \"\(d.name)\" \(marks.joined(separator: " "))")
        }
        print("kilde Monitor: \(MonitorDevice.exists ? "存在する" : "存在しない")")
        print("default output: \(AudioDeviceCatalog.defaultOutput?.name ?? "?")")
    }
}
