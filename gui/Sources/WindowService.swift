import AppKit
import CoreGraphics

/// 収録対象ウィンドウの分類 (issue #429)。
///
/// 目的は 2 つ:
/// 1. ウィンドウ選択リストで «録画対象になりやすいウィンドウ« (オンライン会議・動画視聴) を
///    タグで見つけやすくする (ウィンドウの数が多いときにどれを選ぶべきか分かりづらい、が発端)
/// 2. `recording_start` の `window_service` パラメータで «どのようなサービスが録画されているか«
///    を区分として計測する
///
/// **送信・表示の語彙はこの列挙に閉じる** (UsageAnalytics の errorKind / ScreenName と同じ
/// 規約)。bundleID・ウィンドウタイトルは判定にだけ使い、外部へ出すのはこの rawValue と
/// タグのラベルのみ — ウィンドウのタイトルや未知のアプリの名前が計測に漏れないようにする
/// ため (PRIVACY.md «利用統計»)。
///
/// MeetingDetector (会議の自動録画) との違い: あちらは «今 会議が開いているか» を
/// マイク使用などの動的信号と突き合わせて判定する。こちらは «録画対象になりやすい
/// ウィンドウか« を bundleID とタイトルの**静的な規則だけで**判定する — パネルを開いた
/// 時点で (会議が始まる前に) タグを出すためで、規則の重なり (Meet のタイトル等) は
/// 意図的に同じにしてある
enum WindowService: String, CaseIterable {
    // MARK: 区分 (語彙)

    /// Zoom (アプリ本体のウィンドウ。ホーム画面も会議アプリの一部として «会議« 扱い)
    case zoom
    /// Google Meet (ブラウザのタブ / PWA)。タイトルは "Meet - <コード>" または "Google Meet"
    case googleMeet = "google_meet"
    /// Microsoft Teams。会議ウィンドウとチャットウィンドウをタイトルだけで区別できない
    /// ため、アプリ単位で «会議« 扱いにする
    case teams = "microsoft_teams"
    case webex
    /// Slack。**ハドルのウィンドウだけ** (Slack はチャットが主用途なので、
    /// 通常のウィンドウを «会議« と表示しない)
    case slack
    /// YouTube (ブラウザのタブ)
    case youtube
    /// YouTube 以外の動画配信 (Netflix / Prime Video / Disney+ 等。区分は 1 つにまとめる)
    case streaming
    /// 既知の会議・動画サービスに当てはまらないブラウザのウィンドウ
    case browser
    /// それ以外のアプリのウィンドウ
    case other

    // MARK: UI のタグ

    /// ウィンドウ選択リストに付けるタグ。タグが付かない区分 (browser / other) は nil
    enum Tag: Equatable {
        case meeting
        case video

        /// タグの表示文字列 (ローカライズ済み)
        var label: String {
            switch self {
            case .meeting: return String(localized: "会議")
            case .video: return String(localized: "動画")
            }
        }
    }

    /// この区分に付けるタグ (会議 / 動画)。なければ nil
    var tag: Tag? {
        switch self {
        case .zoom, .googleMeet, .teams, .webex, .slack: return .meeting
        case .youtube, .streaming: return .video
        case .browser, .other: return nil
        }
    }

    /// ウィンドウ一覧の並び替え順 (大きいほど前)。タグ付きを先頭に並べるために使う
    /// (issue #429 — «どれを選ぶべきか分かりづらい« の緩和)。会議を動画より前にするのは、
    /// 本プロダクトの最重要ユースケースが会議の録画のため (CLAUDE.md §1)
    var listRank: Int {
        switch tag {
        case .meeting: return 2
        case .video: return 1
        case nil: return 0
        }
    }

    // MARK: 判定 (純関数)

    /// 既知の会議アプリの bundleID 接頭辞 (アプリ単位で会議扱いにするもの。
    /// MeetingDetector.apps の windowBundlePrefixes と同じ語彙)
    private static let meetingAppPrefixes: [String: WindowService] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams": .teams,
        "Cisco-Systems.Spark": .webex,
        "com.webex.": .webex,
        "com.cisco.webex": .webex,
    ]

    /// Slack の bundleID 接頭辞。**タイトルでハドルかを見る必要があるため**、
    /// meetingAppPrefixes とは別に持つ
    private static let slackPrefix = "com.tinyspeck.slackmacgap"
    /// Slack のハドルらしいタイトル (MeetingDetector の Slack 規則と同じ語彙)
    private static let slackHuddleContains = ["Huddle", "ハドル", "허들"]

    /// ブラウザの bundleID 接頭辞 (MeetingDetector.apps の Meet 規則に出てくるものと同じ)。
    /// ブラウザは «アクティブなタブのタイトル« がウィンドウタイトルになるため、
    /// タイトルからサービスを判定できる
    private static let browserPrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.mozilla.firefox", "com.apple.Safari",
    ]

    /// Google Meet のタブタイトル (MeetingDetector.meetPrefixes と同じ。
    /// 言語によって en dash が変わる)
    private static let meetPrefixes = ["Meet - ", "Meet – "]
    private static let meetContains = ["Google Meet"]

    /// 動画配信サービスのタイトルに含まれる語。**ブラウザのタイトル判定にだけ使う** —
    /// 「YouTube 活用術.key」のような (ブラウザ以外の) タイトルを動画扱いにしないため
    private static let streamingContains = [
        "Netflix", "Prime Video", "Disney+", "Disney＋", "Hulu", "ABEMA",
        "ニコニコ動画", "TVer", "U-NEXT", "Lemino", "FOD",
    ]

    /// bundleID とウィンドウタイトルから区分を決める (パネルのタグと計測の両方が使う)。
    /// どの規則にも当てはまらないウィンドウは失敗させず `.other` / `.browser` に倒す —
    /// タグは付かないが一覧の表示・計測には支障が無いようにするため
    static func classify(bundleIdentifier: String?, title: String?) -> WindowService {
        let bundle = bundleIdentifier ?? ""
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 1. アプリ単位で決まる会議アプリ (Zoom / Teams / Webex) — タイトルは見ない
        for (prefix, service) in meetingAppPrefixes where bundle.hasPrefix(prefix) {
            return service
        }
        // 2. Slack はハドルのウィンドウだけ会議扱い (チャットが主用途のため)
        if bundle.hasPrefix(slackPrefix)
            && slackHuddleContains.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            return .slack
        }
        // 3. ブラウザはアクティブなタブのタイトルでサービスを判定する
        if browserPrefixes.contains(where: { bundle.hasPrefix($0) }) {
            if meetPrefixes.contains(where: { title.hasPrefix($0) })
                || meetContains.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                return .googleMeet
            }
            if title.localizedCaseInsensitiveContains("YouTube") {
                return .youtube
            }
            if streamingContains.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                return .streaming
            }
            return .browser
        }
        return .other
    }

    // MARK: 観測

    /// windowID から現在のウィンドウを引いて区分を返す (録画開始時の計測に使う)。
    /// 対象のウィンドウが見つからなければ nil — そのときはパラメータ自体を省略する
    /// («分類不明« という値を送るより «対象がウィンドウでは無い/取れなかった» と
    /// 区別できなくても実害が無いため)。
    ///
    /// 問い合わせは CGWindowList — **SCK の列挙と違い録画開始と競合しない** (issue #70)。
    /// MeetingDetector の検知が常時同じ問い合わせをしているので、録画開始直前に
    /// 呼んでも新たな競合は生まない。`.optionAll` は最小化・別スペースのウィンドウも
    /// 含む (収集対象は必ずしも画面上に無いため)
    static func classify(windowID: UInt32) -> WindowService? {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        guard let info = list.first(where: {
            ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) == windowID
        }) else { return nil }
        let bundle: String?
        if let pid = info[kCGWindowOwnerPID as String] as? Int {
            bundle = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
        } else {
            bundle = nil
        }
        // タイトル (kCGWindowName) は画面収録の権限が無いと取れない。その場合も
        // bundleID だけで決まる区分 (Zoom 等) は出る — 権限が無ければ録画自体が
        // できないので、実際の運用でこの組み合わせは稀
        let title = info[kCGWindowName as String] as? String
        return classify(bundleIdentifier: bundle, title: title)
    }
}
