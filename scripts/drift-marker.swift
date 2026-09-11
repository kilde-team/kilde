// A/V ドリフト計測 (issue #3) 用のマーカー発生アプリ。
// 黒いウィンドウを一定間隔で白く点滅させ、同時に短いビープ (1 kHz) を鳴らす。
// `kilde rec --window KildeDriftMarker --audio system --audio mic` で収録すると、
//   映像      … ウィンドウの点滅
//   system    … このアプリのビープ (ウィンドウ収録なので他アプリの音は入らない — SPIKE-NOTES F-B)
//   mic       … スピーカーから回り込んだ同じビープ (BlackHole を指定すればデジタルで折り返せる)
// の 3 系統に「同じ瞬間」のマーカーが入る。点滅と発音の間には表示・出力の遅延ぶんの
// 一定のずれがあるが、計測したいのは録画中に**ずれが増えていくか (ドリフト)** なので問題にならない。
//
// 使い方: drift-marker <マーカー間隔秒> <自動終了までの秒> [出力デバイス名 (部分一致)]
//
// 出力デバイスを指定できるようにしているのは、**システムの既定出力を変えずに**鳴らす先を選ぶため。
// 検証機は液晶が破損していて常時クラムシェルのため内蔵スピーカーが使えず (AudioQueueStart -66681)、
// 外部ディスプレイのスピーカーや BlackHole に直接出す必要がある。そのため AVAudioPlayer ではなく
// AVAudioEngine を使い、出力ユニットの CurrentDevice を指定している。
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
// 空文字は「指定なし」(drift-test.sh が OUT 未設定のときに空文字を渡すため)
let outputDeviceName: String? = args.count > 3 && !args[3].isEmpty ? args[3] : nil

// drift-analyze の探索窓 (幅 1.5 秒) より短い間隔では隣のマーカーと区別できず計測が成立しないので、
// 直接実行されたときのためにここでも拒否する (drift-test.sh と drift-analyze と同じ条件)
// (トップレベルの guard にすると以降のグローバル変数の扱いが変わり、main actor 分離の警告が出るので if にしている)
if interval <= 1.5 {
    FileHandle.standardError.write("ERROR: マーカー間隔は 1.5 秒より大きくしてください: \(interval)\n".data(using: .utf8)!)
    exit(2)
}
// 最初のマーカーは interval 秒後に出るので、寿命がそれ以下だとマーカーを 1 個も出さずに正常終了してしまう
if lifetime <= interval {
    FileHandle.standardError.write("ERROR: 自動終了までの秒 (\(lifetime)) はマーカー間隔 (\(interval)) より長くしてください\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write("ERROR: \(message)\n".data(using: .utf8)!)
    exit(code)
}

/// 1 kHz / 60 ms のビープ (48 kHz mono)。
/// オンセット検出を安定させるため立ち上がりは鋭く (フェードインなし)、末尾だけ 10 ms フェードする
func makeBeep() -> AVAudioPCMBuffer {
    let sampleRate = 48_000.0
    let frames = Int(sampleRate * 0.06)
    let fade = 480
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
        fail("ビープのバッファを作れません", 1)
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = buffer.floatChannelData![0]
    for i in 0..<frames {
        let gain: Float = i > frames - fade ? Float(frames - i) / Float(fade) : 1
        samples[i] = 0.8 * gain * Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate))
    }
    return buffer
}

// MARK: - CoreAudio HAL (出力デバイスの名前引き)

func halDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func halDeviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    // CFString をそのまま受け取るとポインタ越しにオブジェクト参照を書かれてしまうので Unmanaged で受ける
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
          let value = name?.takeRetainedValue() else { return "" }
    return value as String
}

/// 出力ストリームを持つデバイスか (入力専用デバイスを候補から外す)
func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        .contains { $0.mNumberChannels > 0 }
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

let beep = makeBeep()
let engine = AVAudioEngine()
let playerNode = AVAudioPlayerNode()

/// 鳴らす先。未指定ならシステムの既定出力
let selectedOutput: (id: AudioDeviceID, name: String)? = outputDeviceName.map { wanted in
    let outputs = halDeviceIDs().filter(hasOutputStreams).map { (id: $0, name: halDeviceName($0)) }
    guard let match = outputs.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
        fail("出力デバイスが見つかりません: \(wanted)\n  利用可能: \(outputs.map(\.name).joined(separator: " / "))", 2)
    }
    return match
}

engine.attach(playerNode)

/// 出力デバイスの指定 → 接続 → 開始。
/// **デバイス構成が変わると AVAudioEngine は停止し、接続とデバイス指定も失われる**ので、
/// 起動時と構成変更の通知の両方でこれを呼ぶ。kilde rec が SCK 音声やマイクを掴むと実際に発生し、
/// 直さないと 1 個目のマーカーからビープが鳴らないまま録画が進む
func configureEngine() {
    if engine.isRunning { return }
    if var deviceID = selectedOutput?.id {
        guard let unit = engine.outputNode.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            fail("出力デバイスを設定できません: \(selectedOutput?.name ?? "")", 1)
        }
    }
    engine.connect(playerNode, to: engine.mainMixerNode, format: beep.format)
    engine.mainMixerNode.outputVolume = 1.0
    do {
        try engine.start()
    } catch {
        fail("オーディオエンジンを開始できません: \(error.localizedDescription)", 1)
    }
    playerNode.play()
}

if let selectedOutput { print("output device: \(selectedOutput.name)") }
configureEngine()
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
    print("audio engine reconfigured")
    fflush(stdout)
    configureEngine()
}

var count = 0
func fire() {
    count += 1
    window.backgroundColor = .white
    window.display()
    // 鳴らないまま点滅だけ続けると「ビープのない録画」を計測として扱ってしまうので、
    // 繋ぎ直しても直らなければ止める (drift-test.sh は録画終了時にマーカーが居なければその回を失敗にする)
    configureEngine()
    guard engine.isRunning else {
        fail("オーディオエンジンが停止しています (marker \(count))", 1)
    }
    // .interrupts で前のビープを捨てて即座に鳴らす (残響を次のマーカーに持ち越さない)
    playerNode.scheduleBuffer(beep, at: nil, options: .interrupts)
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
