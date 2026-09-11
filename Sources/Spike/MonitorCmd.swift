import Foundation

/// S4: マルチ出力デバイスの作成/状態/復元の検証
///   spike monitor status
///   spike monitor setup      ... 既定出力 + BlackHole で "kilde Monitor" を作成し既定に設定
///   spike monitor teardown   ... 既定出力を元に戻して削除
struct MonitorCmd {
    let args: Args

    private static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kilde_spike_monitor.json")
    }

    private struct State: Codable {
        var originalDefaultOutputUID: String
    }

    func run() {
        switch args.bare.first ?? "status" {
        case "status": status()
        case "setup": setup()
        case "teardown": teardown()
        default:
            fail("不明なサブコマンド: \(args.bare.first ?? "")")
        }
    }

    private func listDevices(header: String) {
        print(header)
        let defOut = AudioHAL.defaultOutput
        for d in AudioHAL.devices {
            let marks = [
                d.uid == defOut?.uid ? "←既定出力" : nil,
                d.isBlackHole ? "←BlackHole" : nil,
                d.uid == MonitorDevice.uid ? "←kilde Monitor" : nil,
            ].compactMap { $0 }.joined(separator: " ")
            print("  id=\(d.id) \(d.kind) in=\(d.inputChannels) out=\(d.outputChannels) \"\(d.name)\" uid=\(d.uid) \(marks)")
        }
    }

    private func status() {
        listDevices(header: "== audio devices ==")
        print("kilde Monitor exists: \(MonitorDevice.exists)")
        if let def = AudioHAL.defaultOutput {
            print("default output: \(def.name) (\(def.uid))")
        }
    }

    private func setup() {
        guard let def = AudioHAL.defaultOutput else { fail("既定出力デバイスが取得できない") }
        let blackhole = AudioHAL.devices.first { $0.isBlackHole && $0.outputChannels > 0 }
        guard let bh = blackhole else {
            listDevices(header: "== BlackHole が見つかりません (brew install --cask blackhole-2ch) ==")
            fail("BlackHole 未検出のため setup をスキップ")
        }
        print("master (clock): \(def.name)")
        print("member: \(def.name) + \(bh.name)")
        do {
            let id = try MonitorDevice.create(masterUID: def.uid, memberUIDs: [def.uid, bh.uid])
            print("created aggregate id=\(id)")
            let ok = MonitorDevice.setDefaultOutput(id)
            print("set default output: \(ok)")
            let state = State(originalDefaultOutputUID: def.uid)
            try JSONEncoder().encode(state).write(to: Self.stateURL)
            print("state saved: \(Self.stateURL.path)")
            listDevices(header: "== after setup ==")
        } catch {
            fail("\(error)")
        }
    }

    private func teardown() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            fail("状態ファイルがないので復元先が不明。手動で既定出力を戻してください")
        }
        if let orig = AudioHAL.devices.first(where: { $0.uid == state.originalDefaultOutputUID }) {
            print("restore default output: \(orig.name)")
            _ = MonitorDevice.setDefaultOutput(orig.id)
        } else {
            print("⚠️ 元の既定出力 (\(state.originalDefaultOutputUID)) が見つかりません")
        }
        print("destroy kilde Monitor: \(MonitorDevice.destroy())")
        try? FileManager.default.removeItem(at: Self.stateURL)
        listDevices(header: "== after teardown ==")
    }
}
