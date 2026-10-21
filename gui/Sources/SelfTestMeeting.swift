import AppKit

/// 会議の自動録画のセルフテスト (KILDE_GUI_SELFTEST_MEETING=1)。
///
///     KILDE_GUI_SELFTEST_MEETING=1 KildeGUI.app/Contents/MacOS/KildeGUI
///
/// **実録画を伴わない。** 2 段で確かめる:
/// 1. 判定規則 (`MeetingDetector.evaluate` / `isAudioActive`) を合成データで検証する。
///    会議に実際に参加しなくても «どの信号の組み合わせで何を会議とみなすか» を機械的に縛る
/// 2. 実機の観測 (CoreAudio のプロセス一覧・CGWindowList) を 1 回行い、結果を出す。
///    会議中に実行すれば «今この会議が検知されるか» をそのまま確かめられる
///
/// 1 がすべて通れば終了コード 0、1 件でも外れれば 1 (2 は結果を出すだけで合否に含めない —
/// 実行時にどのアプリが動いているかに依存するため)
extension SelfTest {
    @MainActor
    static func reportMeetingDetection() -> Never {
        typealias A = MeetingDetector.AudioActivity
        typealias W = MeetingDetector.WindowCandidate
        func audio(_ bundle: String, input: Bool = true, output: Bool = false) -> A {
            A(bundleID: bundle, pid: 1, runningInput: input, runningOutput: output)
        }
        func window(_ id: UInt32, _ bundle: String, _ title: String,
                    size: CGSize = CGSize(width: 1200, height: 800), layer: Int = 0) -> W {
            W(windowID: id, pid: 1, bundleID: bundle, title: title,
              bounds: CGRect(origin: .zero, size: size), layer: layer, isOnScreen: true)
        }
        let zoom = "us.zoom.xos", chrome = "com.google.Chrome", teams = "com.microsoft.teams2"
        let safari = "com.apple.Safari", slack = "com.tinyspeck.slackmacgap"

        struct Case {
            let name: String
            let audio: [A]
            let windows: [W]
            let expected: UInt32?
        }
        let cases: [Case] = [
            Case(name: "Zoom: 会議ウィンドウを選ぶ (メインウィンドウは選ばない)",
                 audio: [audio(zoom)],
                 windows: [window(10, zoom, "Zoom Workplace"), window(20, zoom, "Zoom ミーティング")],
                 expected: 20),
            Case(name: "Zoom: 設定画面のマイクテストでは録らない",
                 audio: [audio(zoom)],
                 windows: [window(10, zoom, "Zoom Workplace"), window(11, zoom, "設定")],
                 expected: nil),
            Case(name: "Zoom: マイク入力が無ければ録らない (出力だけ)",
                 audio: [audio(zoom, input: false, output: true)],
                 windows: [window(20, zoom, "Zoom Meeting")],
                 expected: nil),
            Case(name: "Zoom: 小さすぎるウィンドウは会議とみなさない",
                 audio: [audio(zoom)],
                 windows: [window(20, zoom, "Zoom Meeting", size: CGSize(width: 200, height: 100))],
                 expected: nil),
            Case(name: "Zoom: 浮動レイヤーのウィンドウは会議とみなさない",
                 audio: [audio(zoom)],
                 windows: [window(20, zoom, "Zoom Meeting", layer: 3)],
                 expected: nil),
            Case(name: "Chrome: ヘルパープロセスのマイク + Meet のタブ",
                 audio: [audio("com.google.Chrome.helper")],
                 windows: [window(31, chrome, "Gmail"), window(30, chrome, "Meet - abc-defg-hij")],
                 expected: 30),
            Case(name: "Chrome: Meet 以外のタブでマイクを使っても録らない",
                 audio: [audio("com.google.Chrome.helper")],
                 windows: [window(31, chrome, "YouTube")],
                 expected: nil),
            Case(name: "Chrome のマイクで Safari の Meet を録らない",
                 audio: [audio("com.google.Chrome.helper")],
                 windows: [window(50, safari, "Meet - abc-defg-hij")],
                 expected: nil),
            Case(name: "Teams: 会議らしいタイトルが無ければ最新のウィンドウ",
                 audio: [audio(teams)],
                 windows: [window(45, teams, "Weekly sync | Microsoft Teams"),
                           window(40, teams, "Chat | Microsoft Teams")],
                 expected: 45),
            Case(name: "WebKit のマイクで常駐中の Teams を録らない (帰属があいまい)",
                 audio: [audio("com.apple.WebKit.GPU")],
                 windows: [window(40, teams, "Chat | Microsoft Teams"), window(51, safari, "Apple")],
                 expected: nil),
            Case(name: "Safari: WebKit のマイク + Meet のタブ",
                 audio: [audio("com.apple.WebKit.GPU")],
                 windows: [window(40, teams, "Chat | Microsoft Teams"),
                           window(50, safari, "Meet - abc-defg-hij")],
                 expected: 50),
            Case(name: "Slack: ハドルは最前面の Slack ウィンドウ",
                 audio: [audio("com.tinyspeck.slackmacgap.helper")],
                 windows: [window(60, slack, "general (Channel) - Acme - Slack"),
                           window(61, slack, "Acme - Slack")],
                 expected: 60),
            Case(name: "会議アプリ以外のマイク使用では録らない",
                 audio: [audio("com.apple.VoiceMemos")],
                 windows: [window(20, zoom, "Zoom Meeting")],
                 expected: nil),
        ]

        var failures = 0
        for c in cases {
            let got = MeetingDetector.evaluate(audio: c.audio, windows: c.windows)?.windowID
            let ok = got == c.expected
            if !ok { failures += 1 }
            print("selftest: meeting rule [\(ok ? "PASS" : "FAIL")] \(c.name) "
                  + "expected=\(c.expected.map { "\($0)" } ?? "nil") got=\(got.map { "\($0)" } ?? "nil")")
        }

        // 終了判定: ミュート中 (入力なし) でも出力が流れていれば «会議中»
        let zoomRule = MeetingDetector.apps.first { $0.name == "Zoom" }!
        let activeChecks: [(String, [A], Bool)] = [
            ("終了判定: 出力だけでも会議中", [audio("us.zoom.xos", input: false, output: true)], true),
            ("終了判定: 音声が止まれば会議終了の候補", [], false),
            ("終了判定: 他アプリの音声は数えない", [audio(chrome, input: true, output: true)], false),
        ]
        for (name, list, expected) in activeChecks {
            let got = MeetingDetector.isAudioActive(for: zoomRule, in: list)
            if got != expected { failures += 1 }
            print("selftest: meeting rule [\(got == expected ? "PASS" : "FAIL")] \(name) "
                  + "expected=\(expected) got=\(got)")
        }

        failures += reportCalendarMatching()
        failures += reportRecordingTitleRoundTrip()

        // 実機の観測 (合否に含めない)
        print("selftest: meeting supported=\(MeetingDetector.isSupported)")
        let liveAudio = MeetingDetector.probeAudio()
        for a in liveAudio where a.runningInput || a.runningOutput {
            print("selftest: meeting audio \(a.bundleID) pid=\(a.pid) "
                  + "input=\(a.runningInput) output=\(a.runningOutput)")
        }
        let liveWindows = MeetingDetector.probeWindows()
        print("selftest: meeting audioProcesses=\(liveAudio.count) windows=\(liveWindows.count) "
              + "titled=\(liveWindows.filter { !$0.title.isEmpty }.count)")
        if let detected = MeetingDetector.evaluate(audio: liveAudio, windows: liveWindows) {
            print("selftest: meeting detected app=\(detected.appName) window=\(detected.windowID) "
                  + "title=\(detected.title) exists=\(MeetingDetector.windowExists(detected.windowID).map { "\($0)" } ?? "unknown")")
        } else {
            print("selftest: meeting detected=none")
        }
        print("selftest: meeting failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    /// カレンダーの予定と検知時刻の突き合わせ (issue #393) の純関数テスト。
    /// EventKit に触れない合成データで «どの予定を会議名に使うか» を機械的に縛る
    @MainActor
    private static func reportCalendarMatching() -> Int {
        typealias E = CalendarEventMatcher.Candidate
        func event(_ title: String, _ start: TimeInterval, _ end: TimeInterval,
                   allDay: Bool = false, cancelled: Bool = false) -> E {
            E(title: title, start: Date(timeIntervalSince1970: start),
              end: Date(timeIntervalSince1970: end), isAllDay: allDay, isCancelled: cancelled)
        }
        // 基準: 予定 10:00-11:00 の日時 (秒)
        let start: TimeInterval = 1_700_000_000
        let end = start + 3600
        struct Case {
            let name: String
            let events: [E]
            let at: TimeInterval
            let expected: String?
        }
        let cases: [Case] = [
            Case(name: "予定の途中に検知すれば予定名",
                 events: [event("週次定例", start, end)], at: start + 600, expected: "週次定例"),
            Case(name: "予定の開始前 (早めの入室) でも許容範囲なら予定名",
                 events: [event("週次定例", start, end)], at: start - 300, expected: "週次定例"),
            Case(name: "許容範囲より前に検知したら予定名なし",
                 events: [event("週次定例", start, end)], at: start - 1200, expected: nil),
            Case(name: "予定の終了後 (延長された会議) でも猶予内なら予定名",
                 events: [event("週次定例", start, end)], at: end + 600, expected: "週次定例"),
            Case(name: "猶予を過ぎたら予定名なし",
                 events: [event("週次定例", start, end)], at: end + 3600, expected: nil),
            Case(name: "終日の予定は会議名にしない",
                 events: [event("社外研修", start, end, allDay: true)], at: start + 600, expected: nil),
            Case(name: "キャンセル済みの予定は会議名にしない",
                 events: [event("週次定例", start, end, cancelled: true)], at: start + 600, expected: nil),
            Case(name: "重なるときは最も遅く始まった予定",
                 events: [event("朝会", start - 3600, end), event("週次定例", start, end)],
                 at: start + 600, expected: "週次定例"),
            Case(name: "該当する予定が無ければ予定名なし",
                 events: [event("週次定例", start, end)], at: start + 86400, expected: nil),
            Case(name: "題名が空白だけの予定は使わない",
                 events: [event("  ", start, end)], at: start + 600, expected: nil),
        ]
        var failures = 0
        for c in cases {
            let got = CalendarEventMatcher.title(
                matching: c.events, at: Date(timeIntervalSince1970: c.at))
            let ok = got == c.expected
            if !ok { failures += 1 }
            print("selftest: meeting calendar [\(ok ? "PASS" : "FAIL")] \(c.name) "
                  + "expected=\(c.expected ?? "nil") got=\(got ?? "nil")")
        }
        return failures
    }

    /// 録画ファイル名 `kilde-<時刻>-<題名>` (issue #393) と議事録見出しの題名の復元、
    /// ライブラリの録画日時解析のラウンドトリップ
    @MainActor
    private static func reportRecordingTitleRoundTrip() -> Int {
        struct Case {
            let name: String
            let fileName: String
            let expected: String?
        }
        let cases: [Case] = [
            Case(name: "題名付きの既定名から題名を復元",
                 fileName: "kilde-20261022-103000-週次定例.mp4", expected: "週次定例"),
            Case(name: "題名にハイフンが入っていても全て題名",
                 fileName: "kilde-20261022-103000-第2回-レビュー会.mp4", expected: "第2回-レビュー会"),
            Case(name: "従来の既定名は題名なし",
                 fileName: "kilde-20261022-103000.mp4", expected: nil),
            Case(name: "kilde- で始まる手作り名は題名なし",
                 fileName: "kilde-手作り.mp4", expected: nil),
            Case(name: "kilde- 以外の名前は題名なし",
                 fileName: "review-session.mp4", expected: nil),
        ]
        var failures = 0
        for c in cases {
            let url = URL(fileURLWithPath: "/tmp/\(c.fileName)")
            let got = TranscriptionCoordinator.meetingTitle(fromRecordingName: url)
            let ok = got == c.expected
            if !ok { failures += 1 }
            print("selftest: meeting title [\(ok ? "PASS" : "FAIL")] \(c.name) "
                  + "expected=\(c.expected ?? "nil") got=\(got ?? "nil")")
        }
        // ライブラリの録画日時: 題名付きの名前でもタイムスタンプ部から解析できる
        let titled = URL(fileURLWithPath: "/tmp/kilde-20261022-103000-週次定例.mp4")
        let date = LibraryStore.recordedAt(of: titled, fallback: .distantPast)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let roundTripOK = components.year == 2026 && components.month == 10 && components.day == 22
            && components.hour == 10 && components.minute == 30 && components.second == 0
        if !roundTripOK { failures += 1 }
        print("selftest: meeting title [\(roundTripOK ? "PASS" : "FAIL")] "
              + "ライブラリの録画日時が題名付きの名前から解析できる "
              + "got=\(date)")
        return failures
    }
}
