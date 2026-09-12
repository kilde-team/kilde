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
                // bundleID ごとにまとめて見出しに出す。--exclude-app は bundleID の完全一致で
                // 引くので、ウィンドウ行に混ぜるよりそのままコピーできる形の方が使いやすい
                let windows = snapshot.windows.filter { $0.isOnScreen && $0.bundleIdentifier != nil }
                // bundleID を持たないシステム UI (メニューバー等) は見出しが空になってしまうので
                // まとめて末尾に寄せる。--exclude-app では指定できないことも明示する
                let noBundleID = "(bundleID なし — --exclude-app では指定できません)"
                let grouped = Dictionary(grouping: windows) { w -> String in
                    let id = w.bundleIdentifier ?? ""
                    return id.isEmpty ? noBundleID : id
                }
                // 素直に sorted() すると "(" が英数より前に来て見出しが先頭に来てしまうので、
                // bundleID を持つグループを並べたあとに付ける
                let named = grouped.keys.filter { $0 != noBundleID }.sorted()
                let order = grouped[noBundleID] == nil ? named : named + [noBundleID]
                for bundleID in order {
                    print("  \(bundleID)")
                    for w in grouped[bundleID] ?? [] {
                        print("      [\(w.windowID)] \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height))")
                    }
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
