import Foundation
import CoreGraphics
import ScreenCaptureKit

// S8: SCK で「音声のみ」を取得できるか
// .screen 出力を登録せず startCapture できるか、音声だけが流れてくるかを確認する。

struct RecAudioOnlyCmd {
    let args: Args

    func run() {
        let duration = parseDuration(args.option("--duration"))
        let out = URL(fileURLWithPath: args.option("--output") ?? defaultOutputName("spike-rec-audio-only", "m4a"))
        let withScreen = args.flag("--with-screen-output")
        let match = args.option("--match")

        guard CGPreflightScreenCaptureAccess() else {
            fail("画面収録の権限がありません。`spike doctor` を実行して許可 → 再実行してください")
        }

        do {
            let content = try awaitSync {
                try await SCShareableContent.current
            }
            guard let display = content.displays.first else {
                fail("SCShareableContent.displays が空です")
            }

            let cfg = SCStreamConfiguration()
            cfg.width = Int(display.width)   // 変数を絞るため映像サイズはそのまま (S8 は出力登録のみ変える)
            cfg.height = Int(display.height)
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2

            // --match 指定時はウィンドウ (アプリ) 単位のフィルタ → S9 のスコープと組み合わせ
            let filter: SCContentFilter
            if let match {
                let wins = content.windows.filter { $0.isOnScreen && $0.owningApplication != nil }
                guard let win = wins.first(where: {
                    ($0.title ?? "").localizedCaseInsensitiveContains(match) ||
                    ($0.owningApplication?.bundleIdentifier ?? "").localizedCaseInsensitiveContains(match)
                }) else {
                    fail("\"\(match)\" にマッチするウィンドウなし")
                }
                print("window filter: [\(win.windowID)] \(win.owningApplication?.bundleIdentifier ?? "?") \"\(win.title ?? "")\"")
                filter = SCContentFilter(desktopIndependentWindow: win)
            } else {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }

            print("S8 モード: .audio のみ登録 (observeScreen=\(withScreen), window=\(match != nil))")
            let writer = try runRecordingSession(
                filter: filter,
                configuration: cfg,
                observeScreen: withScreen,
                wantsVideo: false,
                audioLabels: ["system"],
                micEnabled: false,
                url: out,
                duration: duration
            )
            printResults(writer: writer, url: out)
        } catch {
            fail("S8 失敗: \(error)")
        }
    }
}
