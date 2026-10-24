import AppKit

/// 収録対象ウィンドウの分類 (WindowService — issue #429) のセルフテスト
/// (KILDE_GUI_SELFTEST_WINDOW_SERVICE=1)。
///
///     KILDE_GUI_SELFTEST_WINDOW_SERVICE=1 KildeGUI.app/Contents/MacOS/KildeGUI
///
/// **実録画を伴わない。** 2 段で確かめる (SelfTestMeeting と同じ構成):
/// 1. 分類規則 (`WindowService.classify(bundleIdentifier:title:)`) を合成データで検証する。
///    会議中・再生中にしなくても «どの bundleID + タイトルをどの区分にするか» を
///    機械的に縛る
/// 2. 実機のウィンドウ一覧 (CGWindowList) を 1 回分類して結果を出す。会議・動画の
///    ウィンドウを開いた状態で実行すれば «今のタグ付けが正しいか» をそのまま確かめられる
///
/// 1 がすべて通れば終了コード 0、1 件でも外れれば 1 (2 は結果を出すだけで合否に含めない —
/// 実行時にどのアプリが動いているかに依存するため)
extension SelfTest {
    @MainActor
    static func reportWindowServiceClassification() -> Never {
        struct Case {
            let name: String
            let bundle: String?
            let title: String?
            let expected: WindowService
        }
        let chrome = "com.google.Chrome", safari = "com.apple.Safari"
        let slack = "com.tinyspeck.slackmacgap", teams = "com.microsoft.teams2"
        let cases: [Case] = [
            // 会議アプリ (アプリ単位で会議扱い)
            Case(name: "Zoom: 会議ウィンドウ", bundle: "us.zoom.xos",
                 title: "Zoom ミーティング", expected: .zoom),
            Case(name: "Zoom: ホーム画面も会議扱い", bundle: "us.zoom.xos",
                 title: "Zoom Workplace", expected: .zoom),
            Case(name: "Teams: 会議ウィンドウ", bundle: teams,
                 title: "Weekly sync | Microsoft Teams", expected: .teams),
            Case(name: "Teams: チャットウィンドウも会議扱い (タイトルで区別できない)",
                 bundle: teams, title: "Chat | Microsoft Teams", expected: .teams),
            Case(name: "Webex", bundle: "Cisco-Systems.Spark",
                 title: "Meeting", expected: .webex),
            Case(name: "Slack: ハドルのウィンドウ", bundle: slack,
                 title: "Huddle - Acme - Slack", expected: .slack),
            Case(name: "Slack: ハドル以外は会議にしない (チャットが主用途)",
                 bundle: slack, title: "general (Channel) - Acme - Slack", expected: .other),
            // ブラウザのタイトル判定
            Case(name: "Meet: Chrome のタブ (参加中)", bundle: chrome,
                 title: "Meet - abc-defg-hij", expected: .googleMeet),
            Case(name: "Meet: en dash のタイトル", bundle: chrome,
                 title: "Meet – abc-defg-hij", expected: .googleMeet),
            Case(name: "Meet: PWA / ホームのタイトル", bundle: chrome,
                 title: "Google Meet", expected: .googleMeet),
            Case(name: "Meet: Safari のタブ", bundle: safari,
                 title: "Meet - abc-defg-hij", expected: .googleMeet),
            Case(name: "YouTube: Chrome のタブ", bundle: chrome,
                 title: "猫の動画 - YouTube", expected: .youtube),
            Case(name: "YouTube: Safari のウィンドウ (タイトルに Safari が付く)",
                 bundle: safari, title: "開発者会議ライブ — YouTube — Safari", expected: .youtube),
            Case(name: "動画配信: Netflix", bundle: chrome,
                 title: "Stranger Things | Netflix - Google Chrome", expected: .streaming),
            Case(name: "動画配信: ABEMA", bundle: chrome,
                 title: "ABEMA | 無料のインターネットテレビ局", expected: .streaming),
            Case(name: "動画配信: Prime Video", bundle: safari,
                 title: "Prime Video: 気になってる人が多いけど", expected: .streaming),
            Case(name: "会議でも動画でもないタブは browser", bundle: chrome,
                 title: "Gmail", expected: .browser),
            // ブラウザ以外ではタイトルの語を使わない (誤判定の防止)
            Case(name: "ブラウザ以外の YouTube を含むタイトルを動画にしない",
                 bundle: "com.apple.iWork.Keynote",
                 title: "YouTube マーケティング戦略.key", expected: .other),
            Case(name: "ブラウザ以外の Meet を含むタイトルを会議にしない",
                 bundle: "com.apple.Notes", title: "Meet の議事メモ", expected: .other),
            // その他
            Case(name: "未知のアプリは other", bundle: "com.example.Something",
                 title: "何かのウィンドウ", expected: .other),
            Case(name: "bundleID が取れないウィンドウ (権限等) は other",
                 bundle: nil, title: nil, expected: .other),
        ]

        var failures = 0
        for c in cases {
            let got = WindowService.classify(bundleIdentifier: c.bundle, title: c.title)
            let ok = got == c.expected
            if !ok { failures += 1 }
            print("selftest: window service [\(ok ? "PASS" : "FAIL")] \(c.name) "
                  + "expected=\(c.expected.rawValue) got=\(got.rawValue)")
        }

        // 計測 (recording_start の window_service) に送る語彙が列挙に閉じていることを
        // 縛る — 大文字・空白・記号・非 ASCII を含む値が増えると GA4 側の集計
        // (カスタム ディメンション) が «別の値» として分裂するため、機械的に弾く
        let vocabularyOK = WindowService.allCases.allSatisfy { service in
            let raw = service.rawValue
            return !raw.isEmpty
                && raw.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        }
        if !vocabularyOK { failures += 1 }
        print("selftest: window service [\(vocabularyOK ? "PASS" : "FAIL")] "
              + "語彙が列挙に閉じている (半角小文字英数字と _ のみ) "
              + "vocabulary=\(WindowService.allCases.map(\.rawValue))")

        // タグの対応 (会議 / 動画) — 並び替え (listRank) とタグ表示の元になる対応の縛り
        let tagCases: [(WindowService, WindowService.Tag?)] = [
            (.zoom, .meeting), (.googleMeet, .meeting), (.teams, .meeting),
            (.webex, .meeting), (.slack, .meeting),
            (.youtube, .video), (.streaming, .video),
            (.browser, nil), (.other, nil),
        ]
        for (service, expectedTag) in tagCases {
            let ok = service.tag == expectedTag
            if !ok { failures += 1 }
            print("selftest: window service [\(ok ? "PASS" : "FAIL")] タグの対応 \(service.rawValue) "
                  + "expected=\(expectedTag.map { "\($0)" } ?? "nil") got=\(service.tag.map { "\($0)" } ?? "nil")")
        }
        // タグ付きはタグ無しより前 (会議を動画より前) に並ぶ
        let rankOK = WindowService.zoom.listRank > WindowService.youtube.listRank
            && WindowService.youtube.listRank > WindowService.browser.listRank
            && WindowService.browser.listRank == WindowService.other.listRank
        if !rankOK { failures += 1 }
        print("selftest: window service [\(rankOK ? "PASS" : "FAIL")] 並び替え順 (会議 > 動画 > その他)")

        // 実機の観測 (合否に含めない)。実在しない ID は nil になることも確認する
        print("selftest: window service live windows:")
        if let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] {
            var bundleCache: [pid_t: String?] = [:]
            for info in list.prefix(40) {
                guard let number = info[kCGWindowNumber as String] as? Int,
                      let pid = info[kCGWindowOwnerPID as String] as? Int,
                      let frameDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: frameDict),
                      rect.width >= 120, rect.height >= 80,
                      // 自分自身 (セルフテスト) と小さいウィンドウは一覧に出さない
                      pid_t(pid) != ProcessInfo.processInfo.processIdentifier
                else { continue }
                let ownerPID = pid_t(pid)
                let bundle: String?
                if let cached = bundleCache[ownerPID] {
                    bundle = cached
                } else {
                    bundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
                    bundleCache[ownerPID] = bundle
                }
                let title = info[kCGWindowName as String] as? String
                let service = WindowService.classify(bundleIdentifier: bundle, title: title)
                print("selftest: window service window=\(number) bundle=\(bundle ?? "?") "
                      + "title=\"\(title ?? "")\" service=\(service.rawValue)")
            }
        }
        print("selftest: window service classify(missing id)="
              + "\(WindowService.classify(windowID: UInt32.max).map { $0.rawValue } ?? "nil")")
        print("selftest: window service failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
