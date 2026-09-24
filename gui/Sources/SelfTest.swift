import AppKit
import KildeCore

/// 検証用のセルフテスト (issue #18): 環境変数が指定されたときだけ、UI を操作せずに
/// GUI と同じ経路 (RecordingSetup → RecordRequest → RecordingController → Recorder) で
/// ディスプレイ 0 + システム音声を録画して終了する。
///
///     KILDE_GUI_SELFTEST_RECORD=<秒> KILDE_GUI_SELFTEST_OUTPUT=<保存先ディレクトリ> \
///         KildeGUI.app/Contents/MacOS/KildeGUI
///
/// 完了すると出力パスを stdout に出して終了コード 0、失敗なら stderr に理由を出して 1。
/// ターミナルから実行ファイルを直接起動すると TCC の画面収録権限はターミナル側のものが使われる
/// (`open` で起動したアプリとは別扱い) ため、KildeGUI 自体に権限を付けなくても検証できる。
/// 「GUI から開始した録画が CLI と同じ Recorder を通り、同等のファイルが生成される」を
/// 機械的に確かめるためのもので、通常起動では何もしない
enum SelfTest {
    /// ポップオーバーの操作 (AppDelegate から渡す)。セルフテストでしか使わない
    struct PopoverControl {
        let show: () -> Void
        let close: () -> Void
        let isShown: () -> Bool
    }

    @MainActor
    static func runIfRequested(setup: RecordingSetup, recording: RecordingController,
                               permissions: PermissionsModel, updater: UpdaterCoordinator,
                               transcription: TranscriptionCoordinator, popover: PopoverControl) {
        let env = ProcessInfo.processInfo.environment
        // KILDE_GUI_SELFTEST_TRANSCRIBE: 文字起こし経路の検証。値で 2 つの経路を分ける。
        // 値 1 は録画なし版 (issue #146) — 入力音声を KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT で
        // 渡し、実録画を伴わないため録画のスロット (権限・スピーカー) を占有しない。
        // 2 以上の秒数は実録画版 (issue #150) — «録画 → 停止 → 自動文字起こし → 出力検証» の
        // 完全経路。実録画を伴うので並行する録画テストと同時に回さない
        if let transcribeText = env["KILDE_GUI_SELFTEST_TRANSCRIBE"] {
            if transcribeText == "1" {
                runTranscription(setup: setup, transcription: transcription)
            } else {
                // 秒数 1 は録画なし版と衝突するため実録画版では使えない (音声としても短すぎる)。
                // 無限大・過大値は Double("inf") が素通りして Task.sleep の UInt64 変換や
                // Int(秒数) で trap するので、«指定ミスは fail の契約どおり exit 1» に落とす
                guard let seconds = Double(transcribeText),
                      seconds.isFinite, seconds >= 2, seconds <= 3600 else {
                    fail("KILDE_GUI_SELFTEST_TRANSCRIBE は 1 (録画なし版) か 2〜3600 の秒数 (実録画版) で指定してください: \(transcribeText)")
                }
                runTranscribeWithRecording(
                    seconds: seconds, setup: setup, recording: recording,
                    transcription: transcription, popover: popover)
            }
            return
        }
        // KILDE_GUI_SELFTEST_TRANSCRIBE_CANCEL=1: «中止» の経路を確かめる (issue #146)。
        // 実録画を伴わない。enqueue 直後に cancelAll して、
        //   - running が nil に戻る (キャンセルが処理された)
        //   - lastCompletion / lastFailure が立たない (キャンセルは失敗に数えない)
        //   - サイドカーが存在しない (write に届かない = 出力ファイルが残らない)
        // の 3 点を見る。短い音声だと cancelAll 前に文字起こしが終わる競合があるため、
        // KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT には長め (目安 30 秒) の入力を渡すこと
        if env["KILDE_GUI_SELFTEST_TRANSCRIBE_CANCEL"] == "1" {
            runTranscriptionCancel(setup: setup, transcription: transcription)
            return
        }
        // KILDE_GUI_SELFTEST_UPDATE=1: Sparkle 自動更新の配線と設定を確かめる (issue #122)。
        // 終了は reportUpdateSetup の中 (canCheckForUpdates の待ちがあるため)。
        // App Store ビルドには Sparkle が無い (issue #126) のでこの検証は対象外
#if !APPSTORE
        if env["KILDE_GUI_SELFTEST_UPDATE"] == "1" {
            reportUpdateSetup(updater: updater)
            return
        }
#else
        // MAS ビルドには Sparkle が無いので検証できない。**黙って素通ししない** —
        // 素通しすると「終了しないセルフテスト」になり、直接起動したプロセスが
        // 常駐する (検証スクリプトがハングする。cubic レビュー指摘)
        if env["KILDE_GUI_SELFTEST_UPDATE"] == "1" {
            fail("KILDE_GUI_SELFTEST_UPDATE は MAS ビルドでは使えません (Sparkle 非搭載)")
        }
#endif
        // KILDE_GUI_SELFTEST_PERMISSIONS=1: 構成ごとに「何の権限を要求するか」を出して終わる (issue #19)。
        // 実際に TCC の許可を取り消さないと確かめられない部分 (案内の見た目) は人の目に頼るしかないが、
        // 「音声のみの録音に画面収録権限を求めない」のような判定はこれで機械的に確認できる
        if env["KILDE_GUI_SELFTEST_PERMISSIONS"] == "1" {
            reportPermissions(setup: setup, permissions: permissions)
            exit(0)
        }
        // KILDE_GUI_SELFTEST_NOTIFY=1: issue #20 の «通知・Finder 表示・最近の録画・ホットキー» を
        // UI 操作なしで確かめる。通知の配信自体は Notification Center の状態に依存して自動化
        // できないが、**kilde 側の責任範囲 (Finder に渡す URL が正しいか、一覧の走査が
        // 正しいか、ホットキーを登録できるか) は機械的に確かめられる**
        // 終了は reportNotifyTargets の中 (走査結果を待つ Task の末尾) で行う。
        // ここで exit(0) すると、走査の完了を待たずにプロセスが落ちる
        if env["KILDE_GUI_SELFTEST_NOTIFY"] == "1" {
            reportNotifyTargets(setup: setup)
            return
        }
        guard let text = env["KILDE_GUI_SELFTEST_RECORD"] else { return }
        guard let seconds = Double(text), seconds > 0 else {
            fail("KILDE_GUI_SELFTEST_RECORD は正の秒数で指定してください: \(text)")
        }
        // KILDE_GUI_SELFTEST_RECORD_TRANSCRIBE=1: 実録画の完了 → «AppDelegate が
        // 文字起こしを自動で積む» 配線を含めて確かめる (issue #146)。TRANSCRIBE 単体では
        // 確かめられなかった «録画完了 → 自動 enqueue» の経路を実録画 1 回で通す。
        // 実録画を伴うので録画のスロット (権限・スピーカー) を占有する — 実行時の注意は
        // RECORD と同じ (docs/DEVELOPMENT.md §3)
        let expectsTranscription = env["KILDE_GUI_SELFTEST_RECORD_TRANSCRIBE"] == "1"
        if expectsTranscription {
            guard setup.transcriptionAvailable else {
                fail("この環境で Transcriber.isSupported=false です (文字起こし非対応)")
            }
            // ユーザーの config を書き換えず、このプロセス内だけ有効化する
            // (TRANSCRIBE セルフテストと同じ考え)
            setup.transcribeEnabled = true
            print("selftest: transcribeEnabled forced=true for record (config は変更しません)")
        }
        applyRecordingRequest(setup, env: env)

        let options: RecordOptions
        do {
            options = try setup.makeOptions()
        } catch {
            fail("録画オプションを作れません: \(error)")
        }
        // KILDE_GUI_SELFTEST_POPOVER=close: 録画中にポップオーバーを閉じても録画が続くこと
        // (issue #18 の受け入れ条件) を確かめる。閉じた時点と終了時の出力サイズを出すので、
        // 閉じた後もファイルが伸びていれば録画が継続している
        let closesPopover = env["KILDE_GUI_SELFTEST_POPOVER"] == "close"
        if closesPopover {
            // LSUIElement のアプリをターミナルから起動すると非アクティブのままで、
            // その状態では NSPopover が表示されない (isShown が false のまま)。明示的にアクティブ化する
            NSApp.activate(ignoringOtherApps: true)
            popover.show()
            if !popover.isShown() {
                // アクティブ化やステータス項目の生成が間に合わないことがあるので 1 回だけ待って再試行する
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                popover.show()
            }
            guard popover.isShown() else {
                // この時点ではまだ recording.start していないため、makeOptions が確保した
                // 予約の清掃を Recorder に任せられない — 自分で片付けてから失敗する
                if let r = options.outputReservation, !r.removeIfStillReserved() {
                    FileHandle.standardError.write(
                        "WARNING: 予約した出力ファイルを削除できませんでした: \(r.url.path)\n"
                            .data(using: .utf8)!)
                }
                fail("ポップオーバーを開けませんでした (isShown=false)")
            }
            print("selftest: popover shown=true")
            fflush(stdout)
        }

        let closed = ClosedState()

        recording.whenSessionEnds {
            switch recording.phase {
            case .finished(let url):
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
                    .flatMap { $0 } ?? 0
                // close に失敗した場合は既に fail() が原因を出し、停止 → ファイナライズを待っている。
                // ここで先に進むと exit(0) が fail() の exit(1) を追い越し、**失敗を成功と誤判定する**。
                // ハンドラからは戻るだけにして、fail() 側の exit(1) に処理を譲る
                if closesPopover, closed.closeFailed {
                    return
                }
                if closesPopover {
                    // 「閉じた後も録画が進んだ」ことを成功条件にする。outputBytes は
                    // フレームの来ない環境では増えないので、経過時間 (progress 由来) で見る
                    guard let closedAt = closed.elapsed else {
                        fail("ポップオーバーを閉じる前に録画が終わりました")
                    }
                    guard recording.elapsed > closedAt else {
                        fail("ポップオーバーを閉じた後に録画が進んでいません (elapsed \(closedAt)s のまま)")
                    }
                    print("selftest: recording continued after close "
                        + "(elapsed \(String(format: "%.1f", closedAt))s → \(String(format: "%.1f", recording.elapsed))s)")
                }
                print("selftest: finished \(url.path) bytes=\(bytes) popoverShown=\(popover.isShown())")
                fflush(stdout)
                if expectsTranscription {
                    // 録画完了 → AppDelegate の sink が文字起こしを積む → 完了を待つ。
                    // «パネルを閉じても文字起こしが完了する» (受け入れ条件①) は、
                    // coordinator が AppDelegate 所有で popover の寿命に縛られない
                    // 構造の保証 + この経路の実機確認の両方で担保する。
                    // whenSessionEnds のハンドラは同期なので、待ちの Task を積んで戻る
                    print("selftest: waiting for transcription of \(url.lastPathComponent)")
                    fflush(stdout)
                    awaitTranscriptionResult(
                        recordingURL: url, setup: setup, transcription: transcription)
                    return
                }
                exit(0)
            case .failed(let message):
                fail("録画に失敗: \(message)")
            default:
                fail("想定外の状態で終了: \(recording.phase)")
            }
        }
        // 失敗時に停止 → ファイナライズできるよう、開始前に覚えておく
        active = recording
        recording.start(options)
        guard closesPopover else {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                recording.stop()
            }
            return
        }
        Task { @MainActor in
            // start() は .recording への遷移を待たずに返るので、実際に録画が始まってから閉じる
            let deadline = Date().addingTimeInterval(20)
            while recording.phase != .recording, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard recording.phase == .recording else {
                fail("録画が始まりません (phase=\(recording.phase))")
            }
            // KILDE_GUI_SELFTEST_FORCE_CLOSE_FAIL=1 のときは閉じない — 「閉じられなかったときに
            // ちゃんと失敗する (exit 1)」ことを確かめるための経路 (この確認が無かったために、
            // 閉じ失敗が exit 0 になる回帰を見逃した)
            if env["KILDE_GUI_SELFTEST_FORCE_CLOSE_FAIL"] != "1" {
                popover.close()
            }
            // 閉じるのはアニメーション付きで、isShown はその間 true のままになる。
            // 固定待ちだと環境次第で取りこぼすのでポーリングで待つ
            let closeDeadline = Date().addingTimeInterval(3)
            while popover.isShown(), Date() < closeDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !popover.isShown() else {
                closed.closeFailed = true
                fail("ポップオーバーを閉じられませんでした (3 秒待っても isShown=true)")
            }
            closed.elapsed = recording.elapsed
            print("selftest: popover closed shown=false"
                + " elapsed=\(String(format: "%.1f", recording.elapsed))s bytes=\(recording.outputBytes)")
            fflush(stdout)
            // 閉じた後に進捗 (0.5 秒周期) が何度か来る時間を置いてから停止する
            try? await Task.sleep(nanoseconds: UInt64(max(2.0, seconds / 2) * 1_000_000_000))
            recording.stop()
        }
    }

    /// Sparkle 自動更新の検証 (KILDE_GUI_SELFTEST_UPDATE=1、issue #122)。
    ///
    /// 自動で確かめられるのはここまで、という線引きを明示しておく:
    /// - **確かめられる**: Info.plist の SUFeedURL / SUPublicEDKey / CFBundleVersion、
    ///   UpdaterCoordinator が AppDelegate に繋がって更新チェック可能になること、
    ///   録画中のインストール判定 (installAction) の全ケース
    /// - **確かめられない**: 更新のダウンロード・EdDSA 検証・インストール・再起動。
    ///   これらは Developer ID 署名同士のビルドでしか成立せず、実機 E2E は
    ///   v0.3.0 → v0.3.1 のリリースで手動確認する — ここで «通った» にしない
#if !APPSTORE
    @MainActor
    private static func reportUpdateSetup(updater: UpdaterCoordinator) {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = info["SUFeedURL"] as? String ?? ""
        print("selftest: SUFeedURL=\(feedURL)")
        // **完全一致で検証する** — hasPrefix/hasSuffix の緩い形式チェックだと、ホストや
        // パスの打ち間違い (appcast を別リポジトリに置く等) が通ってしまう。latest の
        // 固定 URL は Release を作るたびに appcast の場所が変わらないという SUFeedURL の
        // 契約の一部なので、ここで崩れていないことを機械的に保証する
        guard feedURL == "https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml" else {
            fail("SUFeedURL が GitHub Releases の appcast.xml 固定 URL と一致しません: \(feedURL)")
        }
        let publicEDKey = info["SUPublicEDKey"] as? String ?? ""
        print("selftest: SUPublicEDKey=\(publicEDKey.isEmpty ? "(空)" : publicEDKey)")
        guard !publicEDKey.isEmpty else {
            fail("SUPublicEDKey が空です (EdDSA 公開鍵が Info.plist にありません)")
        }
        let build = info["CFBundleVersion"] as? String ?? ""
        print("selftest: CFBundleVersion=\(build)")
        guard !build.isEmpty else {
            fail("CFBundleVersion が空です (sparkle:version の比較に使うため必須)")
        }

        // AppDelegate の配線も確認する — ポップオーバーのボタンが押す先と
        // 同じインスタンスかどうか (delegate 経由で別物になる退行を見張る)
        let delegate = AppDelegate.shared
        print("selftest: delegate=\(delegate == nil ? "nil" : "ok")"
            + " updaterOwned=\(delegate.map { $0.updater === updater } ?? false)")
        guard let delegate, delegate.updater === updater else {
            fail("AppDelegate が別の UpdaterCoordinator を持っています (配線を確認してください)")
        }

        // canCheckForUpdates は Sparkle の初期化が終わると true になる。KVO 由来の
        // 同期更新なので RunLoop を回して待てる (Swift Concurrency の待ちではない)
        let deadline = Date().addingTimeInterval(5)
        while !updater.canCheckForUpdates, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print("selftest: canCheckForUpdates=\(updater.canCheckForUpdates)")
        guard updater.canCheckForUpdates else {
            fail("updater が更新チェック可能になりませんでした (Sparkle の初期化に失敗?)")
        }

        // installAction の全ケース (録画中 / 通知待ち / 待機中 / 両方)。実際に録画を
        // 始めずに判定だけを確かめる — 停止 → ファイナライズ → 再起動のつなぎ目は
        // UpdateInstallGate が applicationShouldTerminate と同じパターンで書いている
        let cases: [(String, Bool, Bool, UpdaterCoordinator.InstallAction)] = [
            ("録画中", true, false, .afterStop),
            ("通知待ち", false, true, .afterNotification),
            ("待機中", false, false, .immediate),
            ("録画中+通知待ち", true, true, .afterStop),
        ]
        for (name, active, awaiting, expected) in cases {
            let actual = UpdaterCoordinator.installAction(isActive: active, awaitingNotification: awaiting)
            guard actual == expected else {
                fail("installAction(\(name)) が \(actual)、期待は \(expected)")
            }
            print("selftest: installAction[\(name)]=\(actual)")
        }
        fflush(stdout)
        exit(0)
    }
#endif

    /// 権限の判定結果を構成ごとに出す (KILDE_GUI_SELFTEST_PERMISSIONS=1)。
    /// 判定は PermissionsModel が CLI の `kilde doctor` と同じ Permissions を使って行う
    @MainActor
    private static func reportPermissions(setup: RecordingSetup, permissions: PermissionsModel) {
        permissions.refresh()
        print("selftest: screen=\(permissions.screenGranted) mic=\(permissions.micStatus)")
        let cases: [(String, (inout RecordRequest) -> Void)] = [
            ("画面 + システム音声", {
                $0.target = .display(index: 0); $0.captureSystemAudio = true
                $0.captureMic = false; $0.inputDevices = []
            }),
            ("画面 + マイク", {
                $0.target = .display(index: 0); $0.captureSystemAudio = false
                $0.captureMic = true; $0.inputDevices = []
            }),
            ("音声のみ + システム音声", {
                $0.target = .audioOnly; $0.captureSystemAudio = true
                $0.captureMic = false; $0.inputDevices = []
            }),
            ("音声のみ + マイクのみ", {
                $0.target = .audioOnly; $0.captureSystemAudio = false
                $0.captureMic = true; $0.inputDevices = []
            }),
            ("音声のみ + 入力デバイス指定", {
                $0.target = .audioOnly; $0.captureSystemAudio = false
                $0.captureMic = false; $0.inputDevices = ["BlackHole 2ch"]
            }),
        ]
        for (name, mutate) in cases {
            var request = setup.request
            mutate(&request)
            let missing = permissions.missing(for: request)
            let missingText = missing.isEmpty
                ? "なし"
                : missing.map { String(describing: $0) }.joined(separator: ",")
            print("selftest: [\(name)] needsScreen=\(PermissionsModel.needsScreen(request))"
                + " needsMic=\(PermissionsModel.needsMic(request)) missing=\(missingText)")
        }
        fflush(stdout)
    }

    /// issue #20 の検証 (KILDE_GUI_SELFTEST_NOTIFY=1)。
    ///
    /// 自動で確かめられるのはここまで、という線引きを明示しておく:
    /// - **確かめられる**: 最近の録画の走査結果、Finder に渡す URL、存在しないファイルの
    ///   フォールバック先、ホットキーを Carbon に登録できるか
    /// - **確かめられない**: 通知バナーが実際に出るか (Notification Center の状態と TCC 次第)、
    ///   バナーのクリックで Finder が前面に出るか、他アプリ前面でのキー押下が届くか。
    ///   これらは人の目と手が要る — PR に手順として書き、ここで «通った» ことにしない
    @MainActor
    private static func reportNotifyTargets(setup: RecordingSetup) {
        if let dir = ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_OUTPUT"] {
            // シンボリックリンクを解決しておく — /var は /private/var へのリンクなので、
            // 解決しないと «列挙で得た URL (解決済み)» と «環境変数から作った URL» が
            // 同じディレクトリを指しているのに別の文字列になり、検証側で比較できない
            setup.request.outputDirectory = URL(fileURLWithPath: dir, isDirectory: true)
                .resolvingSymlinksInPath()
        }
        print("selftest: outputDirectory=\(setup.request.outputDirectory.path)")

        // ホットキーは **AppDelegate が起動時に登録した結果**を報告する。
        //
        // ここで自前の `HotkeyMonitor` を作ってはいけない — `AppDelegate` が
        // `applicationDidFinishLaunching` で同じキーを登録済みで、Carbon の
        // 排他登録 (`kEventHotKeyExclusive`) は**同一プロセス内でも二重登録を拒む**ため、
        // 必ず失敗する。実際それで T21 が落ちた。
        //
        // 解決の経路 (設定ファイル → `HotkeySettings.resolve`) も `AppDelegate` が
        // 通っているので、登録できていること自体がその経路の検証になる
        // **throw と nil を潰さない。** `try?` でまとめると「設定に hotkey が無い」と
        // 「設定はあるが解釈できない」が同じ nil になり、後者を «未設定» として
        // 成功扱いにしてしまう (検証していないのに成功と報告しない、という方針に反する)
        let resolved: String?
        do {
            resolved = try HotkeySettings.resolve(explicit: nil, config: setup.config)
        } catch {
            print("selftest: hotkeyResolved=invalid error=\(error)")
            fflush(stdout)
            fail("設定の hotkey を解釈できません: \(error)")
        }
        print("selftest: hotkeyResolved=\(resolved ?? "none")")
        print("selftest: configPath=\(ConfigStore.fileURL.path)")
        print("selftest: configHotkey=\(setup.config.hotkey ?? "(なし)")")
        // registeredHotkey が nil のとき、原因は «登録失敗» とは限らない。
        // AppDelegate に届いていない / setup が別インスタンス / 呼ばれる順序、の
        // どれかを切り分けられるようにしておく
        let delegate = AppDelegate.shared
        print("selftest: delegate=\(delegate == nil ? "nil" : "ok")"
            + " sameSetup=\(delegate.map { $0.debugUsesSameSetup(setup) } ?? false)")
        let registered = delegate?.registeredHotkey
        if let registered {
            // **解決値と一致するかまで見る。** 非 nil というだけでは «古い登録が
            // 残っている» 場合も成功になり、設定を反映できていない退行を見逃す
            if registered != resolved {
                print("selftest: hotkeyRegistered=true source=\(registered)"
                    + " (解決値 \(resolved ?? "none") と一致しません)")
                fflush(stdout)
                fail("登録されたホットキー (\(registered)) が設定の解決結果"
                    + " (\(resolved ?? "none")) と一致しません")
            }
            print("selftest: hotkeyRegistered=true source=\(registered)")
        } else {
            // 失敗の理由は AppDelegate が notice に入れている。出さないと
            // «登録できなかった» としか分からず、原因の切り分けができない。
            //
            // **print して続行してはいけない** — 走査のタイムアウトを fail() にしたのと
            // 同じ理由で、検証していない (できていない) のに exit(0) で «成功» と
            // 報告することになる
            print("selftest: hotkeyRegistered=false resolved=\(resolved ?? "none")"
                + " notice=\(setup.notice ?? "(なし)")")
            fflush(stdout)
            // **«設定が無いから登録されていない» と «登録に失敗した» を分ける。**
            // 前者で「登録できませんでした」と exit 1 にすると、設定なしで手動実行
            // したときに原因を取り違える
            if resolved == nil {
                print("selftest: hotkeyUnset=true (設定に hotkey が無いので登録対象なし)")
                fflush(stdout)
            } else {
                fail("ホットキーを登録できませんでした (resolved=\(resolved!))")
            }
        }

        // 最近の録画の走査。結果は Task 経由で MainActor に届くので、**RunLoop を回しても
        // 届かない** — RunLoop.main.run(until:) は Swift Concurrency の main executor に
        // 積まれたタスクを実行しない。既存の待機 (popover.isShown / recording.isActive) が
        // RunLoop で成立しているのは、そちらが同期的に更新される状態を見ているため。
        // ここは await で待ってから出力し、終了もその中で行う
        setup.reloadRecentRecordings()
        Task { @MainActor in
            // 走査の «完了» を待つ。結果が空かどうかで判定すると、本当に 0 件の
            // ディレクトリでも 5 秒待たされ、しかも «未完了» と区別できない
            let deadline = Date().addingTimeInterval(5)
            while !setup.recentScanFinished, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("selftest: scanFinished=\(setup.recentScanFinished)")
            print("selftest: recentCount=\(setup.recentRecordings.count)")
            for url in setup.recentRecordings {
                print("selftest: recent=\(url.lastPathComponent)")
            }

            // Finder に渡す URL は **実装本体 (RecordingNotifier.revealTarget) に決めさせる**。
            // ここで分岐を書き写すと、実装が退行してもこの検証は通ってしまう
            if let first = setup.recentRecordings.first {
                let target = RecordingNotifier.revealTarget(for: first)
                print("selftest: revealTarget=\(target.url.path) select=\(target == .select(first))")
            }
            // 欠損ファイルの URL は **列挙で得た URL から作る** — outputDirectory は
            // 環境変数の文字列由来で /tmp のままだが、列挙結果は解決済みの
            // /private/tmp を返す。同じディレクトリなのに文字列が違うので、
            // 基準を揃えないと検証側で比較できない
            let baseDirectory = setup.recentRecordings.first?.deletingLastPathComponent()
                ?? setup.request.outputDirectory
            let missing = baseDirectory.appendingPathComponent("kilde-does-not-exist.mov")
            let fallback = RecordingNotifier.revealTarget(for: missing)
            print("selftest: revealFallback=\(fallback.url.path)"
                + " select=\(fallback == .select(missing))")
            fflush(stdout)
            // 走査が終わらないまま時間切れになったら **失敗として終える**。
            // exit(0) にすると、検証していないのに «成功» と報告することになる
            // (T21 は stdout も見るが、終了コードだけを見る手動実行が誤判定する)
            guard setup.recentScanFinished else {
                fail("最近の録画の走査が 5 秒で完了しませんでした")
            }
            exit(0)
        }
    }

    /// 文字起こし経路の検証 (KILDE_GUI_SELFTEST_TRANSCRIBE=1、issue #146)。
    ///
    ///     KILDE_GUI_SELFTEST_TRANSCRIBE=1 \
    ///         KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT=<音声ファイル> KildeGUI.app/Contents/MacOS/KildeGUI
    ///
    /// GUI 本体と同じ経路 (RecordingSetup の文字起こし設定 → TranscriptionCoordinator.Job →
    /// enqueue → モデル状態確認 → 必要ならモデル取得 → 文字起こし → サイドカー書き出し) を
    /// UI 操作なしで通す。入力は録画ファイルとして用意した音声 (say + afconvert で自作) を
    /// «録画の完了物» として渡す — エンジンの transcribeWithSpeakers はファイルを読むだけなので
    /// 録画である必要はない
    ///
    /// 自動で確かめられるのはここまで、という線引き:
    /// - **確かめられる**: enqueue → 完了 (lastCompletion) までのパイプライン、
    ///   サイドカーが録画ファイルの隣に書かれること (受け入れ条件②の «録画ファイルは残る» 側)
    /// - **確かめられない**: «録画完了 → 自動 enqueue» の配線 (実録画が要るため —
    ///   KILDE_GUI_SELFTEST_RECORD との組み合わせは手動確認に頼る)、オフラインでの
    ///   モデル取得失敗と再試行 (ネットワークの再現が要る。コード上は録画完了の sink から
    ///   切り離されているため、失敗しても録画機能に影響しない構造で担保)
    @MainActor
    private static func runTranscription(setup: RecordingSetup, transcription: TranscriptionCoordinator) {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT"], !input.isEmpty else {
            fail("KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT で音声ファイルを指定してください")
        }
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            fail("入力音声が存在しません: \(inputURL.path)")
        }
        // エンジンがこの環境で文字起こしに対応しているか。非対応環境では
        // «モデル取得に失敗» のような分かりにくい形ではなく、ここではっきり落とす
        guard setup.transcriptionAvailable else {
            fail("この環境で Transcriber.isSupported=false です (文字起こし非対応)")
        }
        // transcribeEnabled はユーザー設定 (~/.kilde/config.json) 由来で既定無効。
        // セルフテストは «設定を変えずに経路だけ» を確かめたいので、ここで強制有効にする
        // (RECORD が setup.request を直接弄るのと同じ考え)。ユーザーの config は書き換えない
        if !setup.transcribeEnabled {
            setup.transcribeEnabled = true
            print("selftest: transcribeEnabled forced=true (config は変更しません)")
        }
        let sidecar = TranscriptWriter.sidecarURL(forRecording: inputURL, format: setup.transcriptFormat)
        // 前回実行の残骸があると «書かれた» と誤判定するので先に消す
        try? FileManager.default.removeItem(at: sidecar)
        print("selftest: transcribe input=\(inputURL.lastPathComponent)"
            + " format=\(setup.transcriptFormat)"
            + " locale=\(setup.transcriptLocale ?? "(端末の言語設定)")")
        print("selftest: expect sidecar=\(sidecar.path)")
        fflush(stdout)
        // 本体と同じ «録画完了時のスナップショット» の形で Job を作る
        transcription.enqueue(TranscriptionCoordinator.Job(
            recordingURL: inputURL,
            format: setup.transcriptFormat,
            localeID: setup.transcriptLocale))
        // lastCompletion / lastFailure の更新は Swift Concurrency で届くため
        // RunLoop.main.run では観測できない (reportNotifyTargets のコメントと同じ理由) —
        // await で待つ。完了時の終了処理 (サイドカー検査と exit) は
        // awaitTranscriptionResult に共通化 (RECORD_TRANSCRIBE と同じ経路)
        awaitTranscriptionResult(recordingURL: inputURL, setup: setup, transcription: transcription)
    }

    /// 文字起こし 1 件の完了 (lastCompletion / lastFailure) を待ち、サイドカーの
    /// 存在と非空を確かめてから exit(0) する。TRANSCRIBE (入力音声を直接 enqueue) と
    /// RECORD_TRANSCRIBE (実録画の完了 → AppDelegate の sink が自動で enqueue) の
    /// 両方から使う — «録画が終わった後にどちらの経路で積まれても同じ検査を通る»
    /// ことを意図した共通化
    ///
    /// 初回は言語モデルの取得 (数GB 級) が入ることがあるので上限は長めに取る。
    /// 10 秒ごとに段階と進捗を出す — «止まっている» のと «進んでいる» を
    /// 外から区別できるようにするため
    @MainActor
    private static func awaitTranscriptionResult(
        recordingURL: URL, setup: RecordingSetup, transcription: TranscriptionCoordinator) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(600)
            var lastReport = Date()
            while transcription.lastCompletion == nil, transcription.lastFailure == nil,
                  Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Date().timeIntervalSince(lastReport) >= 10 {
                    print("selftest: waiting phase=\(transcriptPhaseText(transcription.runPhase))"
                        + " queue=\(transcription.queue.count)")
                    fflush(stdout)
                    lastReport = Date()
                }
            }
            if let failure = transcription.lastFailure {
                fail("文字起こしが失敗: \(failure.message)")
            }
            guard let completion = transcription.lastCompletion else {
                fail("文字起こしが 10 分で完了しませんでした (モデル取得が進んでいない?)")
            }
            // 書き出し先は TranscriptWriter の契約 (録画ファイルの隣) どおりか、
            // 存在するか、空でないかを見る。存在チェックだけだと別の場所に書いても
            // 通ってしまうので、期待パスと比較する (/tmp → /private/tmp の
            // symlink ゆらぎは両辺を解決して吸収する)。空ファイルなら «書けた» と
            // 偽る経路がないか確かめられない
            let expectedSidecar = TranscriptWriter.sidecarURL(
                forRecording: recordingURL, format: setup.transcriptFormat)
            guard completion.sidecarURL.resolvingSymlinksInPath().path
                    == expectedSidecar.resolvingSymlinksInPath().path else {
                fail("サイドカーの書き出し先が期待と違います: "
                    + "\(completion.sidecarURL.path) (期待 \(expectedSidecar.path))")
            }
            guard FileManager.default.fileExists(atPath: completion.sidecarURL.path) else {
                fail("サイドカーが存在しません: \(completion.sidecarURL.path)")
            }
            let bytes = (try? FileManager.default.attributesOfItem(
                atPath: completion.sidecarURL.path)[.size] as? Int).flatMap { $0 } ?? 0
            guard bytes > 0 else {
                fail("サイドカーが空です: \(completion.sidecarURL.path)")
            }
            print("selftest: transcribed segments->\(completion.sidecarURL.lastPathComponent)"
                + " bytes=\(bytes) job=\(completion.job.recordingURL.lastPathComponent)")
            fflush(stdout)
            exit(0)
        }
    }

    /// «中止» 経路の検証 (KILDE_GUI_SELFTEST_TRANSCRIBE_CANCEL=1、issue #146 の
    /// 受け入れ条件② «キャンセルで出力ファイルが残らず、録画ファイルは残る»)。
    ///
    ///     KILDE_GUI_SELFTEST_TRANSCRIBE_CANCEL=1 \
    ///         KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT=<長めの音声> KildeGUI.app/Contents/MacOS/KildeGUI
    ///
    /// enqueue 直後に cancelAll して、(1) running が nil に戻る、(2) lastCompletion /
    /// lastFailure が立たない、(3) サイドカーが残らない、の 3 点を見る。
    /// «キャンセルは失敗に数えない» 設計の回帰をここで落とす。
    /// «直後» を選ぶのは最悪ケースのため — エンジンの SpeechAnalyzer 初期化は
    /// キャンセル通知窓の外で走るので、この窓での中止は Task が hung しうる
    /// (実測)。hung は cancelAll 側の観測タイムアウト (5 秒) で UI 状態が
    /// 戻るため、このテストはその復帰経路も通る。進行中の中止 (onCancel 経由) は
    /// エンジン側で実測済み (kilde-cli-swift SpeechTranscriberEngine のコメント)
    @MainActor
    private static func runTranscriptionCancel(setup: RecordingSetup, transcription: TranscriptionCoordinator) {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT"], !input.isEmpty else {
            fail("KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT で音声ファイルを指定してください")
        }
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            fail("入力音声が存在しません: \(inputURL.path)")
        }
        guard setup.transcriptionAvailable else {
            fail("この環境で Transcriber.isSupported=false です (文字起こし非対応)")
        }
        // runTranscription と同じ «設定を変えずに経路だけ» の方針
        if !setup.transcribeEnabled {
            setup.transcribeEnabled = true
            print("selftest: transcribeEnabled forced=true (config は変更しません)")
        }
        let sidecar = TranscriptWriter.sidecarURL(forRecording: inputURL, format: setup.transcriptFormat)
        try? FileManager.default.removeItem(at: sidecar)
        print("selftest: transcribe-cancel input=\(inputURL.lastPathComponent)")
        print("selftest: expect no sidecar=\(sidecar.path)")
        fflush(stdout)
        transcription.enqueue(TranscriptionCoordinator.Job(
            recordingURL: inputURL,
            format: setup.transcriptFormat,
            localeID: setup.transcriptLocale))
        transcription.cancelAll()
        Task { @MainActor in
            // cancelAll は running を即 nil にしない設計 («止まっている途中» を
            // UI に見せる) ので、catch 経由で空になるのを待つ
            let deadline = Date().addingTimeInterval(60)
            while transcription.running != nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard transcription.running == nil else {
                fail("cancelAll 後 60 秒で running が空になりません (キャンセルが届いていない?)")
            }
            if transcription.lastCompletion != nil {
                fail("キャンセル後に lastCompletion が立っています (中止したのに完了扱い)")
            }
            if transcription.lastFailure != nil {
                fail("キャンセル後に lastFailure が立っています (キャンセルが失敗に数えられている)")
            }
            if FileManager.default.fileExists(atPath: sidecar.path) {
                fail("キャンセル後にサイドカーが残っています: \(sidecar.path)")
            }
            print("selftest: cancelled cleanly (no completion, no failure, no sidecar)")
            fflush(stdout)
            exit(0)
        }
    }

    /// «録画 → 停止 → 自動文字起こし → 出力検証» の完全経路
    /// (KILDE_GUI_SELFTEST_TRANSCRIBE=<秒>、issue #150)。
    ///
    ///     KILDE_GUI_SELFTEST_TRANSCRIBE=<秒> KILDE_GUI_SELFTEST_OUTPUT=<保存先ディレクトリ> \
    ///         KILDE_GUI_SELFTEST_AUDIO=device:BlackHole 2ch \
    ///         [KILDE_GUI_SELFTEST_POPOVER=close] KildeGUI.app/Contents/MacOS/KildeGUI
    ///
    /// #146 の録画なし版 (値が 1) と違い、**実録画を伴う**。録画中に say で作った
    /// テスト音声を再生し、停止後の «録画完了 → 自動 enqueue» (AppDelegate の配線) を
    /// 経て、サイドカーに «喋った内容のキーワード» が乗るまでを機械的に確かめる。
    /// KILDE_GUI_SELFTEST_POPOVER=close を重ねると、**パネルを閉じた状態でも**
    /// 録画も文字起こしも完了すること (TranscriptionCoordinator は AppDelegate 持ちで
    /// パネルに寿命がない) を検証する
    ///
    /// 実録画のため録画のスロット (権限・既定出力) を占有する — 並行する録画テスト
    /// (KILDE_GUI_SELFTEST_RECORD、kilde-cli-swift 側の統合テスト) と同時に回さない
    @MainActor
    private static func runTranscribeWithRecording(
        seconds: Double, setup: RecordingSetup, recording: RecordingController,
        transcription: TranscriptionCoordinator, popover: PopoverControl) {
        let env = ProcessInfo.processInfo.environment
        guard setup.transcriptionAvailable else {
            fail("この環境で Transcriber.isSupported=false です (文字起こし非対応)")
        }
        // 喋らせる文章と検索するキーワード。SpeechTranscriber の認識精度は環境次第なので
        // «全部一致» を要求せず、1 語でも乗っていれば成功とする (0 語は «無音» か
        // «認識失敗» で、どちらも «文字起こしが動いた» の証明にならない)
        let speechText = "これはマイクテストの録画です。テスト、テスト。以上です。"
        let keywords = ["テスト", "マイク", "録画"]
        // テスト音声は録画の前に作っておく。say と afplay は «既定出力デバイス» から鳴るので、
        // 内蔵スピーカーが使えない環境 (クラムシェル) では既定出力を BlackHole に向けて、
        // KILDE_GUI_SELFTEST_AUDIO=device:BlackHole 2ch で拾う (docs/DEVELOPMENT.md §3)
        let voice = env["KILDE_GUI_SELFTEST_SPEECH_VOICE"] ?? "Kyoko"
        let speechURL = makeSpeechSample(text: speechText, voice: voice)
        applyRecordingRequest(setup, env: env)
        let options: RecordOptions
        do {
            options = try setup.makeOptions()
        } catch {
            fail("録画オプションを作れません: \(error)")
        }
        // transcribeEnabled はユーザー設定 (~/.kilde/config.json) 由来で既定無効。
        // «録画完了 → 自動 enqueue» の配線 (AppDelegate の sink) はこの値を見るため、
        // 録画なし版と同じくメモリ上で強制有効にする (config は書き換えない)
        if !setup.transcribeEnabled {
            setup.transcribeEnabled = true
            print("selftest: transcribeEnabled forced=true (config は変更しません)")
        }
        let format = setup.transcriptFormat
        let closesPopover = env["KILDE_GUI_SELFTEST_POPOVER"] == "close"
        if closesPopover {
            // RECORD 版と同じ: LSUIElement のアプリをターミナルから起動すると
            // 非アクティブのままで NSPopover が出ないので、明示的にアクティブ化してから開く
            NSApp.activate(ignoringOtherApps: true)
            popover.show()
            if !popover.isShown() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                popover.show()
            }
            guard popover.isShown() else {
                // この時点ではまだ recording.start していないため、makeOptions が確保した
                // 予約の清掃を Recorder に任せられない — 自分で片付けてから失敗する
                if let r = options.outputReservation, !r.removeIfStillReserved() {
                    FileHandle.standardError.write(
                        "WARNING: 予約した出力ファイルを削除できませんでした: \(r.url.path)\n"
                            .data(using: .utf8)!)
                }
                fail("ポップオーバーを開けませんでした (isShown=false)")
            }
            print("selftest: popover shown=true")
            fflush(stdout)
        }

        let closed = ClosedState()

        recording.whenSessionEnds {
            switch recording.phase {
            case .finished(let url):
                // close に失敗した場合は既に fail() が原因を出し、停止 → ファイナライズを
                // 待っている (RECORD 版と同じ譲り)。ここで先へ進むと exit(1) を追い越し、
                // 失敗を成功と誤判定する
                if closesPopover, closed.closeFailed {
                    return
                }
                if closesPopover {
                    guard let closedAt = closed.elapsed else {
                        fail("ポップオーバーを閉じる前に録画が終わりました")
                    }
                    guard recording.elapsed > closedAt else {
                        fail("ポップオーバーを閉じた後に録画が進んでいません (elapsed \(closedAt)s のまま)")
                    }
                    print("selftest: recording continued after close "
                        + "(elapsed \(String(format: "%.1f", closedAt))s → \(String(format: "%.1f", recording.elapsed))s)")
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
                    .flatMap { $0 } ?? 0
                print("selftest: finished \(url.path) bytes=\(bytes) — waiting for transcription…")
                fflush(stdout)
                // ここでは exit しない — 文字起こしの完了まで待つ Task が検証と exit を担う
            case .failed(let message):
                fail("録画に失敗: \(message)")
            default:
                fail("想定外の状態で終了: \(recording.phase)")
            }
        }
        // 失敗時に停止 → ファイナライズできるよう、開始前に覚えておく
        active = recording
        recording.start(options)
        Task { @MainActor in
            // start() は .recording への遷移を待たずに返る。«録画が確実に進んだ状態» で
            // 音を鳴らすため、遷移を待ってから再生する
            let deadline = Date().addingTimeInterval(20)
            while recording.phase != .recording, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard recording.phase == .recording else {
                fail("録画が始まりません (phase=\(recording.phase))")
            }
            if closesPopover {
                popover.close()
                // 閉じるのはアニメーション付きで、isShown はその間 true のまま (RECORD 版と同じ)
                let closeDeadline = Date().addingTimeInterval(3)
                while popover.isShown(), Date() < closeDeadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard !popover.isShown() else {
                    closed.closeFailed = true
                    fail("ポップオーバーを閉じられませんでした (3 秒待っても isShown=true)")
                }
                closed.elapsed = recording.elapsed
                print("selftest: popover closed shown=false"
                    + " elapsed=\(String(format: "%.1f", recording.elapsed))s bytes=\(recording.outputBytes)")
                fflush(stdout)
            }
            // テスト音声を鳴らす (録画進行中)。再生完了は待たない — 音が出ている間も
            // 録画が回り続けることが本経路の狙い
            guard playAudio(speechURL) else {
                fail("テスト音声を再生できませんでした (/usr/bin/afplay)")
            }
            print("selftest: playing \(speechURL.lastPathComponent) during recording")
            fflush(stdout)
            // 指定秒数録画を続けてから停止する。秒数は音声の長さより十分長く取る
            // (目安は docs/DEVELOPMENT.md §3)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            recording.stop()
        }
        Task { @MainActor in
            // 1) 録画の完了を待つ (failed / 想定外は whenSessionEnds 側が fail で落とす)
            let recordDeadline = Date().addingTimeInterval(seconds + 60)
            var finishedURL: URL?
            while finishedURL == nil, Date() < recordDeadline {
                if case .finished(let url) = recording.phase {
                    finishedURL = url
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let recordingURL = finishedURL else {
                fail("録画が \(Int(seconds + 60)) 秒で終わりませんでした (phase=\(recording.phase))")
            }
            // 2) «録画完了 → 自動 enqueue» (AppDelegate の sink)。#146 の録画なし版では
            // 確かめられなかった部分 — 実録画があって初めて通る経路
            let enqueueDeadline = Date().addingTimeInterval(15)
            while !transcription.isBusy, transcription.lastCompletion == nil,
                  transcription.lastFailure == nil, Date() < enqueueDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // すぐ死んだジョブは «始まらない» ではなく «始まって失敗した» — 誤診しない
            if let failure = transcription.lastFailure {
                fail("文字起こしが失敗: \(failure.message)")
            }
            guard transcription.isBusy || transcription.lastCompletion != nil else {
                fail("録画完了後に文字起こしが始まりません"
                    + " (transcribeEnabled=\(setup.transcribeEnabled)"
                    + " available=\(setup.transcriptionAvailable))")
            }
            print("selftest: transcription enqueued after recording finished"
                + " (\(recordingURL.lastPathComponent))")
            fflush(stdout)
            // 3) 完了を待つ。上限は録画なし版と同じ 10 分 — 初回は言語モデルの取得
            // (数GB 級) が入ることがあるため
            let doneDeadline = Date().addingTimeInterval(600)
            var lastReport = Date()
            while transcription.lastCompletion == nil, transcription.lastFailure == nil,
                  Date() < doneDeadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Date().timeIntervalSince(lastReport) >= 10 {
                    print("selftest: waiting phase=\(transcriptPhaseText(transcription.runPhase))"
                        + " queue=\(transcription.queue.count)")
                    fflush(stdout)
                    lastReport = Date()
                }
            }
            if let failure = transcription.lastFailure {
                fail("文字起こしが失敗: \(failure.message)")
            }
            guard let completion = transcription.lastCompletion else {
                fail("文字起こしが 10 分で完了しませんでした (モデル取得が進んでいない?)")
            }
            // 4) 出力検証。録画ファイルとサイドカーの両方が存在して空でないこと。
            // 書き出し先が TranscriptWriter の契約 (録画ファイルの隣) どおりかも見る
            let expectedSidecar = TranscriptWriter.sidecarURL(forRecording: recordingURL, format: format)
            guard completion.sidecarURL == expectedSidecar else {
                fail("サイドカーの位置が契約と違います: \(completion.sidecarURL.path)"
                    + " (期待: \(expectedSidecar.path))")
            }
            guard FileManager.default.fileExists(atPath: expectedSidecar.path) else {
                fail("サイドカーが存在しません: \(expectedSidecar.path)")
            }
            let bytes = (try? FileManager.default.attributesOfItem(
                atPath: expectedSidecar.path)[.size] as? Int).flatMap { $0 } ?? 0
            guard bytes > 0 else {
                fail("サイドカーが空です: \(expectedSidecar.path)")
            }
            let recordingBytes = (try? FileManager.default.attributesOfItem(
                atPath: recordingURL.path)[.size] as? Int).flatMap { $0 } ?? 0
            // 空の録画は «消灯・ロック中に実行した» 症状 (SCK がフレームを出さない) と
            // 音声入力が死んでいる症状を区別する目印になるので、ここで落とす
            guard recordingBytes > 0 else {
                fail("録画ファイルが空です: \(recordingURL.path)"
                    + " (消灯・ロック中に実行していないか確認してください)")
            }
            // 喋った内容のキーワードが乗っていること。«1 語でも一致» を PASS にする
            // (0 語なら無音か認識失敗で、文字起こしが内容を拾った証明にならない)
            let text = (try? String(contentsOf: expectedSidecar, encoding: .utf8)) ?? ""
            let normalized = normalizeForMatch(text)
            let matched = keywords.filter { normalized.contains(normalizeForMatch($0)) }
            guard !matched.isEmpty else {
                fail("サイドカーにキーワードが 1 つも見つかりませんでした"
                    + " (\(keywords.joined(separator: "/"))) 先頭: \(text.prefix(200))")
            }
            // «パネルを閉じた状態でも完了» の確認 (POPOVER=close 時)。閉じた直後に
            // isShown=false をポーリングで確認済みだが、«完了まで閉じたまま» も含めて
            // 見る (途中で表示が復活する退行を拾う)
            let popoverShownAtEnd = popover.isShown()
            if closesPopover, popoverShownAtEnd {
                fail("文字起こし完了時にポップオーバーが再表示されています")
            }
            print("selftest: transcribed sidecar=\(expectedSidecar.lastPathComponent)"
                + " bytes=\(bytes) keywords=\(matched.joined(separator: ","))"
                + " popoverShown=\(popoverShownAtEnd)"
                + " recordingBytes=\(recordingBytes)")
            fflush(stdout)
            // fail() は «停止 → ファイナライズ待ち» で RunLoop をポンプしている間に、この
            // Task («成功待ち») を先へ進めてしまう。closeFailed の譲りは whenSessionEnds 側に
            // しかないので、«失敗宣言のあとの成功報告» にならないよう exit の直前で確認する
            if isFailing {
                exit(1)
            }
            cleanupSpeech()
            exit(0)
        }
    }

    /// 録画の対象と音声を環境変数から RecordRequest に当てはめる
    /// (KILDE_GUI_SELFTEST_RECORD と実録画版 TRANSCRIBE の共通部分)。
    /// KILDE_GUI_SELFTEST_AUDIO: system (既定) / none / device:<UID or 名前>。
    /// none は音声出力が使えない環境 (既定出力が鳴らないデバイスだと SCK の音声開始が -3818 で
    /// 失敗する) でも GUI → Recorder の経路を確かめるため。device: は BlackHole ループバックの
    /// ようにスピーカーを介さずに信号を入れて検証するため (既定の出力デバイスを変えずに済む)
    @MainActor
    private static func applyRecordingRequest(_ setup: RecordingSetup, env: [String: String]) {
        if let dir = env["KILDE_GUI_SELFTEST_OUTPUT"] {
            setup.request.outputDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        setup.request.target = .display(index: 0)
        setup.request.captureMic = false
        setup.request.inputDevices = []
        switch env["KILDE_GUI_SELFTEST_AUDIO"] ?? "system" {
        case "system":
            setup.request.captureSystemAudio = true
        case "none":
            setup.request.captureSystemAudio = false
        case let value where value.hasPrefix("device:"):
            setup.request.captureSystemAudio = false
            setup.request.inputDevices = [String(value.dropFirst("device:".count))]
        case let other:
            fail("KILDE_GUI_SELFTEST_AUDIO は system / none / device:<名前> を指定してください: \(other)")
        }
    }

    /// say でテスト音声を作る。実在の会議音声や第三者の音声は使わない
    /// (AGENTS.md §6 — 検証用の音声はリポジトリに置かないので一時ディレクトリへ出す)
    private static func makeSpeechSample(text: String, voice: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kilde-selftest-speech-\(UUID().uuidString.prefix(8)).aiff")
        try? FileManager.default.removeItem(at: url)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, text]
        do {
            try say.run()
        } catch {
            fail("テスト音声を作れません (/usr/bin/say の起動に失敗): \(error)")
        }
        say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            fail("テスト音声を作れません (say 終了コード \(say.terminationStatus)。"
                + "KILDE_GUI_SELFTEST_SPEECH_VOICE=\(voice) が無い環境の可能性)")
        }
        return url
    }

    /// afplay と say の後片付け。**exit は子プロセスを殺さない**ので、鳴りっぱなしと
    /// 一時ファイルの残留は自分で止める (fail 経路と成功 exit の両方から呼ぶ)
    @MainActor
    private static func cleanupSpeech() {
        if let player = speechPlayer, player.isRunning {
            player.terminate()
        }
        speechPlayer = nil
        if let url = speechSampleURL {
            try? FileManager.default.removeItem(at: url)
            speechSampleURL = nil
        }
    }

    /// afplay で音声を再生する (起動だけして完了は待たない — «録画が回っている間に
    /// 音が出る» ことが目的)。プロセスと音声ファイルは cleanupSpeech() が片付ける
    private static func playAudio(_ url: URL) -> Bool {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        do {
            try player.run()
        } catch {
            return false
        }
        MainActor.assumeIsolated {
            speechPlayer = player
            speechSampleURL = url
        }
        return true
    }

    /// 実行段階の 1 行表記 (待ちループの定期ログに使う)
    private static func transcriptPhaseText(_ phase: TranscriptionCoordinator.RunPhase?) -> String {
        switch phase {
        case .preparingModel(let progress):
            return "preparingModel(\(Int(progress * 100))%)"
        case .transcribing(let progress):
            return "transcribing(\(Int(progress * 100))%)"
        case nil:
            return "nil"
        }
    }

    /// キーワード照合のための正規化 — 句読点・空白・改行を落とし小文字へ統一する。
    /// «マイクテストの録画です。» から «テスト» «録画» を探すとき、認識結果の
    /// 区切り方 (句点・読点の有無) を吸収するため
    private static func normalizeForMatch(_ text: String) -> String {
        let dropped: Set<Character> = ["、", "。", ",", ".", "\n", "\r", " ", "\u{3000}", "!", "?"]
        return text.lowercased().filter { !dropped.contains($0) }
    }

    /// ポップオーバーを閉じた時点の経過時間 (閉じる側と終了側のクロージャで共有する)
    @MainActor
    private final class ClosedState {
        var elapsed: TimeInterval?
        /// 閉じる操作が効かなかった (診断メッセージを取り違えないために持つ)
        var closeFailed = false
    }

    /// 実行中のセッション。失敗時に停止 → ファイナライズしてから終わるために持つ
    @MainActor private static var active: RecordingController?

    /// 一度でも fail() に入ったら立つ。fail() は RunLoop をポンプしながらファイナライズを
    /// 待つので、その間にほかの Task («成功待ち» や «録画開始待ち») が進行し、
    /// «失敗宣言のあとの成功報告» や fail() の再入 (二重のエラー報告と競合する
    /// 後片付け) が起こりうる — このフラグで両方を防ぐ
    @MainActor private static var isFailing = false

    /// 鳴らし中の afplay と say で作ったテスト音声 (cleanupSpeech が後片付けする)
    @MainActor private static var speechPlayer: Process?
    @MainActor private static var speechSampleURL: URL?

    /// 失敗して終了する。録画中なら停止してファイナライズを待つ — そのまま exit すると
    /// 書きかけのファイルが残り、`kilde inspect` が "Cannot Open" (-11829) になる
    private static func fail(_ message: String) -> Never {
        // 再入ガード。下の RunLoop ポンプの間にほかの Task が fail() に到達しても、
        // 2 つ目以降は報告も後片付けもせず、最初の経路の exit(1) に任せる
        if MainActor.assumeIsolated({ isFailing }) {
            exit(1)
        }
        MainActor.assumeIsolated { isFailing = true }
        FileHandle.standardError.write("selftest: \(message)\n".data(using: .utf8)!)
        // fail() は常にメインスレッドから呼ばれる。MainActor 隔離のプロパティに触るので
        // 参照はすべて assumeIsolated の中で行う
        let wasActive = MainActor.assumeIsolated { () -> Bool in
            cleanupSpeech()
            guard let recording = active, recording.isActive else { return false }
            recording.stop()
            return true
        }
        if wasActive {
            // ファイナライズの完了を待つ (待てなければあきらめて終了する)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, MainActor.assumeIsolated({ active?.isActive ?? false }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        exit(1)
    }
}
