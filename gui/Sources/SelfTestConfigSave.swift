import AppKit
import KildeCore

/// 設定の引き継ぎ (issue #345) の UI 無し検証。
/// «録画開始時にパネルの選択を次回起動用に保存する» (`RecordingSetup.persistSessionDefaults`) と
/// «起動時に復元する» (`RecordRequest.initial` + `restoreCaptureTarget`) の往復を、
/// ConfigStore の保存先を一時ディレクトリへ差し替えて確かめる。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (並行する録画テストと同時に回せる)。
///
/// ユーザーの実環境を壊さないための 2 つの差し替え:
/// - **config.json** は `ConfigStore.directory` を一時ディレクトリへ差し替える。
///   MAS ビルドでは RecordingSetup を作り直しても
///   `SandboxSupport.redirectConfigStoreIntoContainer()` が 2 回目以降は
///   コンテナへ戻さない (1 プロセス 1 回の制約。cubic レビュー指摘への対応) ので、
///   差し替えが persist まで有効に続く
/// - **収録対象 (UserDefaults)** は RecordingSetup へ別スイートを注入する —
///   共有の `UserDefaults.standard` を検証で消去・復元すると、同時に走っている
///   別プロセスの GUI が保存したばかりの収録対象を消しうるため
///   (cubic レビュー指摘への対応)。standard には一切触らない
///
/// 自動で確かめられるのはここまで、という線引き:
/// - **確かめられる**: persistSessionDefaults の config.json への反映 (音声ソース / トラック方針 /
///   文字起こし。既存の outputDirectory を**壊さない**ことも)、収録対象の保存と復元、
///   RecordingSetup.init が復元済みの値で初期値を作ること (再起動後の init と同じ経路)、
///   «保存を呼ばない変更は漏れない» こと (受け入れ条件 «録画を開始しないまま終了した場合、
///   開始していない構成は保存されない» は «persist を呼ぶのが開始経路だけ» という構造 +
///   この検証で担保する)
/// - **確かめられない**: 実際の録画開始経路 (ボタン・ホットキー) から persist が呼ばれること。
///   実録画が要るため実機確認に頼る — この検証で «通った» にしない
///
/// 使い方: `KILDE_GUI_SELFTEST_CONFIG_SAVE=1 <GUI>` (SelfTest.runIfRequested から配線)
@MainActor
enum SelfTestConfigSave {

    private static var failures = 0

    /// 検証に使う音声構成。デバイス名は実在しなくてよい (config の保存・復元は
    /// 文字列の往復で、デバイスの解決は録画開始時に行われる)
    private static let deviceSpec = "SelfTest Device"

    static func run() {
        // 実環境の退避。ConfigStore.directory は public static var なので差し替えられる
        // (単体テストで一時ディレクトリへ差し替えるための設計 — エンジンのコメント参照)
        let originalDirectory = ConfigStore.directory
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-config-save-\(UUID().uuidString)")
        let seededOutputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-config-save-output-\(UUID().uuidString)",
                                    isDirectory: true)
        // 収録対象の保存先。実行のたびに空のスイートを作り、終わりにドメインごと消す
        let suiteName = "kilde-selftest-config-save"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: seededOutputDirectory, withIntermediateDirectories: true)
        } catch {
            print("selftest: config-save failed to create temp dir: \(error)")
            exit(1)
        }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("selftest: config-save failed to create defaults suite")
            exit(1)
        }
        suite.removePersistentDomain(forName: suiteName)

        func cleanup() {
            ConfigStore.directory = originalDirectory
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: seededOutputDirectory)
        }
        // check は fail-fast にしない (SelfTestLibraryExport と同じく failures を数える)。
        // ただし後続の検証の前提が崩れるものは、cleanup してから終わる
        func abort(_ label: String) -> Never {
            cleanup()
            print("selftest: config-save FAIL: \(label)")
            exit(1)
        }

        // **先に保存先を差し替えてから**シードを書く — 逆だと実環境の config.json を
        // 上書きしてしまう
        ConfigStore.directory = directory
        // あらかじめ outputDirectory を持つ config を用意する — «persist が
        // outputDirectory を書き換えない» は、値がある状態で同じ値のままかを見ないと
        // 検証にならない (cubic レビュー指摘)
        do {
            var seed = KildeConfig()
            seed.outputDirectory = seededOutputDirectory.path
            try ConfigStore.save(seed)
        } catch {
            abort("シード用の config.json を書けない: \(error)")
        }

        // 1) 保存が無い状態の初期値。収録対象は既定 (ディスプレイ 0) で、
        //    保存先はシードした値から復元される
        let fresh = RecordingSetup(defaults: suite)
        // **RecordingSetup を作り直しても ConfigStore の差し替えが保たれること。**
        // MAS ビルドでは init が SandboxSupport.redirectConfigStoreIntoContainer を
        // 呼ぶ — 2 回目以降でコンテナへ戻ると実ユーザーの config を読み書きする
        // (cubic レビュー指摘。対処は SandboxSupport 側の 1 プロセス 1 回の制約)
        check(ConfigStore.directory == directory,
              "RecordingSetup を作り直しても一時ディレクトリの差し替えが保たれる")
        guard case .display(index: 0) = fresh.request.target else {
            abort("保存が無い状態で収録対象がディスプレイ 0 になる (実際 \(fresh.request.target))")
        }
        check(!fresh.request.captureMic, "保存が無い状態の captureMic はオフ")
        check(fresh.transcribeEnabled == false, "保存が無い状態の transcribe はオフ")
#if !APPSTORE
        check(fresh.request.outputDirectory == seededOutputDirectory,
              "保存が無い状態でも config の outputDirectory から復元する")
#else
        // MAS では init が SandboxSupport.userVisible で正規化するため、コンテナ内の
        // 一時ディレクトリは既定の保存先へ倒れる — «コンテナ内のパスがそのまま
        // 残らないこと» (Guideline 2.4.5(i) 対策の正規化が働くこと) だけを見る
        check(fresh.request.outputDirectory.path != seededOutputDirectory.path,
              "MAS ではコンテナ内の outputDirectory が正規化される")
#endif

        // 2) パネル操作の想定で選択を変え、録画開始時の保存を実行する
        fresh.request.target = .audioOnly
        fresh.request.captureSystemAudio = false
        fresh.request.captureMic = true
        fresh.request.inputDevices = [deviceSpec]
        fresh.request.trackPolicy = .separate
        fresh.transcribeEnabled = true
        fresh.persistSessionDefaults()

        // 3) config.json への反映。**outputDirectory は触らない** — MAS 版は
        //    security-scoped bookmark 経由で独立に永続化されており、config のパスは
        //    コンテナ内を指しえて CLI でも解釈できない (persistSessionDefaults のコメント)
        let saved: KildeConfig
        do {
            saved = try ConfigStore.load()
        } catch {
            abort("保存した config.json を読めない: \(error)")
        }
        check(saved.defaultAudioSources == ["mic", "device:\(deviceSpec)"],
              "音声ソースが --audio と同じ文字列表現で保存される "
                  + "(実際 \(String(describing: saved.defaultAudioSources)))")
        check(saved.audioTracks == "separate", "トラック方針が保存される")
        check(saved.transcribe == true, "文字起こしのトグルが保存される")
        check(saved.outputDirectory == seededOutputDirectory.path,
              "outputDirectory は書き換えない (bookmark に任せる)")
        check(suite.string(forKey: RecordingSetup.captureTargetDefaultsKey) == "audioOnly",
              "収録対象が注入した defaults へ保存される")

        // 4) 復元。RecordingSetup.init は再起動後と同じ経路 (initial + restoreCaptureTarget)
        let restored = RecordingSetup(defaults: suite)
        check(!restored.request.captureSystemAudio, "復元: システム音声のオフ")
        check(restored.request.captureMic, "復元: マイクのオン")
        check(restored.request.inputDevices == [deviceSpec], "復元: 入力デバイス")
        check(restored.request.trackPolicy == .separate, "復元: トラック方針")
        check(restored.transcribeEnabled, "復元: 文字起こしのトグル")
        guard case .audioOnly = restored.request.target else {
            abort("復元: 収録対象が音声のみになる (実際 \(restored.request.target))")
        }
        check(true, "復元: 収録対象が音声のみ (capture source selector — ユーザー報告の修正)")

        // 5) «録画を開始しないまま終了した場合、開始していない構成は保存されない»。
        //    persist を呼ばない変更は config.json にも defaults にも漏れない
        restored.request.target = .display(index: 0)
        restored.request.captureMic = false
        let untouched: KildeConfig
        do {
            untouched = try ConfigStore.load()
        } catch {
            abort("変更後の config.json を読めない: \(error)")
        }
        check(untouched.defaultAudioSources == ["mic", "device:\(deviceSpec)"],
              "persist を呼ばない変更は config.json に漏れない")
        check(suite.string(forKey: RecordingSetup.captureTargetDefaultsKey) == "audioOnly",
              "persist を呼ばない変更は収録対象に漏れない")
        let relaunched = RecordingSetup(defaults: suite)
        check(relaunched.request.captureMic, "再構築でも保存済みの構成が保たれる")
        guard case .audioOnly = relaunched.request.target else {
            abort("再構築でも保存済みの収録対象が保たれる (実際 \(relaunched.request.target))")
        }

        // 6) 収録対象の妥当性検証。環境で意味が通らなくなった値は復元しない。
        //    defaults / screens / liveWindows を注入して実環境に依存しない
        suite.set("audioOnly", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: []) == .audioOnly,
              "音声のみは環境に依存せず復元する")
        suite.set("display:0", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: []) == nil,
              "ディスプレイが 1 台も無い環境ではディスプレイ 0 も復元しない "
                  + "(«0 は常に有効» の特例を置かない — cubic レビュー指摘)")
        let screens = NSScreen.screens
        if !screens.isEmpty {
            check(RecordingSetup.restoreCaptureTarget(
                    defaults: suite, screens: screens, liveWindows: []) == .display(index: 0),
                  "実在するディスプレイ 0 は復元する (台数 \(screens.count))")
        }
        suite.set("display:3", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: screens, liveWindows: []) == nil,
              "存在しないディスプレイ番号は復元しない")
        suite.set("display:-1", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: screens, liveWindows: []) == nil,
              "負のディスプレイ番号は復元しない")
        // ウィンドウは "window:<id>:<bundleIdentifier>" の形で保存する。
        // ID が存続していても所有アプリが変わっていたら «別ウィンドウに再利用された»
        // ものとして復元しない (cubic レビュー指摘)
        let window = RecordingSetup.WindowIdentity(
            id: 424242, bundleIdentifier: "com.example.selftest")
        suite.set(RecordingSetup.encodedCaptureTarget(
            .window(id: 424242), liveWindows: [window]),
            forKey: RecordingSetup.captureTargetDefaultsKey)
        check(suite.string(forKey: RecordingSetup.captureTargetDefaultsKey)
                == "window:424242:com.example.selftest",
              "ウィンドウ選択は ID と所有アプリの bundle を一緒に保存する")
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: [window]) == .window(id: 424242),
              "ID と bundle が一致する存続ウィンドウは復元する")
        let reused = RecordingSetup.WindowIdentity(
            id: 424242, bundleIdentifier: "com.example.other")
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: [reused]) == nil,
              "ID が再利用されて bundle が変わったウィンドウは復元しない")
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: []) == nil,
              "存在しない windowID は復元しない (再起動でウィンドウが閉じた分)")
        suite.set("window:424242:com.example.selftest",
                  forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: [window]) == .window(id: 424242),
              "保存済み文字列のままでも復元できる")
        suite.set("bogus", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindows: [window]) == nil,
              "未知の形式は復元しない")

        cleanup()
        print("selftest: config-save failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: config-save OK: \(label)")
        } else {
            failures += 1
            print("selftest: config-save FAIL: \(label)")
        }
    }
}
