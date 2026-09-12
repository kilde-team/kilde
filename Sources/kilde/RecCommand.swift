import Foundation
import AppKit
import ArgumentParser
import KildeCore
import Darwin

/// 'p' キー監視で raw mode にする前の端末設定 (復元用)。
/// ParsableCommand の struct にプロパティを増やすと引数の解析対象と紛れるため、
/// 既存の signalSources と同じくファイルスコープに置く
private var pauseKeyOriginalTermios: termios?

struct RecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rec",
        abstract: "録画 / 録音を開始する (Ctrl+C で安全に停止)"
    )

    @Option(help: "収録ディスプレイの番号 (kilde devices で確認。既定 0)")
    var display: Int?

    @Option(help: "ウィンドウ単位で収録 (title / bundleID / windowID の部分一致)。音声もそのアプリにスコープされる")
    var window: String?

    @Option(help: "音声ソース。system / mic / device:<名前orUID> / none。複数回指定可 (既定 system。設定 defaultAudioSources で変更可)")
    var audio: [String] = []

    // 設定ファイルの値と区別するため、既定値を持たせず「未指定 = nil」にしている
    @Option(help: "複数音声ソースの処理: mixed = 1 トラックに合成 (既定) / separate = トラック分離 (設定 audioTracks で変更可)")
    var audioTracks: String?

    @Flag(help: "録音 (音声のみ) モード。出力は M4A")
    var noVideo: Bool = false

    @Flag(help: "BlackHole マルチ出力デバイスをセッションに紐付けて自動 setup/teardown (--audio device:BlackHole... と組み合わせる)")
    var monitor: Bool = false

    @Option(name: .shortAndLong, help: "出力先パス (既定 kilde-yyyyMMdd-HHmmss.mov / .m4a。保存先は KILDE_OUTPUT_DIR > 設定 outputDirectory > カレントディレクトリ)")
    var output: String?

    @Argument(help: "出力先パス (--output と同じ。kilde rec demo.mov のように使える)")
    var outputPositional: String?

    @Option(help: "自動停止までの時間 (例: 30s, 5m)")
    var duration: String?

    @Option(help: "映像コーデック: h264 (既定) / hevc / prores (設定 codec で変更可)")
    var codec: String?

    @Option(help: "上限フレームレート (1 以上。0 以下は終了コード 64。未指定は設定 fps、どちらも無ければ SCK 既定)")
    var fps: Int?

    // --no-cursor は M1 からの互換。設定 showsCursor=false を 1 回だけ打ち消せるよう --cursor も受ける
    @Flag(inversion: .prefixedNo, help: "カーソルを写り込む / 写り込まない (既定: 写り込む。設定 showsCursor で変更可、--cursor は false をその回だけ打ち消す)")
    var cursor: Bool?

    @Option(help: "開始前カウントダウン (秒)")
    var countdown: Int = 0

    @Option(help: "プリセット: meeting = ウィンドウ対話選択 + system + mic + ミックス")
    var preset: String?

    @Option(help: "グローバルホットキーで開始 / 停止 (例: cmd+shift+r。未指定時は設定 hotkey を使用)")
    var hotkey: String?

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
        if let audioTracks, AudioTrackPolicy(name: audioTracks) == nil {
            throw ValidationError("--audio-tracks は mixed か separate を指定してください")
        }
        if let fps, fps <= 0 {
            throw ValidationError("--fps は 1 以上の整数を指定してください")
        }
        if let codec, VideoCodecKind(rawValue: codec) == nil {
            throw ValidationError("--codec は h264 / hevc / prores を指定してください")
        }
        for a in audio where a != "none" && AudioSourceSpec.parse(a) == nil {
            throw ValidationError("--audio の値が不正: \(a) (system / mic / device:<名前> / none)")
        }
        if let d = duration, parseDuration(d) == nil {
            throw ValidationError("--duration の形式が不正: \(d) (例: 30s, 5m)")
        }
        if let hotkey {
            do {
                _ = try HotkeyParser.parse(hotkey)
            } catch {
                throw ValidationError("\(error)")
            }
            // 待機モードでは countdown は「待機開始までの」カウントになって録画の
            // 開始を守れなくなる (守るなら開始後のカウントダウンで別機能)。
            // 挙動が期待とずれるのを避けるため併用を拒否する
            if countdown > 0 {
                throw ValidationError("--countdown と --hotkey は併用できません (カウントダウンが待機前に消費されるため)")
            }
        }
    }

    mutating func run() {
        // SCK ウィンドウ収録に必要な WindowServer 初期化 (SPIKE-NOTES F-D.3)。
        // 録画経路でのみ行い、他のサブコマンドを GUI セッションに依存させない。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 設定ファイルの不正は対話 (meeting のウィンドウ選択) より前に失敗させる
        let config: KildeConfig
        do {
            config = try ConfigStore.load()
        } catch {
            cliError(error)
        }
        let resolvedHotkey: String?
        do {
            resolvedHotkey = try HotkeySettings.resolve(explicit: hotkey, config: config)
        } catch {
            cliError(error)
        }
        // validate() は CLI 引数しか見られないため、設定ファイルの hotkey との組合せは
        // ここで初めて分かる。カウントダウンが待機前に消費される挙動は期待とずれるので
        // 設定由来も同じく拒否する (設定値との組合せエラーのため終了コードは 1)
        if resolvedHotkey != nil, countdown > 0 {
            cliError(KilError.failed("--countdown と hotkey は併用できません (カウントダウンが待機前に消費されるため)"))
        }

        var options = RecordOptions()
        options.displayIndex = display ?? 0
        options.wantsVideo = !noVideo
        options.duration = parseDuration(duration)
        options.autoMonitor = monitor

        // CLI 引数 > プリセット > 環境変数 > 設定ファイル > 既定値 の解決は KildeCore 側
        // (GUI も同じ規則で設定を読むため)。出力 URL もここで一度だけ決まる
        var overrides = RecordOverrides()
        overrides.outputPath = output ?? outputPositional
        overrides.audio = audio
        overrides.audioTracks = audioTracks
        overrides.codec = codec
        overrides.fps = fps
        overrides.showsCursor = cursor
        overrides.meetingPreset = preset == "meeting"
        do {
            try RecordSettings.apply(overrides, config: config,
                                     environment: ProcessInfo.processInfo.environment,
                                     to: &options)
        } catch {
            cliError(error)
        }

        // meeting のウィンドウ選択は設定・保存先の検証を通ってから (不正な設定で対話後に失敗させない)
        if preset == "meeting" && window == nil {
            do {
                if let picked = try promptWindowSelection() {
                    window = picked
                }
            } catch {
                cliError(error)
            }
        }
        options.windowMatch = window

        if countdown > 0 {
            for i in stride(from: countdown, through: 1, by: -1) {
                print("開始まで \(i)...", terminator: "\r")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }
            print("                        \r", terminator: "")
        }
        if overrides.outputPath == nil && (countdown > 0 || preset == "meeting") {
            // 既定の出力名は録画開始時刻にしたい。検証は対話・カウントダウンより前に済ませたが、
            // その間に時刻が進むので既定名だけ取り直す (解決規則を揃えるため同じ apply を再実行する)
            do {
                try RecordSettings.apply(overrides, config: config,
                                         environment: ProcessInfo.processInfo.environment,
                                         to: &options)
            } catch {
                cliError(error)
            }
        }

        if let resolvedHotkey {
            waitForHotkey(resolvedHotkey, options: options, overrides: overrides, config: config)
        } else {
            runImmediately(options: options)
        }
    }

    // MARK: - 実行モード

    /// 従来の即時録画経路。--hotkey 未指定かつ設定もない場合の挙動を変えない。
    private func runImmediately(options: RecordOptions) {
        let recorder = Recorder(options: options)
        installStopSignalHandler { [weak recorder] in
            recorder?.stop()
        }
        // 一時停止 / 再開 (issue #11)。SIGUSR1 と 'p' キーのどちらもトグル
        installPauseSignalHandler { [weak recorder] in
            guard let recorder else { return }
            if recorder.isPaused { recorder.resume() } else { recorder.pause() }
        }
        let pauseKey = startPauseKeyWatcher(recorder)
        defer { stopPauseKeyWatcher(pauseKey) }

        let result: Result<Recorder.Summary, Error>
        let pauseHint = pauseKey != nil ? " / p で一時停止・再開" : " / SIGUSR1 で一時停止・再開"
        print("● 録画\(!options.wantsVideo ? " (音声のみ)" : "") → \(options.outputURL!.path)  (Ctrl+C で停止\(pauseHint))")
        let ticker = startStatusTicker(recorder)
        result = Result { try recorder.run() }
        ticker.cancel()
        finish(recorder: recorder, result: result)
    }

    /// Carbon イベントを受け取るためメイン RunLoop を維持し、Recorder.run() の
    /// 長時間ブロックだけをワーカーへ逃がす。状態の変更はすべてメインキュー上で行う。
    private func waitForHotkey(_ source: String, options: RecordOptions,
                               overrides: RecordOverrides, config: KildeConfig) {
        var ticker: DispatchSourceTimer?
        var outcome: HotkeyRecordingController.Outcome?

        do {
            let controller = try HotkeyRecordingController(
                hotkey: source, options: options, overrides: overrides, config: config,
                environment: ProcessInfo.processInfo.environment,
                onStarted: { recorder, startedOptions, normalized in
                    print("● 録画\(!startedOptions.wantsVideo ? " (音声のみ)" : "") → \(startedOptions.outputURL!.path)  (Ctrl+C / \(normalized) で停止)")
                    ticker = startStatusTicker(recorder)
                },
                onFinished: { result in
                    ticker?.cancel()
                    outcome = result
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            )
            try controller.start()
            installStopSignalHandler {
                controller.requestStop()
            }
            print("⏳ 待機中 — \(controller.normalizedHotkey) で開始 / Ctrl+C で終了")
            // stdout がファイルにリダイレクトされていると C stdio はフルバッファになり、
            // この後 RunLoop で無期限にブロックするため「待機中」が exit まで出ない。
            // 統合テスト (T13) はこの行をログから待つので、ここで必ず吐き出す
            fflush(stdout)
            while outcome == nil {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        } catch {
            cliError(error)
        }

        switch outcome! {
        case .cancelled:
            return
        case .failed(let error):
            cliError(error)
        case .completed(let recorder, let result):
            finish(recorder: recorder, result: result)
        }
    }

    private func finish(recorder: Recorder, result: Result<Recorder.Summary, Error>) {
        print("")
        for warning in recorder.cleanupWarnings {
            FileHandle.standardError.write("WARNING: \(warning)\n".data(using: .utf8)!)
        }
        switch result {
        case .success(let summary):
            printSummary(summary)
            if !recorder.cleanupWarnings.isEmpty {
                Darwin.exit(1)
            }
        case .failure(let error):
            cliError(error)
        }
    }

    // MARK: - 内部

    /// meeting プリセット用のウィンドウ対話選択。nil ならディスプレイ全体。
    /// 戻り値は windowID (選択したウィンドウを確実に再解決できる)。
    private func promptWindowSelection() throws -> String? {
        let windows = try DisplayCatalog.listOnScreenWindows()
        let sorted = windows.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        print("収録するウィンドウを選択してください:")
        for (i, w) in sorted.enumerated() {
            print("  [\(i)] \(w)")
        }
        for _ in 0..<3 {
            print("番号を入力 (空欄 Enter でディスプレイ全体): ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
                // 非対話実行で意図せず全画面を収録しないよう、明示指定を要求する
                throw KilError.failed("ウィンドウ選択の入力がありません (非対話実行では --window を指定してください)")
            }
            if line.isEmpty { return nil }
            if let n = Int(line), sorted.indices.contains(n) {
                return String(sorted[n].windowID)
            }
            print("  無効な入力です。0...\(sorted.count - 1) の番号を入力してください。")
        }
        // 誤入力を全画面指定として扱うと収録範囲が広がるため、安全側で中止する
        throw KilError.failed("有効なウィンドウ番号が入力されませんでした (--window で直接指定もできます)")
    }

    /// 録画中に stdin の 'p' で一時停止 / 再開する (issue #11)。
    /// stdin が端末でないとき (パイプ・リダイレクト・統合テスト) は何もしない —
    /// 端末以外を raw mode にしても入力は来ず、呼び出し元のシェルの端末設定を壊しかねないため
    private func startPauseKeyWatcher(_ recorder: Recorder) -> DispatchSourceRead? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        // 1 文字ずつ即座に受け取り、画面にエコーしない (ステータス行が乱れる)
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        pauseKeyOriginalTermios = original
        let src = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO,
                                                queue: DispatchQueue(label: "kilde.pausekey"))
        src.setEventHandler { [weak recorder] in
            var ch: UInt8 = 0
            guard read(STDIN_FILENO, &ch, 1) == 1, let recorder else { return }
            guard ch == UInt8(ascii: "p") || ch == UInt8(ascii: "P") else { return }
            if recorder.isPaused { recorder.resume() } else { recorder.pause() }
        }
        src.resume()
        return src
    }

    /// 端末の設定を必ず戻す (戻さないとシェルのエコーが効かないままになる)
    private func stopPauseKeyWatcher(_ source: DispatchSourceRead?) {
        source?.cancel()
        if var original = pauseKeyOriginalTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            pauseKeyOriginalTermios = nil
        }
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
            // 一時停止中は PAUSED を出す。経過時間は一時停止ぶんを引いた値なので止まって見える
            let label = p.isPaused ? "PAUSED" : "REC"
            print(String(format: "\r%@ %02d:%02d | %@ | %@   ", label, m, s, size, levels), terminator: "")
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
        if s.pausedDuration > 0 {
            print(String(format: "一時停止: 合計 %.1fs (出力ファイルの長さには含まれません)", s.pausedDuration))
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
