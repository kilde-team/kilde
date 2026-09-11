import Foundation
import AVFoundation
import ScreenCaptureKit

struct DevicesCmd {
    func run() {
        // SCK: ディスプレイとウィンドウ
        do {
            let content = try awaitSync {
                try await SCShareableContent.current
            }
            print("== displays ==")
            for (i, d) in content.displays.enumerated() {
                print("  [\(i)] \(Int(d.width))x\(Int(d.height)) displayID=\(d.displayID)")
            }
            print("== windows (on-screen) ==")
            for w in content.windows where w.isOnScreen {
                let app = w.owningApplication?.bundleIdentifier ?? "?"
                print("  [\(w.windowID)] \(app) \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height))")
            }
        } catch {
            print("== SCK 取得失敗 (spike doctor を参照): \(error)")
        }

        // CoreAudio
        print("== audio devices (CoreAudio) ==")
        let defOut = AudioHAL.defaultOutput
        for d in AudioHAL.devices {
            let marks = [
                d.uid == defOut?.uid ? "←既定出力" : nil,
                d.isBlackHole ? "←BlackHole" : nil,
            ].compactMap { $0 }.joined(separator: " ")
            print("  id=\(d.id) \(d.kind) in=\(d.inputChannels) out=\(d.outputChannels) \"\(d.name)\" \(marks)")
            print("      uid=\(d.uid)")
        }

        // AVCapture
        print("== audio devices (AVCapture) ==")
        let av = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        for d in av {
            print("  \(d.uniqueID) \"\(d.localizedName)\"")
        }
    }
}
