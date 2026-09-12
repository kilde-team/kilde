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
                               permissions: PermissionsModel, popover: PopoverControl) {
        let env = ProcessInfo.processInfo.environment
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
        if let dir = env["KILDE_GUI_SELFTEST_OUTPUT"] {
            setup.request.outputDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        setup.request.target = .display(index: 0)
        // KILDE_GUI_SELFTEST_AUDIO: system (既定) / none / device:<UID or 名前>。
        // none は音声出力が使えない環境 (既定出力が鳴らないデバイスだと SCK の音声開始が -3818 で
        // 失敗する) でも GUI → Recorder の経路を確かめるため。device: は BlackHole ループバックのように
        // スピーカーを介さずに信号を入れて検証するため (既定の出力デバイスを変えずに済む)
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
        let resolved = (try? HotkeySettings.resolve(explicit: nil, config: setup.config)) ?? nil
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
            print("selftest: hotkeyRegistered=true source=\(registered)")
        } else {
            // 失敗の理由は AppDelegate が notice に入れている。出さないと
            // «登録できなかった» としか分からず、原因の切り分けができない
            print("selftest: hotkeyRegistered=false resolved=\(resolved ?? "none")"
                + " notice=\(setup.notice ?? "(なし)")")
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

    /// ポップオーバーを閉じた時点の経過時間 (閉じる側と終了側のクロージャで共有する)
    @MainActor
    private final class ClosedState {
        var elapsed: TimeInterval?
        /// 閉じる操作が効かなかった (診断メッセージを取り違えないために持つ)
        var closeFailed = false
    }

    /// 実行中のセッション。失敗時に停止 → ファイナライズしてから終わるために持つ
    @MainActor private static var active: RecordingController?

    /// 失敗して終了する。録画中なら停止してファイナライズを待つ — そのまま exit すると
    /// 書きかけのファイルが残り、`kilde inspect` が "Cannot Open" (-11829) になる
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("selftest: \(message)\n".data(using: .utf8)!)
        // fail() は常にメインスレッドから呼ばれる。MainActor 隔離のプロパティに触るので
        // 参照はすべて assumeIsolated の中で行う
        let wasActive = MainActor.assumeIsolated { () -> Bool in
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
