// A/V ドリフト計測 (issue #3) 用のマーカー発生アプリ。
// 黒いウィンドウを一定間隔で白く点滅させ、同時に短いビープ (1 kHz) を鳴らす。
// `kilde rec --window KildeDriftMarker --audio system --audio mic` で収録すると、
//   映像      … ウィンドウの点滅
//   system    … このアプリのビープ (ウィンドウ収録なので他アプリの音は入らない — SPIKE-NOTES F-B)
//   mic       … スピーカーから回り込んだ同じビープ
// の 3 系統に「同じ瞬間」のマーカーが入る。点滅と発音の間には表示・出力の遅延ぶんの
// 一定のずれがあるが、計測したいのは録画中に**ずれが増えていくか (ドリフト)** なので問題にならない。
//
// 使い方: drift-marker <マーカー間隔秒> <自動終了までの秒>
import AppKit
import AVFoundation

let args = CommandLine.arguments
let interval = args.count > 1 ? (Double(args[1]) ?? 30) : 30
let lifetime = args.count > 2 ? (Double(args[2]) ?? 960) : 960

/// 1 kHz / 60 ms のビープを一時ファイルに書く。
/// オンセット検出を安定させるため立ち上がりは鋭く (フェードインなし)、末尾だけ 10 ms フェードする
func makeBeep() throws -> URL {
    let sampleRate = 48_000.0
    let frames = Int(sampleRate * 0.06)
    let fade = 480
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = buffer.floatChannelData![0]
    for i in 0..<frames {
        let gain: Float = i > frames - fade ? Float(frames - i) / Float(fade) : 1
        samples[i] = 0.8 * gain * Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate))
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kilde-drift-beep-\(getpid()).caf")
    // AVAudioFile は解放時にファイルを閉じるので、スコープを切って書き切ってから返す
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    return url
}

let app = NSApplication.shared
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "KildeDriftMarker"
window.backgroundColor = .black
window.orderFrontRegardless()

let beepURL = try makeBeep()
let player = try AVAudioPlayer(contentsOf: beepURL)
player.volume = 1.0
// 初回の play() だけ出力経路の立ち上げで遅れないよう、事前にバッファを用意しておく
player.prepareToPlay()

var count = 0
func fire() {
    count += 1
    window.backgroundColor = .white
    window.display()
    player.currentTime = 0
    player.play()
    print("marker \(count) \(String(format: "%.3f", Date().timeIntervalSince1970))")
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        window.backgroundColor = .black
        window.display()
    }
}

// Timer 自体の揺れは計測に影響しない (マーカーごとに映像と音声の差を取るため)
Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in fire() }
Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { _ in
    try? FileManager.default.removeItem(at: beepURL)
    NSApp.terminate(nil)
}
app.run()
