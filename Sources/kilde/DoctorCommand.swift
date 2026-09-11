import Foundation
import ArgumentParser
import KildeCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "権限と環境の診断"
    )

    func run() {
        print("== kilde doctor ==")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let screen = Permissions.hasScreenCapture
        print("[screen] 画面収録権限: \(screen ? "あり" : "なし")")
        if !screen {
            print("[screen] 権限を要求します (システム設定が開きます)。許可後、再実行してください。")
            let requested = Permissions.requestScreenCapture()
            print("[screen] 要求発行: \(requested)")
            print("         システム設定 → プライバシーとセキュリティ → 画面とオーディオを収録 で許可してください")
        }

        switch Permissions.micStatus {
        case .authorized:
            print("[mic] マイク権限: あり")
        case .notDetermined:
            print("[mic] マイク権限: 未設定 → 要求ダイアログを出します")
            print("[mic] 許可されました: \(Permissions.requestMic())")
        case .denied:
            print("[mic] マイク権限: 拒否済み (ダイアログは出ません)")
            print("         システム設定 → プライバシーとセキュリティ → マイク で許可してください")
        }

        do {
            let snapshot = try DisplayCatalog.snapshot()
            print("[sck] displays=\(snapshot.displays.count) windows=\(snapshot.windows.count)")
            for d in snapshot.displays {
                print("  \(d)")
            }
        } catch {
            print("[sck] ERROR: \(error)")
        }

        let devices = AudioDeviceCatalog.devices
        print("[coreaudio] devices=\(devices.count) defaultOut=\"\(AudioDeviceCatalog.defaultOutput?.name ?? "?")\" defaultIn=\"\(AudioDeviceCatalog.defaultInput?.name ?? "?")\"")
        if !AudioDeviceCatalog.hasBlackHole {
            print("[coreaudio] BlackHole: 未検出 (--audio device: を使う場合: brew install --cask blackhole-2ch)")
        } else {
            for d in devices where d.isBlackHole {
                print("  blackhole: \"\(d.name)\" in=\(d.inputChannels) out=\(d.outputChannels)")
            }
        }
        print("[monitor] kilde Monitor: \(MonitorDevice.exists ? "存在する" : "存在しない")")
    }
}
