import AppKit
import KildeCore

/// «アプリの音声» (issue #364) の UI 無し検証。
/// «ピッカーの選択 → RecordRequest の組み立て» (RecordingSetup.setAppSource /
/// setSystemAudio — ContentView の Binding と同じメソッド) と、
/// «config.json への保存 → RecordingSetup.init での復元» の往復を、
/// ConfigStore の保存先を一時ディレクトリへ差し替えて確かめる。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (並行する録画テストと同時に回せる)。tap の生成自体は録画開始時にしか
/// 起こらないので、この検証の対象外 — サンドボックス下での tap の実測は
/// フェーズ 0 のスパイク (PR の «サンドボックス・スパイク» 参照) と、
/// `KILDE_GUI_SELFTEST_AUDIO=app:<bundleID>` を付けた RECORD セルフテストが担う。
///
/// ユーザーの実環境を壊さないための差し替えは SelfTestConfigSave と同じ 2 つ:
/// - **config.json** は `ConfigStore.directory` を一時ディレクトリへ差し替える
///   (MAS ビルドでも 2 回目以降の RecordingSetup init がコンテナへ戻さないことは
///   SandboxSupport の 1 プロセス 1 回の制約で保証済み — SelfTestConfigSave 参照)
/// - **UserDefaults** は別スイートを注入し、standard には触らない
///
/// 使い方: `KILDE_GUI_SELFTEST_APP_AUDIO=1 <GUI>` (SelfTest.runIfRequested から配線)
@MainActor
enum SelfTestAppAudio {

    private static var failures = 0

    /// 検証に使う bundleID。実在しないアプリでよい — モデルの排他制御と config の
    /// 往復は文字列の操作で、アプリの解決は録画開始時 (エンジン) に行われる
    private static let appSpec = "com.example.selftestapp"

    static func run() {
        let originalDirectory = ConfigStore.directory
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-app-audio-\(UUID().uuidString)")
        let seededOutputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-app-audio-output-\(UUID().uuidString)",
                                    isDirectory: true)
        let suiteName = "kilde-selftest-app-audio"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: seededOutputDirectory, withIntermediateDirectories: true)
        } catch {
            print("selftest: app-audio failed to create temp dir: \(error)")
            exit(1)
        }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("selftest: app-audio failed to create defaults suite")
            exit(1)
        }
        suite.removePersistentDomain(forName: suiteName)

        func cleanup() {
            ConfigStore.directory = originalDirectory
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: seededOutputDirectory)
        }
        func abort(_ label: String) -> Never {
            cleanup()
            print("selftest: app-audio FAIL: \(label)")
            exit(1)
        }

        // **先に保存先を差し替えてから**シードを書く (SelfTestConfigSave と同じ順序 —
        // 逆だと実環境の config.json を上書きする)
        ConfigStore.directory = directory
        do {
            var seed = KildeConfig()
            seed.outputDirectory = seededOutputDirectory.path
            try ConfigStore.save(seed)
        } catch {
            abort("シード用の config.json を書けない: \(error)")
        }

        // 1) ピッカーの列挙 (実機の環境に依存するので不変条件だけ見る)。
        //    bundleID は保持値の語彙なので空が混ざらないこと、重複がないこと、
        //    自アプリが含まれないことを確かめる。
        //    **reload() を呼んでから確かめる** — init だけでは列挙が走らず、
        //    空の一覧への検証が «壊れていても成功» になる (cubic レビュー指摘)。
        //    reload() の中で runningApps は同期で埋まり、画面の列挙 (SCK) は
        //    非同期で走るが、この検証は runningApps だけを見るので待たない
        let fresh = RecordingSetup(defaults: suite)
        check(ConfigStore.directory == directory,
              "RecordingSetup を作り直しても一時ディレクトリの差し替えが保たれる")
        fresh.reload()
        guard !fresh.runningApps.isEmpty else {
            abort("実行中のアプリが列挙されませんでした (NSWorkspace の一覧が空。ピッカーの検証ができない)")
        }
        check(fresh.runningApps.allSatisfy { !$0.bundleID.isEmpty },
              "ピッカーの選択肢は bundleID を持つ (\(fresh.runningApps.count) 件)")
        check(Set(fresh.runningApps.map(\.bundleID)).count == fresh.runningApps.count,
              "ピッカーの選択肢に bundleID の重複がない")
        check(!fresh.runningApps.contains { $0.bundleID == Bundle.main.bundleIdentifier },
              "ピッカーに自アプリを含まない")
        check(fresh.request.captureSystemAudio, "初期状態はシステム音声オン")
        check(fresh.request.appSources.isEmpty, "初期状態はアプリの音声なし")

        // 2) 排他制御 — «アプリを選ぶと system が外れ、mic は併用できる»。
        //    ContentView の Binding と同じメソッドを通る
        fresh.setAppSource(true, spec: appSpec)
        check(!fresh.request.captureSystemAudio, "アプリを選ぶとシステム音声が外れる")
        check(fresh.request.appSources == [appSpec], "アプリの音声が bundleID で保持される")
        check(fresh.request.audioSourceStrings == ["app:\(appSpec)"],
              "audioSourceStrings は app: 接頭辞のみ (固定順の末尾)")
        fresh.request.captureMic = true
        check(fresh.request.audioSourceStrings == ["mic", "app:\(appSpec)"],
              "mic との併用が生きている (順序は system → mic → device → app の契約)")
        check(fresh.request.audioSourceCount == 2, "2 ソースでトラック方針の選択が意味を持つ")

        // 3) 逆方向 — «system を戻すとアプリの音声が外れる»
        fresh.setSystemAudio(true)
        check(fresh.request.appSources.isEmpty, "システム音声を戻すとアプリの音声が空になる")
        check(fresh.request.audioSourceStrings == ["system", "mic"],
              "system に戻った音声ソースの文字列 (順序契約)")
        // 大文字小文字の揺れはエンジンの解決 (caseInsensitiveCompare) に合わせて同一視する —
        // 二重追加もしない
        fresh.setAppSource(true, spec: appSpec)
        fresh.setAppSource(true, spec: appSpec.uppercased())
        check(fresh.request.appSources == [appSpec.uppercased()],
              "大文字小文字の違う同じ bundleID で二重追加しない (後の指定で置き換わる)")
        check(fresh.unrunningSelectedAppSources == [appSpec.uppercased()],
              "実行していないアプリの指定は «実行中でない» 側に出る")
        // 以降の検証は正規の表記 (小文字) に戻す — 保持値は UI が渡した通りの
        // 文字列で、エンジンの解決が大文字小文字を同一視する
        fresh.setAppSource(true, spec: appSpec)

        // 3-b) 名前指定と実行中アプリの項目の対応 (CodeRabbit レビュー指摘)。
        //     手編集 config の `app:Safari` のような名前指定が、実行中アプリ
        //     «Safari» のメニュー項目で «未選択» になると、クリックで同じアプリが
        //     二重に足される。解決の照合 (resolvesToApp) は合成アプリで確かめ、
        //     «選択表示 → 切替の置換» は実在の実行中アプリで確かめる
        let safari = RecordingSetup.RunningApp(
            bundleID: "com.apple.Safari", name: "Safari", icon: nil)
        check(fresh.resolvesToApp("Safari", app: safari),
              "名前指定 (app:Safari) は実行中アプリ «Safari» の項目に解決される")
        check(fresh.resolvesToApp("com.apple.Safari", app: safari),
              "bundleID 指定はその実行中アプリの項目に解決される")
        check(fresh.resolvesToApp("COM.APPLE.SAFARI", app: safari),
              "bundleID の照合は大文字小文字を無視する")
        check(!fresh.resolvesToApp("com.example.selftestapp", app: safari),
              "別のアプリの指定はその項目に解決されない")
        // «復元した名前指定が選択表示に出る» 経路。appSources に直接名前を置くのは
        // 手編集 config からの復元 (RecordRequest.initial) と同じ状態を作るため
        fresh.request.appSources = ["Safari"]
        check(fresh.hasSelectedSource(resolvingTo: safari),
              "保存済みの名前指定は実行中アプリ «Safari» の項目を «選択中» にする")
        fresh.request.appSources = []
        // «選び替えの置換» (実在の実行中アプリ 1 件で端到端に確かめる)。名前指定が
        // 残ったまま bundleID が足されると、エンジンが同じプロセスを 2 つのソースと
        // して解決し、同じ音を二重に録る。
        // **名前が取れるアプリに限る** — localizedName が空のプロセス (FollowUpUI など)
        // は名前指定の語彙そのものが成立しない
        guard let target = fresh.runningApps.first(where: { !$0.name.isEmpty }) else {
            abort("名前の取れる実行中アプリがありません (名前指定の置換を検証できない)")
        }
        fresh.request.appSources = [target.name]
        fresh.setAppSource(true, spec: target.bundleID)
        check(fresh.request.appSources == [target.bundleID],
              "実行中アプリを選ぶと同名の保存済み指定が bundleID に置き換わる "
                  + "(実際 \(String(describing: fresh.request.appSources)))")
        fresh.setAppSource(false, spec: target.bundleID)
        check(fresh.request.appSources.isEmpty,
              "置き換え後の選択は 1 回の解除で外れる")
        // 以降 (セクション 4) の «app + system» の状態を作り直す — 上の解除で
        // appSources を空にしたまま進むと、system 単独の«有効な»構成になってしまう
        fresh.request.appSources = [appSpec]

        // 4) エンジン契約 — «app と system の併用は makeOptions / savingDefaults の
        //    両方で拒否» (RecordRequest.checkSourceCombination)。GUI が外し忘れた
        //    組合せを録画開始まで通さないことの最後の砦。
        //    **投げられたエラーが requestInvalid であることまで見る** — «何か例外が
        //    出た» だけだと、保存先不存在などの別の失敗を «契約どおり» と誤判定する
        //    (cubic レビュー指摘)
        fresh.request.captureSystemAudio = true
        do {
            _ = try fresh.makeOptions(for: fresh.request)
            check(false, "app + system の makeOptions は拒否される")
        } catch {
            check(isRequestInvalid(error),
                  "app + system の makeOptions は requestInvalid で拒否される (\(errorKind(error)))")
        }
        do {
            _ = try fresh.request.savingDefaults(into: KildeConfig())
            check(false, "app + system の savingDefaults は拒否される")
        } catch {
            check(isRequestInvalid(error),
                  "app + system の savingDefaults は requestInvalid で拒否される (\(errorKind(error)))")
        }
        // 不正な組合せは config.json に書かせない — «既定値として保存» でも同じ
        fresh.request.captureSystemAudio = false

        // 5) 有効な組合せの makeOptions。予約した出力ファイルは録画しないので自分で片付ける
        //    (SelfTest の popover 失敗経路と同じ後始末)
        do {
            var request = fresh.request
            request.target = .audioOnly
            request.captureMic = false
            let options = try fresh.makeOptions(for: request)
            check(options.audioSources == [.app(appSpec)],
                  "app のみの音声ソースがエンジンに渡る (\(options.audioSources))")
            check(!options.wantsVideo, "app のみは映像なしで録音になる")
            if let reservation = options.outputReservation {
                _ = reservation.removeIfStillReserved()
            }
        } catch {
            check(false, "app のみの makeOptions は通る: \(error)")
        }
        do {
            let updated = try fresh.request.savingDefaults(into: KildeConfig())
            check(updated.defaultAudioSources == ["mic", "app:\(appSpec)"],
                  "«既定値として保存» の既定にも app: が入る "
                      + "(実際 \(String(describing: updated.defaultAudioSources)))")
        } catch {
            check(false, "app + mic の savingDefaults は通る: \(error)")
        }

        // 6) config.json への保存 → 復元の往復。persistSessionDefaults は
        //    audioSourceStrings をそのまま書くので app: が保存され、
        //    RecordingSetup.init (RecordRequest.initial) が復元する
        let persisting = RecordingSetup(defaults: suite)
        persisting.request.target = .audioOnly
        persisting.request.captureSystemAudio = false
        persisting.request.captureMic = true
        persisting.setAppSource(true, spec: appSpec)
        persisting.request.trackPolicy = .separate
        persisting.persistSessionDefaults()
        let saved: KildeConfig
        do {
            saved = try ConfigStore.load()
        } catch {
            abort("保存した config.json を読めない: \(error)")
        }
        check(saved.defaultAudioSources == ["mic", "app:\(appSpec)"],
              "config.json に app: 付きで保存される "
                  + "(実際 \(String(describing: saved.defaultAudioSources)))")

        let restored = RecordingSetup(defaults: suite)
        check(!restored.request.captureSystemAudio, "復元: システム音声のオフ")
        check(restored.request.captureMic, "復元: マイクのオン")
        check(restored.request.appSources == [appSpec],
              "復元: アプリの音声 (config の app: から appSources へ)")
        check(restored.request.audioSourceStrings == ["mic", "app:\(appSpec)"],
              "復元後も audioSourceStrings の往復が一致")
        check(restored.request.trackPolicy == .separate, "復元: トラック方針")

        // 7) «復元時に対象アプリが非実行» — 黙って system に縮退しないこと。
        //    検証アプリ (com.example.selftestapp) は実在しないので、常に非実行の状態
        check(!restored.request.captureSystemAudio,
              "対象が非実行でも system に縮退しない (開始時にエンジンのエラーで案内)")
        check(restored.unrunningSelectedAppSources == [appSpec],
              "非実行の選択はピッカーの «実行中でない» に出る (選択を見せ続ける)")

        cleanup()
        print("selftest: app-audio failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    /// 失敗メッセージの冒頭だけを出す (KilError の description は長い)
    private static func errorKind(_ error: Error) -> String {
        let text = String(describing: error)
        if let range = text.range(of: "\n") { return String(text[..<range.lowerBound]) }
        return text
    }

    /// エンジンの «app と system の併用» 拒否 (KilError.Code.requestInvalid) か。
    /// «何かエラーが出た» を合格にしないための判定 (cubic レビュー指摘)
    private static func isRequestInvalid(_ error: Error) -> Bool {
        (error as? KilError)?.code == .requestInvalid
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: app-audio OK: \(label)")
        } else {
            failures += 1
            print("selftest: app-audio FAIL: \(label)")
        }
    }
}
