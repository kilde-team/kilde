import Foundation
import AppKit
import ArgumentParser
import KildeCore
import Darwin

struct RecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rec",
        abstract: "録画 / 録音を開始する (Ctrl+C で安全に停止)"
    )

    @Option(help: "収録ディスプレイの番号 (kilde devices で確認。既定 0)")
    var display: Int?

    @Option(help: "ウィンドウ単位で収録 (title / bundleID / windowID の部分一致)。音声もそのアプリにスコープされる")
    var window: String?

    @Option(help: "ディスプレイの一部だけを収録 x,y,w,h (ポイント座標、左上が原点)。幅・高さは 2 以上で偶数に切り捨て、ディスプレイの範囲外は録画前に失敗 (終了コード 1)。--window / --no-video / --preset meeting とは併用不可")
    var region: String?

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
        if let region {
            // 幅・高さの下限はディスプレイの情報が要らないので、ここで弾いて終了コードを
            // 64 (引数エラー) に揃える。Recorder まで持ち越すと範囲外と同じ 1 になってしまう
            if let r = parseRegion(region), r.width < 2 || r.height < 2 {
                throw ValidationError("--region の幅と高さは 2 ポイント以上にしてください: \(region)")
            }
            guard parseRegion(region) != nil else {
                throw ValidationError(
                    "--region は x,y,w,h の形式で指定してください (例: 0,0,1280,720。"
                    + "ポイント座標で左上が原点、幅と高さは正の数)")
            }
            // ウィンドウ収録には領域の概念がなく、音声のみでは映像自体が無い。
            // 黙って無視すると「指定したのに効かない」ので、ここで弾く
            if window != nil {
                throw ValidationError("--region と --window は併用できません (ウィンドウ収録に領域指定はありません)")
            }
            if noVideo {
                throw ValidationError("--region と --no-video は併用できません (映像を録らないため領域が効きません)")
            }
            // meeting プリセットは validate() の後、run() の対話でウィンドウを選ぶ。
            // ここで弾かないと「ウィンドウを選んだら region が無視され、空欄 Enter なら効く」と
            // 選択結果次第で挙動が変わってしまう
            if preset == "meeting" {
                throw ValidationError("--region と --preset meeting は併用できません (meeting はウィンドウを選んで収録するため)")
            }
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
        options.region = parseRegion(region)
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

        let result: Result<Recorder.Summary, Error>
        print("● 録画\(!options.wantsVideo ? " (音声のみ)" : "") → \(options.outputURL!.path)  (Ctrl+C で停止)")
        let ticker = startStatusTicker(recorder, wantsVideo: options.wantsVideo)
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
                    ticker = startStatusTicker(recorder, wantsVideo: startedOptions.wantsVideo)
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
            // 準備中の停止は「失敗」ではない — Ctrl+C は kilde の正規の停止操作なので
            // 0 で返す (DESIGN.md §6)。録画は 1 フレームも成立していないのでサマリは出さない
            // ただし後始末の警告 (monitor の復元失敗など) があるときは通常の失敗として扱う —
            // 既定出力が `kilde Monitor` のまま残っているのを exit 0 で隠さない
            if recorder.cancelledBeforeRecording {
                print(Recorder.cancelledDuringPreparationMessage)
                guard recorder.cleanupWarnings.isEmpty else {
                    // 非 0 で終わる原因は停止ではなく後始末の失敗 (既定出力が
                    // `kilde Monitor` のまま残っている)。停止そのものを失敗扱いする
                    // ERROR 行を出すと原因を取り違えさせるので、後始末の方を理由として出す
                    let message = "ERROR: 停止しましたが、既定の出力デバイスを復元できませんでした "
                        + "(上の WARNING を参照。`kilde audio monitor teardown` で復元できます)\n"
                    FileHandle.standardError.write(message.data(using: .utf8)!)
                    Darwin.exit(1)
                }
                return
            }
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

    private func startStatusTicker(_ recorder: Recorder, wantsVideo: Bool) -> DispatchSourceTimer {
        let q = DispatchQueue(label: "kilde.status")
        let timer = DispatchSource.makeTimerSource(queue: q)
        var warnedNoVideoFrames = false
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            guard let p = recorder.progress() else { return }
            // .recording のゲート: progress() はマイク権限ダイアログの待ちより前から
            // 値を返すため、ゲートしないと権限応答に 10 秒以上かけたユーザーに
            // 「映像が来ない」警告を誤爆する (実際には録画がまだ始まっていない)
            if wantsVideo && !warnedNoVideoFrames && recorder.currentState == .recording
                && p.elapsed >= 10 && p.videoAppended == 0 {
                warnedNoVideoFrames = true
                let warning = "WARNING: 開始から 10 秒間映像フレームが来ていません。ディスプレイの消灯/ロック中の可能性があります\n"
                FileHandle.standardError.write(warning.data(using: .utf8)!)
            }
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
