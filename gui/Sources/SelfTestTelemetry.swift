import AppKit
import FirebaseCore

/// 利用統計・クラッシュレポートのオプトアウト設定 (issue #435) の UI 無し検証。
/// TelemetryPreferences の «キーが無ければオン» と保存・復元の往復、起動時のゲート
/// (`AppDelegate.usageReportingPermitted`) が設定とセルフテストの両方で閉じること、
/// 未初期化の Firebase に対して `applyToFirebase` が何もせず落ちないことを確かめる。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (並行する録画テストと同時に回せる)。
///
/// 共有の `UserDefaults.standard` には触らない — 検証で消去・復元すると、同時に走って
/// いる別プロセスの GUI がいま保存した設定を消しうる (SelfTestConfigSave の規約)。
/// 代わりに専用スイートを注入し、終わりにドメインごと消す。
///
/// 自動で確かめられるのはここまで、という線引き:
/// - **確かめられる**: 既定オン / オフの保存と再読込 (同一プロセス内での再オープン —
///   再起動後の永続化は実機確認) /
///   ゲートがオフで閉じること / セルフテスト中はゲートが設定に依らず閉じること /
///   Firebase 未初期化で applyToFirebase が安全なこと
/// - **確かめられない**: Release 構成で実際に `FirebaseApp.configure()` が呼ばれない
///   こと (`sendsUsageToFirebase` は Debug で常に false — ゲートの純関数部分
///   `usageReportingPermitted` で代替する)、初期化済み Firebase に対する
///   `setAnalyticsCollectionEnabled` / `setCrashlyticsCollectionEnabled` の呼び出し
///   (セルフテストは Firebase を初期化しないため — 実機の Release ビルドで確認する)
///
/// 使い方: `KILDE_GUI_SELFTEST_TELEMETRY=1 <GUI>` (SelfTest.runIfRequested から配線)
@MainActor
enum SelfTestTelemetry {

    private static var failures = 0

    static func run() {
        // 実行のたびに空のスイートを作り、終わりにドメインごと消す
        let suiteName = "kilde-selftest-telemetry"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("selftest: telemetry FAIL: defaults suite を作れない")
            exit(1)
        }
        suite.removePersistentDomain(forName: suiteName)
        func cleanup() {
            suite.removePersistentDomain(forName: suiteName)
        }

        // 0) このセルフテスト自身が Firebase を初期化していないこと (前提)。
        //    初期化済みだと 5) の «未初期化で何もしない» が検証にならない
        guard FirebaseApp.app() == nil else {
            cleanup()
            print("selftest: telemetry FAIL: セルフテストで Firebase が初期化されている")
            exit(1)
        }

        // 1) キーが無ければオン — 既存ユーザーがアップデート直後にオフ扱いにならない
        check(suite.object(forKey: TelemetryPreferences.enabledKey) == nil,
              "初期状態ではキーが無い")
        check(TelemetryPreferences.isEnabled(suite), "キーが無ければオン (既定)")
        check(AppDelegate.usageReportingPermitted(isSelfTest: false, defaults: suite),
              "既定のゲートは開いている (通常起動・設定オン)")
        check(!AppDelegate.usageReportingPermitted(isSelfTest: true, defaults: suite),
              "セルフテスト中は設定に依らずゲートが閉じる")

        // 2) オフにする → 即時に読める + ゲートが閉じる
        TelemetryPreferences.setEnabled(false, defaults: suite)
        check(!TelemetryPreferences.isEnabled(suite), "オフを保存すると isEnabled が false")
        check(suite.object(forKey: TelemetryPreferences.enabledKey) as? Bool == false,
              "保存先は Bool false (キー \(TelemetryPreferences.enabledKey))")
        check(!AppDelegate.usageReportingPermitted(isSelfTest: false, defaults: suite),
              "設定オフでゲートが閉じる (次回起動で configure() を呼ばない条件)")

        // 3) «再起動» に近い形: 同じスイート名で UserDefaults を作り直して読む。
        //    同一プロセス内では同じインスタンスが返るため、これは永続化そのものの証明には
        //    ならない (再起動後の読み出しは実機確認) — «設定の読み出し経路がキーを
        //    見る» ことの確認にとどめる (cubic レビュー指摘)。synchronize は非推奨で
        //    効果も保証されないため呼ばない
        guard let reopened = UserDefaults(suiteName: suiteName) else {
            cleanup()
            print("selftest: telemetry FAIL: スイートを開き直せない")
            exit(1)
        }
        check(!TelemetryPreferences.isEnabled(reopened),
              "スイートを作り直して読んでもオフが残る (同一プロセス内。再起動後の永続化は実機確認)")

        // 4) オンに戻す → 即時に読める + ゲートが開く
        TelemetryPreferences.setEnabled(true, defaults: suite)
        check(TelemetryPreferences.isEnabled(suite), "オンを保存すると isEnabled が true")
        check(AppDelegate.usageReportingPermitted(isSelfTest: false, defaults: suite),
              "設定オンでゲートが開く")

        // 5) Firebase 未初期化なら applyToFirebase は何もしない (Crashlytics.crashlytics()
        //    を configure() 前に呼ぶと落ちる — ガードが効いていることの実証)
        TelemetryPreferences.applyToFirebase(enabled: false)
        TelemetryPreferences.applyToFirebase(enabled: true)
        check(FirebaseApp.app() == nil, "applyToFirebase は未初期化の Firebase を初期化しない")

        // 6) 設定キーは他の GUI ローカル設定と衝突しない名前 (契約: PRIVACY.md / DEVELOPMENT.md)
        check(TelemetryPreferences.enabledKey == "usageTelemetryEnabled",
              "キー名が usageTelemetryEnabled (ドキュメントとの契約)")

        cleanup()
        print("selftest: telemetry failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: telemetry OK: \(label)")
        } else {
            failures += 1
            print("selftest: telemetry FAIL: \(label)")
        }
    }
}
