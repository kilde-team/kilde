import Foundation
import CoreGraphics
import ScreenCaptureKit

// S9: ウィンドウ単位収録と「そのアプリの音声のみ」スコープの検証
// 使い方:
//   1) spike rec-window --list でウィンドウ一覧
//   2) 別アプリで音を鳴らしながら、無関係なウィンドウを収録 → 音声が入らなければスコープ有効

struct RecWindowCmd {
    let args: Args

    func run() {
        let duration = parseDuration(args.option("--duration"))
        let out = URL(fileURLWithPath: args.option("--output") ?? defaultOutputName("spike-rec-window", "mov"))
        let match = args.option("--match") ?? args.option("-m")

        guard CGPreflightScreenCaptureAccess() else {
            fail("画面収録の権限がありません。`spike doctor` を実行して許可 → 再実行してください")
        }

        do {
            let content = try awaitSync {
                try await SCShareableContent.current
            }
            let wins = content.windows.filter { $0.isOnScreen && $0.owningApplication != nil }

            func listWindows() {
                print("== on-screen windows ==")
                for w in wins {
                    print("  [\(w.windowID)] \(w.owningApplication?.bundleIdentifier ?? "?") \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height))")
                }
            }

            guard let match else {
                listWindows()
                fail("--match <text> でウィンドウを指定してください (title または bundleID の部分一致)")
            }
            guard let win = wins.first(where: {
                ($0.title ?? "").localizedCaseInsensitiveContains(match) ||
                ($0.owningApplication?.bundleIdentifier ?? "").localizedCaseInsensitiveContains(match)
            }) else {
                listWindows()
                fail("\"\(match)\" にマッチするウィンドウがありません")
            }
            print("window: [\(win.windowID)] \(win.owningApplication?.bundleIdentifier ?? "?") \"\(win.title ?? "")\"")

            let cfg = SCStreamConfiguration()
            cfg.width = Int(win.frame.width)
            cfg.height = Int(win.frame.height)
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            let filter = SCContentFilter(desktopIndependentWindow: win)

            let writer = try runRecordingSession(
                filter: filter,
                configuration: cfg,
                observeScreen: true,
                wantsVideo: true,
                audioLabels: ["system"],
                micEnabled: false,
                url: out,
                duration: duration
            )
            printResults(writer: writer, url: out)
            print("※ 音声スコープの判定: 収録中に「このウィンドウ以外のアプリ」で音を鳴らし、")
            print("   出力ファイルにそれが入っていなければ スコープ有効 (S9 成功)")
        } catch {
            fail("\(error)")
        }
    }
}
