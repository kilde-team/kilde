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

/// 不正な値を既定値に置き換えると指定と違う周期で計測してしまうので、拒否して終了する
func positiveArg(_ index: Int, default value: Double) -> Double {
    guard args.count > index else { return value }
    guard let v = Double(args[index]), v.isFinite, v > 0 else {
        FileHandle.standardError.write("ERROR: 引数は正の数値で指定してください: \(args[index])\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}
let interval = positiveArg(1, default: 30)
let lifetime = positiveArg(2, default: 960)
// 最初のマーカーは interval 秒後に出るので、寿命がそれ以下だとマーカーを 1 個も出さずに正常終了してしまう
// (トップレベルの guard にすると以降のグローバル変数の扱いが変わり、main actor 分離の警告が出るので if にしている)
// drift-analyze の探索窓 (幅 1.5 秒) より短い間隔では隣のマーカーと区別できず計測が成立しないので、
// 直接実行されたときのためにここでも拒否する (drift-test.sh と drift-analyze と同じ条件)
if interval <= 1.5 {
    FileHandle.standardError.write("ERROR: マーカー間隔は 1.5 秒より大きくしてください: \(interval)\n".data(using: .utf8)!)
    exit(2)
}
if lifetime <= interval {
    FileHandle.standardError.write("ERROR: 自動終了までの秒 (\(lifetime)) はマーカー間隔 (\(interval)) より長くしてください\n".data(using: .utf8)!)
    exit(2)
}

/// 1 kHz / 60 ms のビープを CAF のバイト列として作る。
/// オンセット検出を安定させるため立ち上がりは鋭く (フェードインなし)、末尾だけ 10 ms フェードする
func makeBeep() throws -> Data {
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
    // 一時ファイルは読み込んだ直後に消す。drift-test.sh の kill (SIGTERM) など、寿命タイマー以外の
    // 終了経路でも CAF が一時ディレクトリに残らないようにするため
    defer { try? FileManager.default.removeItem(at: url) }
    // AVAudioFile は解放時にファイルを閉じるので、スコープを切って書き切ってから読む
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    return try Data(contentsOf: url)
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

let player = try AVAudioPlayer(data: makeBeep(), fileTypeHint: AVFileType.caf.rawValue)
player.volume = 1.0
// 初回の play() だけ出力経路の立ち上げで遅れないよう、事前にバッファを用意しておく
player.prepareToPlay()

var count = 0
func fire() {
    count += 1
    window.backgroundColor = .white
    window.display()
    player.currentTime = 0
    // 再生できないまま点滅だけ続けると「ビープのない録画」を計測として扱ってしまうので、ここで止める。
    // drift-test.sh は録画終了時にマーカーが居なければその回を失敗にする
    guard player.play() else {
        FileHandle.standardError.write("ERROR: ビープの再生を開始できません (marker \(count))\n".data(using: .utf8)!)
        exit(1)
    }
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
    NSApp.terminate(nil)
}
// 起動の遅れ (WindowServer 等) を固定の sleep で待つと --window の解決に失敗しうるので、
// イベントループが回り始めた (ウィンドウが表示された) 時点で drift-test.sh に準備完了を知らせる
DispatchQueue.main.async {
    print("ready")
    fflush(stdout)
}
app.run()
