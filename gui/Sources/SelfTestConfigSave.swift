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
/// 自動で確かめられるのはここまで、という線引き:
/// - **確かめられる**: persistSessionDefaults の config.json への反映 (音声ソース / トラック方針 /
///   文字起こし。保存先 outputDirectory を**書かない**ことも)、収録対象の UserDefaults への
///   保存と復元、RecordingSetup.init が復元済みの値で初期値を作ること
///   (再起動後の init と同じ経路)、«保存を呼ばない変更は漏れない» こと
///   (受け入れ条件 «録画を開始しないまま終了した場合、開始していない構成は保存されない» は
///   «persist を呼ぶのが開始経路だけ» という構造 + この検証で担保する)
/// - **確かめられない**: 実際の録画開始経路 (ボタン・ホットキー) から persist が呼ばれること。
///   実録画が要るため実機確認に頼る — この検証で «通った» にしない
///
/// ユーザーの実環境 (~/.kilde/config.json と UserDefaults の lastCaptureTarget) は
/// 退避して必ず元へ戻す
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
        // (単体テストで一時ディレクトリへ差し替えるための設計 — エンジンのコメント参照)。
        // UserDefaults のキーは文字列 1 個なので値を取っておいて最後に戻す
        let originalDirectory = ConfigStore.directory
        let originalTarget = UserDefaults.standard.string(
            forKey: RecordingSetup.captureTargetDefaultsKey)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-config-save-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("selftest: config-save failed to create temp dir: \(error)")
            exit(1)
        }

        func cleanup() {
            ConfigStore.directory = originalDirectory
            if let originalTarget {
                UserDefaults.standard.set(
                    originalTarget, forKey: RecordingSetup.captureTargetDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(
                    forKey: RecordingSetup.captureTargetDefaultsKey)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        // check は fail-fast にしない (SelfTestLibraryExport と同じく failures を数える)。
        // ただし後続の検証の前提が崩れるものは、cleanup してから終わる
        func abort(_ label: String) -> Never {
            cleanup()
            print("selftest: config-save FAIL: \(label)")
            exit(1)
        }

        ConfigStore.directory = directory
        // 前回実行の残留で誤判定しないように、収録対象のキーは消してから始める
        UserDefaults.standard.removeObject(forKey: RecordingSetup.captureTargetDefaultsKey)

        // 1) 何も保存していない状態の初期値。config.json が無いので既定の構成になる
        //    (収録対象はディスプレイ 0 — 保存が無いことはここでも確認する)
        let fresh = RecordingSetup()
        guard case .display(index: 0) = fresh.request.target else {
            abort("保存が無い状態で収録対象がディスプレイ 0 になる (実際 \(fresh.request.target))")
        }
        check(!fresh.request.captureMic, "保存が無い状態の captureMic はオフ")
        check(fresh.transcribeEnabled == false, "保存が無い状態の transcribe はオフ")

        // 2) パネル操作の想定で選択を変え、録画開始時の保存を実行する
        fresh.request.target = .audioOnly
        fresh.request.captureSystemAudio = false
        fresh.request.captureMic = true
        fresh.request.inputDevices = [deviceSpec]
        fresh.request.trackPolicy = .separate
        fresh.transcribeEnabled = true
        fresh.persistSessionDefaults()

        // 3) config.json への反映。**outputDirectory は書かない** — MAS 版は
        //    security-scoped bookmark で独立に永続化されており、config のパスは
        //    コンテナ内を指しえるため (persistSessionDefaults のコメント)
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
        check(saved.outputDirectory == nil, "outputDirectory は書き換えない (bookmark に任せる)")
        check(UserDefaults.standard.string(forKey: RecordingSetup.captureTargetDefaultsKey)
                == "audioOnly",
              "収録対象が UserDefaults へ保存される")

        // 4) 復元。RecordingSetup.init は再起動後と同じ経路 (initial + restoreCaptureTarget)
        let restored = RecordingSetup()
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
        //    persist を呼ばない変更は config.json にも UserDefaults にも漏れない
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
        check(UserDefaults.standard.string(forKey: RecordingSetup.captureTargetDefaultsKey)
                == "audioOnly",
              "persist を呼ばない変更は収録対象に漏れない")
        let relaunched = RecordingSetup()
        check(relaunched.request.captureMic, "再構築でも保存済みの構成が保たれる")
        guard case .audioOnly = relaunched.request.target else {
            abort("再構築でも保存済みの収録対象が保たれる (実際 \(relaunched.request.target))")
        }

        // 6) 収録対象の妥当性検証。環境で意味が通らなくなった値は復元しない。
        //    defaults / screens / liveWindowIDs を注入して実環境に依存しない
        guard let suite = UserDefaults(suiteName: "kilde-selftest-config-save") else {
            abort("検証用の UserDefaults スイートを作成できない")
        }
        suite.removePersistentDomain(forName: "kilde-selftest-config-save")
        suite.set("audioOnly", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(defaults: suite, screens: [], liveWindowIDs: [])
                == .audioOnly,
              "音声のみは環境に依存せず復元する")
        suite.set("display:0", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(defaults: suite, screens: [], liveWindowIDs: [])
                == .display(index: 0),
              "ディスプレイ 0 は常に復元する")
        suite.set("display:3", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(defaults: suite, screens: [], liveWindowIDs: []) == nil,
              "存在しないディスプレイ番号は復元しない")
        // 接続台数の外の番号 (有効な番号は 0..<台数) は落とす。実機の NSScreen をそのまま使う
        let screenCount = NSScreen.screens.count
        if screenCount > 0 {
            suite.set("display:\(screenCount)", forKey: RecordingSetup.captureTargetDefaultsKey)
            check(RecordingSetup.restoreCaptureTarget(
                    defaults: suite, screens: NSScreen.screens, liveWindowIDs: []) == nil,
                  "接続台数を超えるディスプレイ番号は復元しない (台数 \(screenCount))")
        }
        suite.set("window:424242", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(defaults: suite, screens: [], liveWindowIDs: []) == nil,
              "存在しない windowID は復元しない (再起動で ID が無効になった分)")
        check(RecordingSetup.restoreCaptureTarget(
                defaults: suite, screens: [], liveWindowIDs: [424242]) == .window(id: 424242),
              "存続している windowID は復元する")
        suite.set("bogus", forKey: RecordingSetup.captureTargetDefaultsKey)
        check(RecordingSetup.restoreCaptureTarget(defaults: suite, screens: [], liveWindowIDs: [1]) == nil,
              "未知の形式は復元しない")
        suite.removePersistentDomain(forName: "kilde-selftest-config-save")
        // 文字列変換の往復
        check(RecordingSetup.decodeCaptureTarget(RecordingSetup.encodeCaptureTarget(.display(index: 2)))
                == .display(index: 2),
              "display の文字列変換が往復する")
        check(RecordingSetup.decodeCaptureTarget(RecordingSetup.encodeCaptureTarget(.window(id: 7)))
                == .window(id: 7),
              "window の文字列変換が往復する")
        check(RecordingSetup.decodeCaptureTarget("display:") == nil
                && RecordingSetup.decodeCaptureTarget("window:x") == nil,
              "壊れた文字列は nil (既定のディスプレイ 0 に倒す)")

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
