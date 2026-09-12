import Foundation
import AppKit
import ArgumentParser
import KildeCore
import Darwin

/// 'p' キー監視で raw mode にする前の端末設定 (復元用)。
/// ParsableCommand の struct にプロパティを増やすと引数の解析対象と紛れるため、
/// 既存の signalSources と同じくファイルスコープに置く
private var pauseKeyOriginalTermios: termios?

/// 待機モード (--hotkey) で使う 'p' キー監視。onStarted の中からは触れないため
/// ファイルスコープに置く (signalSources と同じ理由)
private var pauseKeyWatcher: DispatchSourceRead?

struct RecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rec",
        abstract: "録画 / 録音を開始する (Ctrl+C で安全に停止)"
    )

    @Option(help: "収録ディスプレイの番号 (kilde devices で確認。既定 0)")
    var display: Int?

    @Option(help: "ウィンドウ単位で収録 (title / bundleID / windowID の部分一致)。音声もそのアプリにスコープされる。複数回指定するとそのウィンドウ群をまとめて収録 (出力はディスプレイ全体の大きさになり、対象外は黒で埋まる)")
    var window: [String] = []

    @Option(help: "ディスプレイ収録から除外するアプリの bundleID (完全一致、複数回指定可。kilde devices で確認)。映像だけでなくそのアプリのシステム音声も出力に入らない。--window / --no-video / --preset meeting とは併用不可")
    var excludeApp: [String] = []

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

    @Option(help: "出力コンテナ: mov (既定) / mp4。出力パスの拡張子が .mp4 なら自動で mp4 になる。MP4 に ProRes は入れられない")
    var format: String?

    @Option(help: "上限フレームレート (1 以上。0 以下は終了コード 64。未指定は設定 fps、どちらも無ければ SCK 既定)")
    var fps: Int?

    // --no-cursor は M1 からの互換。設定 showsCursor=false を 1 回だけ打ち消せるよう --cursor も受ける
    @Flag(inversion: .prefixedNo, help: "カーソルを写り込む / 写り込まない (既定: 写り込む。設定 showsCursor で変更可、--cursor は false をその回だけ打ち消す)")
    var cursor: Bool?

    @Flag(help: "HDR で収録する (macOS 15 以降 + HDR ディスプレイ + --codec hevc。条件を満たさない環境では警告して SDR で録る)")
    var hdr: Bool = false

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
            if !window.isEmpty {
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
        if !excludeApp.isEmpty {
            // 除外はディスプレイ収録の絞り込みなので、収録対象を選ぶ指定とは両立しない。
            // 黙って無視すると「除外したのに写っている」ことになり、画面を見るまで気づけない
            if !window.isEmpty {
                throw ValidationError("--exclude-app と --window は併用できません (ウィンドウ収録では対象を選ぶため除外は使いません)")
            }
            if noVideo {
                throw ValidationError("--exclude-app と --no-video は併用できません (映像を録らないため除外が効きません)")
            }
            // --region と同じ理由: meeting は validate() の後にウィンドウを選ぶので、
            // ここで弾かないと選択結果次第で除外が効いたり効かなかったりする
            if preset == "meeting" {
                throw ValidationError("--exclude-app と --preset meeting は併用できません (meeting はウィンドウを選んで収録するため)")
            }
            if excludeApp.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw ValidationError("--exclude-app には bundleID を指定してください (例: com.apple.Safari)")
            }
        }
        if let codec, VideoCodecKind(rawValue: codec) == nil {
            throw ValidationError("--codec は h264 / hevc / prores を指定してください")
        }
        if hdr {
            // HDR は 10-bit の HEVC (Main10) で書くので、他のコーデックでは成立しない。
            // 黙って HEVC に変えると「指定した codec と違うもので録れる」ことになるので弾く
            if let codec, codec != "hevc" {
                throw ValidationError("--hdr は --codec hevc と組み合わせてください (指定: \(codec))")
            }
            if noVideo {
                throw ValidationError("--hdr と --no-video は併用できません (映像を録らないため HDR が効きません)")
            }
        }
        if let format {
            guard ContainerKind(rawValue: format.lowercased()) != nil else {
                throw ValidationError("--format は mov か mp4 を指定してください")
            }
            // 音声のみの出力は M4A で固定なので、指定しても効かない
            if noVideo {
                throw ValidationError("--format と --no-video は併用できません (音声のみの出力は M4A です)")
            }
        }
        // コンテナは --format だけでなく出力パスの拡張子でも決まる (kilde rec demo.mp4)。
        // CLI で分かる組合せは終了コード 64 で弾く契約なので、実効コンテナで検証する
        // (設定ファイル由来の codec との組合せだけは KildeCore 側で 1 になる)
        let effectiveContainer: ContainerKind? = {
            if let format { return ContainerKind(rawValue: format.lowercased()) }
            guard let path = output ?? outputPositional else { return nil }
            return ContainerKind(rawValue: URL(fileURLWithPath: path).pathExtension.lowercased())
        }()
        if !noVideo, let codec, let kind = VideoCodecKind(rawValue: codec),
           let container = effectiveContainer, !container.supports(kind) {
            throw ValidationError(
                "\(container.rawValue.uppercased()) コンテナに \(codec) は入れられません "
                + "(--codec h264 / hevc か --format mov)")
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

        // HDR 対応ディスプレイの判定は NSScreen = メインスレッドが要る。
        // Recorder のセッションから呼ぶと、run() が塞いでいるメインスレッドへ
        // ディスパッチすることになってデッドロックするので、ここで先に済ませる
        // (KildeCore.Recorder は MainActor を要求しない — CLAUDE.md §6)。
        //
        // ArgumentParser の main() はメインスレッドで走るのでこの関数もメインスレッド上だが、
        // 型の上では nonisolated なので assumeIsolated で表明する。await にしないのは、
        // ここが同期関数でありメインスレッドを手放せないため。前提が崩れれば
        // assumeIsolated がその場で落ちるので、黙って間違った値を使うことはない
        let hdrCapableDisplays = MainActor.assumeIsolated { DisplayHDR.capableDisplayIDs() }

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
        options.hdr = hdr
        options.hdrCapableDisplayIDs = hdrCapableDisplays

        // CLI 引数 > プリセット > 環境変数 > 設定ファイル > 既定値 の解決は KildeCore 側
        // (GUI も同じ規則で設定を読むため)。出力 URL もここで一度だけ決まる
        var overrides = RecordOverrides()
        overrides.outputPath = output ?? outputPositional
        overrides.audio = audio
        overrides.audioTracks = audioTracks
        overrides.codec = codec
        overrides.format = format
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
        if preset == "meeting" && window.isEmpty {
            do {
                if let picked = try promptWindowSelection() {
                    window = [picked]
                }
            } catch {
                cliError(error)
            }
        }
        options.windowMatches = window
        options.excludedBundleIDs = excludeApp

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
            var options = options
            reserveDefaultOutputIfNeeded(&options)
            runImmediately(options: options)
        }
    }

    // MARK: - 実行モード

    /// 既定名 (出力先の明示なし) のとき、表示の前に予約を確定させる。
    /// 予約は Recorder 内でも行えるが、後から -2 に退避すると「● 録画 → path」の表示が
    /// 実際の出力先と食い違うため、CLI は先に確定して正しいパスを表示する
    private func reserveDefaultOutputIfNeeded(_ options: inout RecordOptions) {
        do {
            try OutputFileReservation.resolveDefaultOutput(on: &options)
        } catch {
            cliError(error)
        }
    }

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
        let pauseKey = startPauseKeyWatcher { [weak recorder] in
            guard let recorder else { return }
            if recorder.isPaused { recorder.resume() } else { recorder.pause() }
        }
        defer { stopPauseKeyWatcher(pauseKey) }

        let result: Result<Recorder.Summary, Error>
        let pauseHint = pauseKey != nil ? " / p で一時停止・再開" : " / SIGUSR1 で一時停止・再開"
        print("● 録画\(!options.wantsVideo ? " (音声のみ)" : "") → \(options.outputURL!.path)  (Ctrl+C で停止\(pauseHint))")
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
        // 待機モードでも SIGUSR1 を掴む。既定の動作 (即時終了) のままだと
        // kill -USR1 でファイナライズされずに死に、壊れたファイルが残る
        var activeRecorder: Recorder?

        do {
            let controller = try HotkeyRecordingController(
                hotkey: source, options: options, overrides: overrides, config: config,
                environment: ProcessInfo.processInfo.environment,
                onStarted: { recorder, startedOptions, normalized in
                    activeRecorder = recorder
                    print("● 録画\(!startedOptions.wantsVideo ? " (音声のみ)" : "") → \(startedOptions.outputURL!.path)  (Ctrl+C / \(normalized) で停止 / SIGUSR1 で一時停止・再開)")
                    ticker = startStatusTicker(recorder, wantsVideo: startedOptions.wantsVideo)
                },
                onFinished: { result in
                    ticker?.cancel()
                    outcome = result
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            )
            // controller.start() より前にシグナルの設置を済ませる — pthread_sigmask は
            // 呼び出しスレッド (メイン) しかブロックしないため、ホットキー監視等の
            // スレッドが生まれる前に窓を閉じておかないと、プロセス宛シグナルが
            // ブロックされていない別スレッドへ配送されて SIG_IGN 破棄されうる (issue #67)
            installStopSignalHandler {
                controller.requestStop()
            }
            // 録画が始まっていなければ何もしない (待機中の SIGUSR1 と 'p' は無視)
            // activeRecorder は onStarted (メインキュー) で書かれ、シグナルと 'p' キーは
            // それぞれ別のキューから読む。メインキューへ直列化しないとデータ競合になり、
            // 両方が同時に来たときに同じ isPaused を見て一方のトグルが失われる
            let toggle = {
                DispatchQueue.main.async {
                    guard let recorder = activeRecorder else { return }
                    if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                }
            }
            installPauseSignalHandler(toggle)
            // 待機経路でも 'p' キーを使えるようにする (即時録画と操作を揃える)
            pauseKeyWatcher = startPauseKeyWatcher(toggle)
            defer { stopPauseKeyWatcher(pauseKeyWatcher); pauseKeyWatcher = nil }
            try controller.start()
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
        // この関数は Darwin.exit / cliError で戻らずに終わる経路があり、呼び出し元の
        // defer が走らない。端末を raw mode のままにするとユーザーのシェルで
        // エコーが効かなくなるため、ここで必ず戻す (二重復元は無害)
        restorePauseKeyTerminal()
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

    /// 録画中に stdin の 'p' で一時停止 / 再開する (issue #11)。
    /// stdin が端末でないとき (パイプ・リダイレクト・統合テスト) は何もしない —
    /// 端末以外を raw mode にしても入力は来ず、呼び出し元のシェルの端末設定を壊しかねないため
    private func startPauseKeyWatcher(_ toggle: @escaping () -> Void) -> DispatchSourceRead? {
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
        src.setEventHandler {
            var ch: UInt8 = 0
            guard read(STDIN_FILENO, &ch, 1) == 1 else { return }
            guard ch == UInt8(ascii: "p") || ch == UInt8(ascii: "P") else { return }
            toggle()
        }
        src.resume()
        return src
    }

    /// 端末の設定を必ず戻す (戻さないとシェルのエコーが効かないままになる)
    private func stopPauseKeyWatcher(_ source: DispatchSourceRead?) {
        source?.cancel()
        restorePauseKeyTerminal()
    }

    /// raw mode にした端末を元に戻す。戻す設定が無ければ何もしない (冪等)
    private func restorePauseKeyTerminal() {
        guard var original = pauseKeyOriginalTermios else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        pauseKeyOriginalTermios = nil
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
        if let reason = s.hdrFallback {
            // 録画は成功しているので終了コードは 0 のまま。ただし黙って SDR にすると
            // 「HDR で録れたつもりのファイル」ができるので、結果に必ず出す (issue #16)
            print("⚠ HDR: \(reason)")
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
