import Foundation
import CoreGraphics
import AVFoundation
import ScreenCaptureKit

/// S6: 権限と環境の診断
struct Doctor {
    func run() {
        print("== kilde spike doctor ==")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 画面収録 (SCK)
        let pre = CGPreflightScreenCaptureAccess()
        print("[screen] preflight: \(pre)")
        if !pre {
            print("[screen] 権限を要求します (ダイアログ/システム設定が開きます)。")
            print("         許可したら、このコマンドを再実行してください。")
            let req = CGRequestScreenCaptureAccess()
            print("[screen] CGRequestScreenCaptureAccess -> \(req)")
        }

        // マイク
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: print("[mic] authorized")
        case .notDetermined:
            print("[mic] notDetermined → 要求ダイアログを出します")
            print("[mic] granted: \(ensureMicPermission())")
        case .denied: print("[mic] DENIED")
        case .restricted: print("[mic] restricted")
        @unknown default: print("[mic] other")
        }

        // SCShareableContent (権限がない場合のエラーの形を S6 の記録用に出す)
        do {
            let content = try awaitSync {
                try await SCShareableContent.current
            }
            print("[sck] displays=\(content.displays.count) windows=\(content.windows.count) apps=\(content.applications.count)")
            for (i, d) in content.displays.enumerated() {
                print("  display[\(i)] \(Int(d.width))x\(Int(d.height)) displayID=\(d.displayID)")
            }
        } catch {
            print("[sck] ERROR (権限不足時のエラーの形を記録): \(error)")
        }

        // CoreAudio
        let devices = AudioHAL.devices
        print("[coreaudio] devices=\(devices.count) defaultOut=\"\(AudioHAL.defaultOutput?.name ?? "?")\" defaultIn=\"\(AudioHAL.defaultInput?.name ?? "?")\"")
        let bh = devices.filter { $0.isBlackHole }
        if bh.isEmpty {
            print("[coreaudio] BlackHole: 未検出 (brew install --cask blackhole-2ch)")
        } else {
            for d in bh { print("  blackhole: \"\(d.name)\" in=\(d.inputChannels) out=\(d.outputChannels)") }
        }

        // AVCapture
        let av = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        print("[avcapture] audio devices=\(av.count)")
        for d in av {
            print("  \(d.uniqueID) \"\(d.localizedName)\"")
        }
    }
}
