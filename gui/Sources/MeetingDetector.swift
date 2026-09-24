import AppKit
import CoreAudio
import CoreGraphics

/// オンライン会議の検知 (会議の自動録画)。
///
/// 判定は 2 つの信号の AND:
/// 1. **会議アプリのプロセスがマイク入力を使っている** — CoreAudio のプロセスオブジェクト
///    (`kAudioHardwarePropertyProcessObjectList` / `kAudioProcessPropertyIsRunningInput`、
///    macOS 14.2+)。アプリの起動・常駐だけでは録画を始めないための信号
/// 2. **そのアプリに会議ウィンドウがある** — `CGWindowListCopyWindowInfo` のタイトル・所有者。
///
/// **ウィンドウの列挙に ScreenCaptureKit (`SCShareableContent`) を使わない。** SCK の列挙は
/// 録画開始と重なると両方が無期限に止まり (issue #70)、GUI は列挙と録画を直列化している
/// (SCKStartupLock / RecordingSetup.enumerationsRunning)。検知は数秒おきに常時回るので、
/// SCK を使うとその直列化に常時割り込むことになる。CGWindowList は replayd を経由せず、
/// CGWindowID は SCWindow.windowID と同じ値なので、そのまま `.window(id:)` に渡せる。
/// (タイトルは画面収録権限が無いと取れないが、その場合はどのみち録画できない)
///
/// ここは **判定の純関数 (`evaluate`) と観測 (`probe*`) を分けてある** — 判定規則は
/// セルフテスト (KILDE_GUI_SELFTEST_MEETING) が合成データで機械的に確かめる
enum MeetingDetector {

    // MARK: - 観測データ

    /// 音声を使っているプロセス 1 つ分
    struct AudioActivity: Equatable {
        let bundleID: String
        let pid: pid_t
        let runningInput: Bool
        let runningOutput: Bool
    }

    /// 画面上のウィンドウ 1 つ分 (CGWindowList から)
    struct WindowCandidate: Equatable {
        let windowID: UInt32
        let pid: pid_t
        let bundleID: String?
        let title: String
        let bounds: CGRect
        let layer: Int
        let isOnScreen: Bool
    }

    /// 検知結果。`windowID` は SCWindow.windowID と同じ値 (CGWindowID)
    struct DetectedMeeting: Equatable {
        let appName: String
        let windowID: UInt32
        let title: String
        /// 会議の終了判定 (アプリの音声が止まったか) に使う
        let rule: MeetingApp
    }

    // MARK: - 会議アプリの規則

    /// タイトルが取れない・言語で変わるアプリで、どのウィンドウを «会議» とみなすか
    enum Fallback: Equatable {
        /// タイトルが一致しなければ会議とみなさない (ブラウザ・Zoom)。
        /// ブラウザはマイクを会議以外 (音声入力・通話以外のサイト) でも使うため、
        /// Zoom は設定画面の «マイクのテスト» でマイクが動くため
        case none
        /// 最後に作られたウィンドウ (CGWindowID は単調増加)。参加時に会議用の
        /// ウィンドウを新しく開くアプリ (Teams・Webex) 向け
        case newest
        /// 最前面のウィンドウ。会議がメインウィンドウの中で行われるアプリ (Slack ハドル) 向け
        case frontmost
    }

    struct MeetingApp: Equatable {
        let name: String
        /// マイクを使うプロセスの bundleID の接頭辞。ヘルパープロセス
        /// (例: com.google.Chrome.helper) が音声を扱うので前方一致で見る
        let processPrefixes: [String]
        /// 帰属があいまいなプロセスの接頭辞 (WebKit の GPU / WebContent プロセス)。
        /// Safari 以外の WebKit 利用アプリの音声もここに出るため、**タイトル一致が
        /// 無いと会議とみなさない** (fallback を使わない)
        let weakProcessPrefixes: [String]
        /// 会議ウィンドウを持つアプリ本体の bundleID (前方一致)
        let windowBundlePrefixes: [String]
        let titlePrefixes: [String]
        let titleContains: [String]
        let fallback: Fallback

        func titleMatches(_ title: String) -> Bool {
            titlePrefixes.contains { title.hasPrefix($0) }
                || titleContains.contains { title.localizedCaseInsensitiveContains($0) }
        }

        func ownsProcess(_ bundleID: String, weak: Bool) -> Bool {
            (weak ? weakProcessPrefixes : processPrefixes).contains { bundleID.hasPrefix($0) }
        }

        func ownsWindow(_ window: WindowCandidate) -> Bool {
            guard let bundle = window.bundleID else { return false }
            return windowBundlePrefixes.contains { bundle.hasPrefix($0) }
        }
    }

    /// Google Meet のタブタイトル。Chrome などは CG のウィンドウ名が «アクティブなタブの
    /// タイトル» になり、会議中は "Meet - abc-defg-hij" (言語によって en dash) になる。
    /// PWA 版は "Google Meet"
    private static let meetPrefixes = ["Meet - ", "Meet – "]
    private static let meetContains = ["Google Meet"]

    private static func meet(_ browser: String, processes: [String], weak: [String] = [],
                             windows: [String]) -> MeetingApp {
        MeetingApp(name: "Google Meet (\(browser))", processPrefixes: processes,
                   weakProcessPrefixes: weak, windowBundlePrefixes: windows,
                   titlePrefixes: meetPrefixes, titleContains: meetContains, fallback: .none)
    }

    /// 判定の優先順。上から順に見て最初に当たったものを採る
    static let apps: [MeetingApp] = [
        // Zoom の会議ウィンドウ名は UI 言語で変わる。設定画面のマイクテストで誤検知しない
        // よう fallback は使わず、既知の名前だけを見る
        MeetingApp(
            name: "Zoom", processPrefixes: ["us.zoom."], weakProcessPrefixes: [],
            windowBundlePrefixes: ["us.zoom.xos"], titlePrefixes: [],
            titleContains: ["Zoom Meeting", "Zoom ミーティング", "Zoom Webinar", "Zoom ウェビナー",
                            "Zoom 会议", "Zoom 會議", "Zoom 회의", "Reunión de Zoom"],
            fallback: .none),
        meet("Chrome", processes: ["com.google.Chrome"], windows: ["com.google.Chrome"]),
        meet("Edge", processes: ["com.microsoft.edgemac"], windows: ["com.microsoft.edgemac"]),
        meet("Arc", processes: ["company.thebrowser."], windows: ["company.thebrowser."]),
        meet("Brave", processes: ["com.brave.Browser"], windows: ["com.brave.Browser"]),
        meet("Vivaldi", processes: ["com.vivaldi.Vivaldi"], windows: ["com.vivaldi.Vivaldi"]),
        meet("Opera", processes: ["com.operasoftware.Opera"], windows: ["com.operasoftware.Opera"]),
        meet("Firefox", processes: ["org.mozilla."], windows: ["org.mozilla.firefox"]),
        // Safari の音声は WebKit のプロセス (com.apple.WebKit.GPU 等) に出る
        meet("Safari", processes: ["com.apple.Safari"], weak: ["com.apple.WebKit."],
             windows: ["com.apple.Safari"]),
        // 新 Teams (com.microsoft.teams2) と旧 Teams。参加すると会議用の別ウィンドウが開く。
        // 会議ウィンドウのタイトルは会議名で決まらないため、会議らしい語を優先し、
        // 無ければ最新のウィンドウを採る。WebKit 経由で音声が出ている場合 (帰属が
        // あいまい) はタイトル一致を必須にする。
        // Safari の Meet より後に置く — WebKit の音声はどちらにも帰属しうるので、
        // タイトルで確実に決まる Meet を先に見る
        MeetingApp(
            name: "Microsoft Teams", processPrefixes: ["com.microsoft.teams"],
            weakProcessPrefixes: ["com.apple.WebKit."],
            windowBundlePrefixes: ["com.microsoft.teams"], titlePrefixes: [],
            titleContains: ["Meeting", "会議", "Call", "通話", "会议", "회의", "Reunión", "Llamada"],
            fallback: .newest),
        // Slack のハドルはメインウィンドウ内で行われる (ポップアウトすると "Huddle" の窓)
        MeetingApp(
            name: "Slack", processPrefixes: ["com.tinyspeck.slackmacgap"], weakProcessPrefixes: [],
            windowBundlePrefixes: ["com.tinyspeck.slackmacgap"], titlePrefixes: [],
            titleContains: ["Huddle", "ハドル", "허들"],
            fallback: .frontmost),
        MeetingApp(
            name: "Webex", processPrefixes: ["Cisco-Systems.Spark", "com.webex.", "com.cisco.webex"],
            weakProcessPrefixes: [],
            windowBundlePrefixes: ["Cisco-Systems.Spark", "com.webex.", "com.cisco.webex"],
            titlePrefixes: [], titleContains: ["Meeting", "ミーティング", "会議"],
            fallback: .newest),
    ]

    /// 会議ウィンドウとして扱う最小の大きさ (ツールバー・浮動コントロール・通知の窓を除く)
    static let minimumWindowSize = CGSize(width: 320, height: 200)

    // MARK: - 判定 (純関数)

    /// 観測データから会議を 1 つ選ぶ。無ければ nil。
    /// `windows` は CGWindowList の順 (**前面から背面**) で渡すこと — `.frontmost` が依存する
    static func evaluate(audio: [AudioActivity], windows: [WindowCandidate],
                         apps: [MeetingApp] = MeetingDetector.apps) -> DetectedMeeting? {
        let inputs = audio.filter(\.runningInput)
        guard !inputs.isEmpty else { return nil }
        let usable = windows.filter {
            $0.layer == 0 && $0.isOnScreen
                && $0.bounds.width >= minimumWindowSize.width
                && $0.bounds.height >= minimumWindowSize.height
        }
        for app in apps {
            let strong = inputs.contains { app.ownsProcess($0.bundleID, weak: false) }
            let weak = !strong && inputs.contains { app.ownsProcess($0.bundleID, weak: true) }
            guard strong || weak else { continue }
            let owned = usable.filter(app.ownsWindow)
            guard !owned.isEmpty else { continue }
            if let titled = owned.first(where: { app.titleMatches($0.title) }) {
                return DetectedMeeting(appName: app.name, windowID: titled.windowID,
                                       title: titled.title, rule: app)
            }
            // 帰属があいまいな音声 (WebKit) で fallback を使うと、Safari でマイクを使った
            // だけで常駐中の Teams のウィンドウを録り始めてしまう
            guard strong else { continue }
            let picked: WindowCandidate?
            switch app.fallback {
            case .none: picked = nil
            case .newest: picked = owned.max { $0.windowID < $1.windowID }
            case .frontmost: picked = owned.first
            }
            if let picked {
                return DetectedMeeting(appName: app.name, windowID: picked.windowID,
                                       title: picked.title, rule: app)
            }
        }
        return nil
    }

    /// 会議アプリの音声 (入力・出力のどちらか) がまだ動いているか。
    /// 会議の終了判定に使う — ミュート中でも相手の声 (出力) は流れるので入力だけは見ない
    static func isAudioActive(for app: MeetingApp, in audio: [AudioActivity]) -> Bool {
        audio.contains { activity in
            (activity.runningInput || activity.runningOutput)
                && (app.ownsProcess(activity.bundleID, weak: false)
                    || app.ownsProcess(activity.bundleID, weak: true))
        }
    }

    // MARK: - 観測 (CoreAudio)

    /// プロセスごとの音声の使用状況を取れる OS か (macOS 14.2+)
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// 音声を使っているプロセスの一覧。取れなければ空 (非対応 OS・HAL が応答しない等)
    static func probeAudio() -> [AudioActivity] {
        guard #available(macOS 14.2, *) else { return [] }
        return probeAudioProcesses()
    }

    @available(macOS 14.2, *)
    private static func probeAudioProcesses() -> [AudioActivity] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        // 2 回の呼び出しの間にプロセスが減ると size が縮む。末尾の 0 を読まない
        ids = Array(ids.prefix(Int(size) / stride))
        return ids.compactMap { id -> AudioActivity? in
            // bundleID を持たないプロセス (デーモン等) は会議アプリになりえないので捨てる
            guard let bundleID = stringProperty(id, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty else { return nil }
            let pid = scalarProperty(id, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1
            let input = scalarProperty(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0
            let output = scalarProperty(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            return AudioActivity(bundleID: bundleID, pid: pid,
                                 runningInput: input != 0, runningOutput: output != 0)
        }
    }

    private static func scalarProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          initial: T) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func stringProperty(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        // CoreAudio の CFString 取得は +1 で返る (呼び出し側が解放する)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - 観測 (CGWindowList)

    /// 画面上のウィンドウ (前面から背面の順)
    static func probeWindows() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var bundleCache: [pid_t: String?] = [:]
        return list.compactMap { info -> WindowCandidate? in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int
            else { return nil }
            let ownerPID = pid_t(pid)
            let bundle: String?
            if let cached = bundleCache[ownerPID] {
                bundle = cached
            } else {
                bundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
                bundleCache[ownerPID] = bundle
            }
            var bounds = CGRect.zero
            if let dict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
                bounds = rect
            }
            return WindowCandidate(
                windowID: UInt32(number), pid: ownerPID, bundleID: bundle,
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true)
        }
    }

    /// ウィンドウがまだ存在するか (画面外・他のスペース・最小化も «存在する» に含める)。
    /// 会議の終了判定に使う — Zoom は画面共有中に会議ウィンドウを隠すので、
    /// on-screen だけを見ると共有を始めた瞬間に «会議が終わった» と誤判定する
    static func windowExists(_ windowID: UInt32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID))
                as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }
    }
}
