// 統合テスト用: 自分で音を鳴らすウィンドウを持つ最小アプリ (S9 のスコープ検証に使用)
// 使い方: soundapp <audio-file>  (90 秒で自動終了)
import AppKit
import AVFoundation

let app = NSApplication.shared
let window = NSWindow(
    contentRect: NSRect(x: 400, y: 500, width: 300, height: 180),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "SpikeSoundWindow"
window.orderFrontRegardless()

let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
player.numberOfLoops = -1
player.volume = 0.8
player.play()

Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
    NSApp.terminate(nil)
}
app.run()
