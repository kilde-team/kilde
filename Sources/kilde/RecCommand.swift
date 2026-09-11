import Foundation
import AppKit
import ArgumentParser
import KildeCore

struct RecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rec",
        abstract: "録画 / 録音を開始する (Ctrl+C で安全に停止)"
    )

    @Option(help: "収録ディスプレイの番号 (kilde devices で確認。既定 0)")
    var display: Int?

    @Option(help: "ウィンドウ単位で収録 (title / bundleID / windowID の部分一致)。音声もそのアプリにスコープされる")
    var window: String?

    @Option(help: "音声ソース。system / mic / device:<名前orUID> / none。複数回指定可 (既定 system)")
    var audio: [String] = []

    @Option(help: "複数音声ソースの処理: mixed = 1 トラックに合成 (既定) / separate = トラック分離")
    var audioTracks: String = "mixed"

    @Flag(help: "録音 (音声のみ) モード。出力は M4A")
    var noVideo: Bool = false

    @Flag(help: "BlackHole マルチ出力デバイスをセッションに紐付けて自動 setup/teardown (--audio device:BlackHole... と組み合わせる)")
    var monitor: Bool = false

    @Option(name: .shortAndLong, help: "出力先パス (既定 kilde-yyyyMMdd-HHmmss.mov / .m4a)")
    var output: String?

    @Argument(help: "出力先パス (--output と同じ。kilde rec demo.mov のように使える)")
    var outputPositional: String?

    @Option(help: "自動停止までの時間 (例: 30s, 5m)")
    var duration: String?

    @Option(help: "映像コーデック: h264 (既定) / hevc / prores")
    var codec: String = "h264"

    @Option(help: "上限フレームレート")
    var fps: Int?

    @Flag(help: "カーソルを写し込まない")
    var noCursor: Bool = false

    @Option(help: "開始前カウントダウン (秒)")
    var countdown: Int = 0

    @Option(help: "プリセット: meeting = ウィンドウ対話選択 + system + mic + ミックス")
    var preset: String?

    func validate() throws {
        if audio.contains("none") && audio.contains(where: { $0 != "none" }) {
            throw ValidationError("--audio none は他の音声ソースと併用できません")
        }
        if noVideo && !audio.isEmpty && audio.allSatisfy({ $0 == "none" }) {
            throw ValidationError("--no-video と --audio none の組合せでは録れるものがありません")
        }
        if output != nil && outputPositional != nil {
            throw ValidationError("--output と位置引数の出力先は同時に指定できません")
        }
        if let preset, preset != "meeting" {
            throw ValidationError("不明なプリセット: \(preset) (利用可能: meeting)")
        }
        guard audioTracks == "mixed" || audioTracks == "separate" else {
            throw ValidationError("--audio-tracks は mixed か separate を指定してください")
        }
        guard VideoCodecKind(rawValue: codec) != nil else {
            throw ValidationError("--codec は h264 / hevc / prores を指定してください")
        }
        for a in audio {
            _ = try parseAudioSource(a)
        }
        if let d = duration, parseDuration(d) == nil {
            throw ValidationError("--duration の形式が不正: \(d) (例: 30s, 5m)")
        }
    }

    mutating func run() {
        // SCK ウィンドウ収録に必要な WindowServer 初期化 (SPIKE-NOTES F-D.3)。
        // 録画経路でのみ行い、他のサブコマンドを GUI セッションに依存させない。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var options = RecordOptions()

        if preset == "meeting" {
            options.audioSources = [.system, .mic]
            options.trackPolicy = .mixed
            if window == nil {
                if let picked = promptWindowSelection() {
                    window = picked
                }
            }
        }

        options.displayIndex = display ?? 0
        options.windowMatch = window
        if !audio.isEmpty {
            if audio.contains("none") {
                options.audioSources = []
            } else {
                options.audioSources = audio.compactMap { try? parseAudioSource($0) }
            }
        }
        options.trackPolicy = audioTracks == "separate" ? .separate : .mixed
        options.wantsVideo = !noVideo
        let outputPath = output ?? outputPositional
        options.outputURL = outputPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        options.duration = parseDuration(duration)
        options.codec = VideoCodecKind(rawValue: codec) ?? .h264
        options.fps = fps
        options.showsCursor = !noCursor
        options.autoMonitor = monitor

        if countdown > 0 {
            for i in stride(from: countdown, through: 1, by: -1) {
                print("開始まで \(i)...", terminator: "\r")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }
            print("                        \r", terminator: "")
        }

        // 表示と Recorder が同一 URL を使うように一度だけ解決する
        // (defaultOutputName を別々に評価すると秒の境界で不一致になり得る)
        options.outputURL = options.outputURL
            ?? URL(fileURLWithPath: defaultOutputName(ext: options.wantsVideo ? "mov" : "m4a"))
        let recorder = Recorder(options: options)
        installStopSignalHandler { [weak recorder] in
            recorder?.stop()
        }

        do {
            print("● 録画\(!options.wantsVideo ? " (音声のみ)" : "") → \(options.outputURL!.path)  (Ctrl+C で停止)")
            let ticker = startStatusTicker(recorder)
            let summary = try recorder.run()
            ticker.cancel()
            print("")
            printSummary(summary)
        } catch {
            cliError(error)
        }
    }

    // MARK: - 内部

    private func parseAudioSource(_ s: String) throws -> AudioSourceSpec {
        switch s {
        case "system": return .system
        case "mic": return .mic
        case "none": return .system  // "none" は run() 内で個別処理 (ソースなし)
        default:
            if s.hasPrefix("device:") {
                return .device(String(s.dropFirst("device:".count)))
            }
            throw ValidationError("--audio の値が不正: \(s) (system / mic / device:<名前> / none)")
        }
    }

    /// meeting プリセット用のウィンドウ対話選択。nil ならディスプレイ全体。
    /// 戻り値は windowID (選択したウィンドウを確実に再解決できる)。
    private func promptWindowSelection() -> String? {
        guard let windows = try? DisplayCatalog.listOnScreenWindows() else { return nil }
        let sorted = windows.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        print("収録するウィンドウを選択してください:")
        for (i, w) in sorted.enumerated() {
            print("  [\(i)] \(w)")
        }
        for _ in 0..<3 {
            print("番号を入力 (空欄 Enter でディスプレイ全体): ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
                return nil  // EOF — ディスプレイ全体へフォールバック
            }
            if line.isEmpty { return nil }
            if let n = Int(line), sorted.indices.contains(n) {
                return String(sorted[n].windowID)
            }
            print("  無効な入力です。0...\(sorted.count - 1) の番号を入力してください。")
        }
        return nil
    }

    private func startStatusTicker(_ recorder: Recorder) -> DispatchSourceTimer {
        let q = DispatchQueue(label: "kilde.status")
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            guard let p = recorder.progress() else { return }
            let m = Int(p.elapsed) / 60
            let s = Int(p.elapsed) % 60
            let size = ByteCountFormatter.string(fromByteCount: p.outputBytes, countStyle: .file)
            let levels = p.peaks.sorted(by: { $0.key < $1.key })
                .map { String(format: "%@:%.2f", $0.key, $0.value) }
                .joined(separator: " ")
            print(String(format: "\rREC %02d:%02d | %@ | %@   ", m, s, size, levels), terminator: "")
            fflush(stdout)
        }
        timer.resume()
        return timer
    }

    private func printSummary(_ s: Recorder.Summary) {
        print("---- 結果 ----")
        if s.videoAppended > 0 || s.videoDropped > 0 {
            print("video: appended=\(s.videoAppended) dropped=\(s.videoDropped)")
        }
        for (label, n) in s.audioAppended.sorted(by: { $0.key < $1.key }) {
            let dropped = s.audioDropped[label] ?? 0
            var extra = ""
            if let off = s.firstPTSOffsets[label] {
                extra = String(format: " (映像との first-PTS 差: %+0.3fs)", off)
            }
            print("audio[\(label)]: appended=\(n) dropped=\(dropped)\(extra)")
        }
        print("file: \(s.outputURL.path) (\(fileSizeString(s.outputURL)))")
        if s.mixedDecodeFailures > 0 {
            print("⚠ ミックスできなかった音声バッファ: \(s.mixedDecodeFailures) 件 (非対応フォーマットの可能性)")
        }
        if let report = try? FileInspection.report(url: s.outputURL) {
            if let size = report.videoSize {
                print(String(format: "video: %dx%d duration=%.2fs", Int(size.width), Int(size.height), report.duration))
            } else {
                print(String(format: "duration=%.2fs", report.duration))
            }
            for (i, a) in report.audioTracks.enumerated() {
                print(String(format: "audio[%d]: rms=%.4f peak=%.4f", i, a.rms, a.peak))
            }
        }
    }
}
