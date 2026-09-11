import Foundation
import CoreGraphics
import AVFoundation
import ScreenCaptureKit

// S1/S2/S3/S5: ディスプレイ + システム音声 (+ マイク) の録画検証

/// rec-system / rec-audio-only / rec-window 共通の録画セッション実行
@discardableResult
func runRecordingSession(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration,
    observeScreen: Bool,
    wantsVideo: Bool,
    audioLabels: [String],
    micEnabled: Bool,
    url: URL,
    duration: TimeInterval
) throws -> MovieWriter {
    let writer = try MovieWriter(
        url: url,
        fileType: wantsVideo ? .mov : .m4a,
        video: wantsVideo,
        videoSize: wantsVideo
            ? CGSize(width: configuration.width, height: configuration.height)
            : nil,
        audioLabels: audioLabels,
        anchor: wantsVideo ? .firstVideo : .firstAudio
    )

    // macOS 26 の SCK は既定で圧縮フレームを渡す (S3 の重要発見)。
    // AVAssetWriter での再圧縮 (任意ビットレート) を使うため非圧縮 BGRA を要求する。
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let sck = SckCapture(filter: filter, configuration: configuration, audio: true,
                         observeScreen: observeScreen) { sb, type in
        switch type {
        case .screen: writer.appendVideo(sb)
        case .audio: writer.appendAudio(sb, label: "system")
        case .microphone: break // macOS 15+ で SCK 自身がマイク取得を持つ。今回は AVCapture 経由のみ使用
        @unknown default: break
        }
    }
    try sck.start()

    var mic: MicCapture?
    if micEnabled {
        mic = try MicCapture { sb in writer.appendAudio(sb, label: "mic") }
        mic?.start()
        print("mic: AVCapture 開始")
    }

    print("● 録画中 \(Int(duration))s → \(url.path)  (Ctrl+C で早期停止)")
    let sem = DispatchSemaphore(value: 0)
    installStopSignalHandler { sem.signal() }
    let waitResult = sem.wait(timeout: .now() + duration)
    print(waitResult == .success ? "シグナル受信 → 停止します" : "規定時間経過 → 停止します")

    print("停止中 (ファイナライズ待ち)…")
    sck.stop()
    mic?.stop()
    try awaitSync { try await writer.finish() }
    return writer
}

func printResults(writer: MovieWriter, url: URL) {
    print("---- 結果 ----")
    for line in writer.reportLines() { print(line) }
    print("file: \(url.path) (\(fileSizeString(url)))")
    if let st = analyzeAudio(url: url) {
        print(String(format: "audio track #1: duration=%.2fs rms=%.4f peak=%.4f", st.duration, st.rms, st.peak))
        if st.rms > 0.001 {
            print("→ 音声の中身あり (システム音声キャプチャ成功)")
        } else {
            print("→ 無音 (録画時間中に何も再生されなかったか、取得失敗)")
        }
    } else {
        print("audio track: なし ← SCK 音声取得の失敗可能性")
    }
}

struct RecSystemCmd {
    let args: Args

    func run() {
        let duration = parseDuration(args.option("--duration"))
        let out = URL(fileURLWithPath: args.option("--output") ?? defaultOutputName("spike-rec-system", "mov"))
        let mic = args.flag("--mic")

        guard CGPreflightScreenCaptureAccess() else {
            fail("画面収録の権限がありません。`spike doctor` を実行して許可 → 再実行してください")
        }
        if mic && !ensureMicPermission() {
            fail("マイク権限がありません")
        }

        do {
            let content = try awaitSync {
                try await SCShareableContent.current
            }
            guard !content.displays.isEmpty else {
                fail("SCShareableContent.displays が空です (権限不足の可能性)。spike doctor を参照")
            }
            let idx = Int(args.option("--display") ?? "") ?? 0
            guard content.displays.indices.contains(idx) else {
                fail("--display \(idx) が範囲外 (0...\(content.displays.count - 1))")
            }
            let display = content.displays[idx]
            print("display[\(idx)] \(Int(display.width))x\(Int(display.height))")

            let cfg = SCStreamConfiguration()
            cfg.width = Int(display.width)
            cfg.height = Int(display.height)
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.showsCursor = true
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let writer = try runRecordingSession(
                filter: filter,
                configuration: cfg,
                observeScreen: true,
                wantsVideo: true,
                audioLabels: mic ? ["system", "mic"] : ["system"],
                micEnabled: mic,
                url: out,
                duration: duration
            )
            printResults(writer: writer, url: out)
        } catch {
            fail("\(error)")
        }
    }
}
