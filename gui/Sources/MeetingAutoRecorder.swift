import AppKit
import Combine
import KildeCore

/// 会議の自動録画の 1 回分の観測結果。MainActor の外で作って MainActor へ渡すので、
/// 隔離されたクラスの入れ子にせずファイル直下に置く
struct MeetingObservation {
    let audio: [MeetingDetector.AudioActivity]
    let windows: [MeetingDetector.WindowCandidate]
    /// 観測を始めた時点で録画中だったか。観測は非同期なので、適用までの間に
    /// 手動録画が終わると «録画中に始まった会議» を見落とす (CodeRabbit レビュー指摘)
    let recordingWasActive: Bool
    /// 自動録画中の会議ウィンドウがまだあるか (自動録画中でない、または問い合わせに
    /// 失敗して不明なら nil)
    let watchedExists: Bool?
    /// suppressed のうち、**存在しないと確認できた**ウィンドウ (不明なものは含めない)
    let closed: Set<UInt32>
}

/// 会議の自動録画: オンライン会議の開始を検知して、その会議ウィンドウだけを録り、
/// 会議が終わったら止める。
///
/// 録画そのものは手動録画と同じ `RecordingController` (= CLI と同じ `Recorder`) を通す。
/// 自動で始めた録画でも «停止すれば必ずファイナライズされる» 経路は 1 本のまま —
/// ここが持つのは «いつ始めて、いつ止めるか» の判断だけ。
///
/// 録画の持ち主 (RecordingController) と同じく AppDelegate が持つ。パネルの開閉とは無関係に
/// 常駐で監視する (パネルに持たせると、閉じている間 = 会議中のほとんどの時間に動かない)
@MainActor
final class MeetingAutoRecorder: ObservableObject {

    /// UserDefaults のキー。**~/.kilde/config.json には置かない** — GUI 専用の機能で、
    /// 設定ファイルは CLI (kilde-cli-swift の KildeConfig) と共有のスキーマなので、
    /// キーを足すにはエンジン側の変更が要る
    static let enabledDefaultsKey = "autoRecordMeetings"

    /// 監視の周期。CoreAudio のプロパティ読み出しと CGWindowList は数 ms で終わる
    private static let pollInterval: TimeInterval = 2
    /// 同じ会議を何回続けて検知したら始めるか (2 回 = 約 2〜4 秒)。
    /// 参加直後のデバイス切替や、マイクを一瞬だけ開く操作で録画を始めないため
    private static let confirmTicks = 2
    /// 会議ウィンドウが何回続けて見つからなければ «閉じた» とみなすか
    private static let missingWindowTicks = 2
    /// 会議アプリの音声 (入力も出力も) が止まってから停止するまでの猶予。
    /// ウィンドウを閉じずに退出するアプリ (Slack ハドル・ブラウザのタブ) 向けの終了判定。
    /// ミュートしていても相手の声 (出力) は流れているので、会議中に誤って止まることはない
    private static let silentGrace: TimeInterval = 60

    /// 機能のオン/オフ (既定はオフ — 会議の相手を録る機能なので明示的に有効にしてもらう)
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
            if !enabled { candidate = nil }
            updateTimer()
        }
    }

    /// 自動で始めた録画の対象 (自動録画中だけ非 nil)。パネルの表示に使う
    @Published private(set) var activeMeeting: MeetingDetector.DetectedMeeting?

    /// この OS で使えるか (CoreAudio のプロセス単位の状態は macOS 14.2+)
    var isSupported: Bool { MeetingDetector.isSupported }

    private let setup: RecordingSetup
    private let recording: RecordingController
    private let permissions: PermissionsModel
    private let notifier: RecordingNotifier

    private var timer: Timer?
    private var tickInFlight = false
    /// 連続で検知している会議ウィンドウと回数 (confirmTicks のため)
    private var candidate: (windowID: UInt32, count: Int)?
    /// 自動では録らない会議ウィンドウ。**ウィンドウが閉じるまで**覚えておく。
    /// - 自動録画を試みたもの: 失敗しても同じ会議で開始を繰り返さない。
    ///   また、ユーザーが自動録画を手で止めたら、同じ会議の間は録り直さない
    /// - 手動録画の最中に検知したもの: その録画を止めた直後に勝手に録り始めない
    private var suppressed: Set<UInt32> = []
    /// 今のセッションを自動で始めたか。**自動で始めた録画だけを自動で止める** —
    /// 手動の録画を会議の終了で止めてはいけない
    private var ownsSession = false
    private var missingCount = 0
    private var silentSince: Date?
    private var stopRequested = false
    /// 開始通知の保留。**実際に収録が始まった (.recording) ときに出す** —
    /// start() を呼んだ時点ではまだ準備中で、デバイス解決などで失敗しうる。
    /// 先に出すと «開始しました» の直後に «失敗しました» が届く (CodeRabbit レビュー指摘)
    private var pendingStartNotice: (meeting: MeetingDetector.DetectedMeeting, micIncluded: Bool)?
    private var cancellables: Set<AnyCancellable> = []

    init(setup: RecordingSetup, recording: RecordingController,
         permissions: PermissionsModel, notifier: RecordingNotifier) {
        self.setup = setup
        self.recording = recording
        self.permissions = permissions
        self.notifier = notifier
        enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        // @Published は willSet で新しい値を流す。ここでは値そのものしか使わない
        recording.$phase
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &cancellables)
    }

    /// 監視を始める (AppDelegate の起動処理から呼ぶ)。
    /// セルフテスト中は呼ばない — 検証中に実際の会議で録画が始まると検証が壊れる
    func activate() {
        updateTimer()
    }

    // MARK: - 監視

    /// 監視は «有効» の間と、自動録画が続いている間だけ回す。
    /// 録画中に無効にされても、その録画の終了判定までは続ける (止め忘れを作らない)
    private func updateTimer() {
        let needed = isSupported && (enabled || ownsSession)
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            // メニューの追跡中 (.eventTracking) でも回す
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
            candidate = nil
        }
    }

    /// 観測は MainActor の外で行う (CGWindowList・CoreAudio の呼び出しで UI を止めない)
    nonisolated static func observe(watching: UInt32?, suppressed: Set<UInt32>,
                                    recordingWasActive: Bool) async -> MeetingObservation {
        // 存在確認はウィンドウ全体の一覧 1 回で済ませる (問い合わせ失敗なら nil = 不明)
        let existing = MeetingDetector.allWindowIDs()
        return MeetingObservation(
            audio: MeetingDetector.probeAudio(),
            windows: MeetingDetector.probeWindows(),
            recordingWasActive: recordingWasActive,
            watchedExists: watching.flatMap { id in existing.map { $0.contains(id) } },
            closed: existing.map { ids in suppressed.filter { !ids.contains($0) } } ?? [])
    }

    private func tick() {
        guard !tickInFlight, enabled || ownsSession else { return }
        tickInFlight = true
        let watching = ownsSession ? activeMeeting?.windowID : nil
        let suppressedNow = suppressed
        let recordingWasActive = recording.isActive
        Task { [weak self] in
            let observation = await Self.observe(
                watching: watching, suppressed: suppressedNow,
                recordingWasActive: recordingWasActive)
            guard let self else { return }
            self.tickInFlight = false
            self.apply(observation)
        }
    }

    /// 観測結果の適用。判定規則は MeetingDetector.evaluate (純関数)、ここは状態遷移だけ
    func apply(_ observation: MeetingObservation) {
        suppressed.subtract(observation.closed)

        if ownsSession {
            watchForEnd(observation)
            return
        }
        guard enabled else { return }
        guard let detected = MeetingDetector.evaluate(
            audio: observation.audio, windows: observation.windows)
        else {
            candidate = nil
            return
        }
        if suppressed.contains(detected.windowID) {
            candidate = nil
            return
        }
        // 観測開始時と今のどちらかで録画中なら «手動録画中に始まった会議» として扱う
        // (観測中に手動録画が終わっても、観測中に録画が始まっても取りこぼさない)
        if observation.recordingWasActive || recording.isActive {
            // 手動で録っている最中に始まった会議。その録画が終わった後に
            // 同じ会議を勝手に録り始めない (ユーザーは既に自分で録っている)
            suppressed.insert(detected.windowID)
            candidate = nil
            return
        }
        let count = candidate?.windowID == detected.windowID ? (candidate?.count ?? 0) + 1 : 1
        candidate = (detected.windowID, count)
        guard count >= Self.confirmTicks else { return }
        // SCK の列挙 (パネルの一覧更新) と録画開始を重ねない — 両方が無期限に止まる
        // (issue #70)。開始ボタン・ホットキーと同じ条件。次の周期で再試行する
        // (candidate は残すので、列挙が終わればすぐ始まる)
        if setup.loading || setup.enumerationsRunning > 0 { return }
        candidate = nil
        start(detected)
    }

    private func start(_ meeting: MeetingDetector.DetectedMeeting) {
        // 成功しても失敗しても、この会議ウィンドウでは再試行しない。
        // 失敗を繰り返す構成 (保存先が無い等) で 2 秒おきに失敗通知を出さないため
        suppressed.insert(meeting.windowID)
        permissions.refresh()
        // 選択中の保存先・トラック方針は引き継ぎ、対象と音声は会議用に固定する
        // (相手の声 = システム音声、自分の声 = マイク)。ウィンドウ収録ではシステム音声が
        // そのアプリにスコープされる (DESIGN.md §6 の --window) ので、通知音などは混ざらない
        var request = setup.request
        request.target = .window(id: meeting.windowID)
        request.captureSystemAudio = true
        // **マイクの許可ダイアログはここで出さない。** 会議に参加した瞬間にダイアログが
        // 出ると会議の操作を邪魔する。未許可ならシステム音声だけで録り、通知で伝える
        request.captureMic = permissions.micStatus == .authorized
        request.inputDevices = []
        guard permissions.missing(for: request).isEmpty else {
            notifier.notifyFailed(message: String(
                localized: "会議を検知しましたが、画面収録の権限が無いため録画できません"))
            return
        }
        do {
            let options = try setup.makeOptions(for: request)
            // start() の中で phase が .starting になる (sink が同期で呼ばれる) ので、
            // 持ち主の印は先に立てる
            ownsSession = true
            stopRequested = false
            missingCount = 0
            silentSince = nil
            activeMeeting = meeting
            pendingStartNotice = (meeting, request.captureMic)
            updateTimer()
            recording.start(options)
        } catch {
            pendingStartNotice = nil
            notifier.notifyFailed(message: String(localized: "会議の自動録画を開始できません: \(error)"))
        }
    }

    /// 自動録画中の終了判定。ウィンドウが閉じた、または会議アプリの音声が長く止まった
    private func watchForEnd(_ observation: MeetingObservation) {
        guard let meeting = activeMeeting, !stopRequested else { return }
        // 不明 (nil) のときは数えも戻しもしない — 一時的な問い合わせ失敗で
        // 停止に近づけず、直前の «見つからない» も帳消しにしない
        switch observation.watchedExists {
        case false?: missingCount += 1
        case true?: missingCount = 0
        case nil: break
        }
        if MeetingDetector.isAudioActive(for: meeting.rule, in: observation.audio) {
            silentSince = nil
        } else if silentSince == nil {
            silentSince = Date()
        }
        let silentTooLong = silentSince.map { Date().timeIntervalSince($0) >= Self.silentGrace } ?? false
        guard missingCount >= Self.missingWindowTicks || silentTooLong else { return }
        stopRequested = true
        // 手動の停止と同じ経路 (Recorder.stop → ファイナライズ)。完了通知も同じものが出る
        recording.stop()
    }

    private func phaseChanged(_ phase: RecordingController.Phase) {
        guard ownsSession else { return }
        switch phase {
        case .finished, .failed, .idle:
            // 自動録画のセッションが終わった (自動停止・手動停止・失敗のいずれも)。
            // 会議ウィンドウは suppressed に残るので、同じ会議で録り直さない
            ownsSession = false
            stopRequested = false
            activeMeeting = nil
            // 収録に至らなかったセッションの開始通知は出さない (失敗の通知だけが届く)
            pendingStartNotice = nil
            updateTimer()
        case .recording:
            if let notice = pendingStartNotice {
                pendingStartNotice = nil
                notifier.notifyAutoRecordingStarted(
                    appName: notice.meeting.appName, title: notice.meeting.title,
                    micIncluded: notice.micIncluded)
            }
        case .starting, .finalizing:
            break
        }
    }
}
