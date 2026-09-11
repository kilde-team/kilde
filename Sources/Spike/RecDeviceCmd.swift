import Foundation
import AVFoundation

// S4 補助: 任意の入力デバイス (BlackHole 等) から音声のみ録音する。
// マルチ出力デバイス稼働中に録って、ループバック全体を検証する。

struct RecDeviceCmd {
    let args: Args

    func run() {
        let duration = parseDuration(args.option("--duration"))
        let out = URL(fileURLWithPath: args.option("--output") ?? defaultOutputName("spike-rec-device", "m4a"))

        guard let uid = args.option("--device") else {
            print("== input devices ==")
            for d in AudioHAL.devices where d.inputChannels > 0 {
                print("  \(d.kind) \"\(d.name)\" uid=\(d.uid)")
            }
            fail("--device <uid> を指定してください")
        }
        guard ensureMicPermission() else { fail("マイク (入力) 権限がありません") }

        do {
            let writer = try MovieWriter(
                url: out, fileType: .m4a, video: false, videoSize: nil,
                audioLabels: ["device"], anchor: .firstAudio
            )
            let cap = try MicCapture(deviceUniqueID: uid) { sb in
                writer.appendAudio(sb, label: "device")
            }
            cap.start()
            print("● 録音中 \(Int(duration))s from uid=\(uid) → \(out.path)")
            let sem = DispatchSemaphore(value: 0)
            installStopSignalHandler { sem.signal() }
            _ = sem.wait(timeout: .now() + duration)
            print("停止中…")
            cap.stop()
            try awaitSync { try await writer.finish() }
            printResults(writer: writer, url: out)
        } catch {
            fail("\(error)")
        }
    }
}
