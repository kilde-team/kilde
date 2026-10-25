import Foundation
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

/// 利用統計 (Firebase Analytics) とクラッシュレポート (Firebase Crashlytics) の送信を
/// ユーザーが止めるための設定 (issue #435)。«ボットなし・クラウドなし» を掲げる
/// アプリで、送っているものを止められないのはローンチ前の最大の弱点だった
/// (docs/launch/faq.md §2)。
///
/// 設計の要点:
/// - **1 つのスイッチで両方を制御する**。PRIVACY.md も «利用統計» と «クラッシュ
///   レポート» を並べて説明しており、ユーザーに 2 つの区別を求めない
/// - **既定はオン** (現状の挙動を変えない)。収集内容は PRIVACY.md で告知済みで、
///   この設定が変えるのは «止められる» こと。フェーズ 2 の KPI (#159 / #161) が
///   Firebase の計測に依存するため、既定をオフにはしない
/// - **キーが無ければオン**。`UserDefaults.bool(forKey:)` は未設定で false を返すので
///   使わない — それに頼ると既存ユーザー全員がアップデート直後にオフ扱いになる
/// - **オフは即時**。«次回起動から» にしない — プライバシー設定で «切ったのに送って
///   いた» は信頼を壊す。起動時のゲートは AppDelegate.sendsUsageToFirebase
///   (オフなら `FirebaseApp.configure()` 自体を呼ばず、何も初期化しない)
enum TelemetryPreferences {

    /// UserDefaults のキー。MAS 版はコンテナ内の UserDefaults に保存される
    /// (PRIVACY.md «設定» — Mac の中にだけ保存)。他の GUI ローカル設定
    /// (`summaryEnabled` など) と同じ camelCase
    static let enabledKey = "usageTelemetryEnabled"

    /// 送信が許可されているか。キーが無ければ true (上の «キーが無ければオン»)
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? true
    }

    /// 設定を保存する。Firebase への反映は呼び出し側が
    /// `AppDelegate.telemetryPreferenceDidChange()` で行う (初期化の要否は
    /// AppDelegate が決めるため — Debug / セルフテストでは初期化しない)
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// 実行中の Firebase に収集の可否を反映する。
    ///
    /// **未初期化なら何もしない** — Debug / セルフテスト / 起動時にオフだった場合は
    /// `FirebaseApp.configure()` を呼んでおらず、送信そのものが無い。
    /// `Crashlytics.crashlytics()` は configure() 前に呼ぶと nil を返して Swift 側で
    /// 落ちる (FIRCrashlytics は defaultApp のコンテナからインスタンスを取る) ため、
    /// このガードは省けない。
    ///
    /// Analytics / Crashlytics の収集スイッチはどちらも **Firebase 側で起動をまたいで
    /// 永続化される**。そのため «オフにして終了 → 次回オフで起動 (configure しない) →
    /// 実行中にオンへ戻す → そこで configure» の経路では、Firebase に残った
    /// «停止» が生きたままになる — オンに戻すときは必ずここで明示的に true を書く
    /// (AppDelegate.startUsageReporting も configure() の直後に呼ぶ)。
    ///
    /// オフにするときは未送信のクラッシュレポートも削除する。«止める» を選んだ
    /// ユーザーの端末に、次にオンへ戻したとき送られる報告を残しておかない
    /// (`deleteUnsentReports` は収集が無効のときにだけ効く API — 順序は停止 → 削除)
    static func applyToFirebase(enabled: Bool) {
        guard FirebaseApp.app() != nil else { return }
        Analytics.setAnalyticsCollectionEnabled(enabled)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCrashlyticsCollectionEnabled(enabled)
        if !enabled {
            crashlytics.deleteUnsentReports()
        }
    }
}
