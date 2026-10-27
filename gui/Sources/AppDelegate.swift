import AppKit
import Combine
import SwiftUI
import KildeCore
// Analytics の API (Analytics クラス) は FirebaseAnalytics モジュールにある。
// SPM 製品 FirebaseAnalyticsCore はリンク用の dummy で import できない —
// 製品依存は FirebaseAnalyticsCore のまま (GoogleAppMeasurementCore が実体で
// IDFA を収集しない)、import だけが transitive モジュール名になる
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

/// メニューバーのステータス項目とポップオーバーの管理。
/// MenuBarExtra (.window) が macOS 26 で開かないため AppKit で手動管理する
/// (経緯は KildeGUIApp.swift のコメント参照)。
///
/// 録画の状態 (RecordingController) と選択 (RecordingSetup) はここが持つ。
/// ポップオーバーを閉じても録画を続けるため、録画の寿命をビューに結び付けない (issue #18)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 生存中のインスタンス。**`NSApp.delegate` からは取れない** —
    /// `@NSApplicationDelegateAdaptor` は SwiftUI が独自のプロキシを
    /// `NSApp.delegate` に据え、この型はその内側に保持されるため、
    /// `NSApp.delegate as? AppDelegate` は nil になる (実測)。
    /// ビュー側からホットキーの再登録を頼む経路がそれで無反応になっていた
    static private(set) weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let recording = RecordingController()
    // セルフテスト起動では移行を行わない — この stored property の初期化は
    // SelfTest.runIfRequested より先に走るため、通常どおり移行まで実行すると
    // セルフテストの起動だけで実環境の config.json / UserDefaults を書き換える
    // (issue #372 — cubic レビュー指摘)。移行の検証はセルフテスト本体が
    // 一時環境で構築する RecordingSetup が担う
    private let setup = RecordingSetup(migrateCaptureTarget: !SelfTest.isActive)
    private let permissions = PermissionsModel()
    /// 録画後の文字起こし (issue #146)。録画と同じく AppDelegate が持つ —
    /// パネルを閉じても処理が続く (TranscriptionCoordinator のコメント参照)
    private let transcription = TranscriptionCoordinator()
    /// 録画完了通知 (issue #20)。UNUserNotificationCenter はデリゲートを弱参照するので、
    /// ここで生存期間を持つ
    private let notifier = RecordingNotifier()
    /// App Store の評価依頼 (issue #156)。MAS ビルドでのみ動く — 直接配布版は
    /// 何もしない置き換えに差し替わる (ReviewPromptCoordinator.swift)
    private let reviewPrompt = ReviewPromptCoordinator()
    /// カレンダー (EventKit) の読み取り (issue #393)。会議の自動録画と同じく
    /// AppDelegate が持つ — 予定の題名の検索は録画開始の経路でパネルと無関係に走るため
    private let calendarTitles = CalendarTitles()
    /// 会議の自動録画。録画 (RecordingController) と同じく AppDelegate が持つ —
    /// パネルを閉じている間 (会議中のほとんどの時間) も監視を続けるため
    private lazy var meetingAutoRecorder = MeetingAutoRecorder(
        setup: setup, recording: recording, permissions: permissions, notifier: notifier,
        calendar: calendarTitles)
    /// 録画ライブラリのウィンドウ (issue #165)。録画と同じく AppDelegate が持つ —
    /// パネルを閉じてもウィンドウを生かすため。
    /// «後から文字起こし» の投入にパネルと同じ TranscriptionCoordinator を渡し (issue #321)、
    /// «議事録を作成» の設定はクロージャで **押された時点の** setup から読ませる。
    /// クロージャには setup を先に取り出して渡す — settings が AppDelegate を
    /// 捕まえると (ライブラリウィンドウの寿命はアプリと同じとはいえ) 循環参照になるため
    private lazy var libraryController: LibraryWindowController = {
        let setup = self.setup
        return LibraryWindowController(
            store: LibraryStore(),
            transcription: transcription,
            pro: pro,
            settings: {
                LibraryTranscriptionSettings(
                    format: setup.transcriptFormat,
                    localeID: setup.transcriptLocale,
                    summaryTemplate: setup.summaryTemplate,
                    summaryUnsupportedReason: setup.summaryUnsupportedReason)
            })
    }()
    /// 自動更新 (issue #122)。Sparkle の起動は環境変数で制御する — 録画系の
    /// セルフテストではネットワークアクセスと更新ダイアログを避けるため
    /// (updaterStartsAtLaunch 参照)
    private(set) lazy var updater = UpdaterCoordinator(
        recording: recording,
        startUpdater: Self.updaterStartsAtLaunch(env: ProcessInfo.processInfo.environment))
    /// チップの購入 (issue #171)。App Store 配布ビルドのみ実体を持ち
    /// (TipCoordinator の実装は APPSTORE 側)、直接配布版ではスタブになる。
    /// セルフテストでは商品を取りにいかない — ASC へのネットワークアクセスを
    /// 録画系の検証に持ち込まない (updaterStartsAtLaunch と同じ配慮)
    private(set) lazy var tips = TipCoordinator(enabled: !SelfTest.isActive)
    /// Pro (要約) の購入と権利 (issue #169 / #170)。チップと同じ構成 —
    /// App Store 配布ビルドのみ StoreKit に触れ、直接配布版はスタブで常に
    /// ロック解除済み、セルフテストでは無効
    private(set) lazy var pro = ProCoordinator(enabled: !SelfTest.isActive)
    private var cancellables: Set<AnyCancellable> = []
    /// グローバルホットキー (issue #20)。CLI と同じ `HotkeyMonitor` / `HotkeySettings` を使い、
    /// 設定 (~/.kilde/config.json の `hotkey`) も CLI と共有する。
    /// nil は «設定されていない» (待機しない)
    private var hotkeyMonitor: HotkeyMonitor?
    /// 解除に失敗して Carbon が握ったままのモニター。次回の適用で再試行する。
    /// 捨てると再度 `stop()` を呼ぶ手段が無くなり、そのキーが効き続ける
    private var pendingRelease: [HotkeyMonitor] = []

    /// 現在登録できているホットキー (nil は未登録)。検証から参照する。
    /// **self-test が自前で HotkeyMonitor を作ると、ここで登録済みのキーと
    /// 排他登録 (kEventHotKeyExclusive) で衝突して必ず失敗する** — 同一プロセス内でも
    /// 二重登録はできないため、登録できたかどうかはこの値で判断する
    var registeredHotkey: String? { hotkeyMonitor?.source }

    /// 検証用。self-test が見ている RecordingSetup が、この AppDelegate が
    /// ホットキーの解決に使ったものと同一インスタンスかを確かめる
    func debugUsesSameSetup(_ other: RecordingSetup) -> Bool { setup === other }

    /// ポップオーバーの既定サイズ。幅 404 は ContentView の外幅 380 (padding 12×2
    /// 込み — `.padding(12)` が `.frame(width: 380)` の内側) より 24pt 広い、
    /// 初回実装 (issue #18) からの既存値。高さは待機中レイアウトの固定高
    /// (ScrollView の maxHeight 420 + その外の行)。
    /// **開くたびにリセットする** — 録画中はコンパクト表示 (sessionView) に合わせて
    /// NSPopover が自動で縮み、その contentSize がポップオーバーに記憶される。
    /// 縮んだまま開き直すと、待機中レイアウトの ScrollView (maxHeight は上限で
    /// 下限ではない) が狭い高さに圧縮されて元に戻らず、設定領域が使い物にならない
    /// (issue #417)
    static let panelContentSize = NSSize(width: 404, height: 600)

    /// Sparkle の更新確認を起動時に始めるか。
    /// - KILDE_GUI_SELFTEST_UPDATE=1: 更新の配線検証なので起動する
    /// - それ以外のセルフテスト (録画・通知・権限): ネットワークアクセスと更新
    ///   ダイアログが検証の邪魔になるので起動しない
    /// - 通常起動: 起動する (Sparkle が前回チェックからの間隔を自分で管理する)
    static func updaterStartsAtLaunch(env: [String: String]) -> Bool {
        if env["KILDE_GUI_SELFTEST_UPDATE"] == "1" { return true }
        if env.keys.contains(where: { $0.hasPrefix("KILDE_GUI_SELFTEST_") }) { return false }
        return true
    }

    /// Firebase を初期化して利用状況の送信 (Analytics / Crashlytics) を始めるか。
    /// - セルフテスト (KILDE_GUI_SELFTEST_*): 送らない。ネットワーク送信とクラッシュ
    ///   報告が検証の邪魔になる (Sparkle と分岐は違う — updaterStartsAtLaunch 参照)
    /// - **Debug 構成: 送らない** (issue #219)。GoogleService-Info.plist は本番アプリの
    ///   BUNDLE_ID / GOOGLE_APP_ID を指したまま (plist は .dev 用に分けない — Firebase
    ///   アプリの追加登録と 2 plist 管理のコストの方が高い)。configure() は plist の
    ///   BUNDLE_ID をそのまま使うため (firebase-ios-sdk 12.19.2 FIROptions.m:208-218 —
    ///   上書きが起こるのはプログラム経路の initWithGoogleAppID:GCMSenderID: のみ)、
    ///   .dev バンドル ID のまま本番 Firebase アプリに繋がる。Debug から送ると本番の
    ///   計測に開発機のデータが混ざり、Crashlytics の報告は dSYM を送っていない
    ///   (project.yml の postBuildScripts は Release 専用) のでシンボル無しで混ざるだけ。
    ///   開発時のクラッシュは Xcode / Console.app で見るため Crashlytics に頼らない
    /// - **ユーザーが設定でオフにしている (issue #435): 送らない**。判定は
    ///   usageReportingPermitted — configure() 自体を呼ばないので Analytics も
    ///   Crashlytics も初期化されない。実行中の切替は telemetryPreferenceDidChange
    /// - 通常起動 (Release 構成、設定オン): 送る
    ///
    /// UsageAnalytics.isEnabled は `FirebaseApp.app() != nil` を見るので、configure()
    /// を飛ばせばイベント送信も Crashlytics も自動で止まる。plist 漏れ (configure() が
    /// NSException を投げて起動即クラッシュ) の検出は Debug ではもう起こらない —
    /// 配布ビルドはすべて Release 構成 (sign.sh / appstore-archive.sh) なので、
    /// アーカイブ時の初回起動で気づく
    static func sendsUsageToFirebase(isSelfTest: Bool) -> Bool {
#if DEBUG
        return false
#else
        return usageReportingPermitted(isSelfTest: isSelfTest, defaults: .standard)
#endif
    }

    /// sendsUsageToFirebase のうち、ビルド構成 (DEBUG) に依らない部分 — セルフテストで
    /// ないこと、かつユーザーの設定 (TelemetryPreferences) がオンであること。
    /// Debug 構成では sendsUsageToFirebase が常に false なので、設定のゲートは
    /// この関数でだけセルフテストから検証できる (SelfTestTelemetry)。`defaults` を
    /// 注入できるのも同じ理由 — 共有の `UserDefaults.standard` を検証で触らない
    static func usageReportingPermitted(isSelfTest: Bool, defaults: UserDefaults) -> Bool {
        !isSelfTest && TelemetryPreferences.isEnabled(defaults)
    }

    /// 設定の «アプリの利用統計とクラッシュレポートを送信する» が変わったときに
    /// ContentView から呼ばれる (issue #435)。
    /// - オフ: Analytics は即時に止まる。Crashlytics は **次回の起動から** (SDK の
    ///   仕様 — TelemetryPreferences.applyToFirebase)。オフのまま起動した次の実行は
    ///   configure() しないため、この間に記録された報告は送られない
    /// - オン: 起動時にオフだったため初期化していなければ**ここで初期化する**。条件は
    ///   起動時のゲート sendsUsageToFirebase と同じ (Debug / セルフテストでは初期化しない)。
    ///   起動時と違い `app_open` は送らない — 起動ではないため。初期化済みなら
    ///   収集を再開するだけ (Firebase 側に永続化された «停止» を解除する —
    ///   TelemetryPreferences.applyToFirebase 参照)
    func telemetryPreferenceDidChange() {
        let enabled = TelemetryPreferences.isEnabled()
        if enabled, FirebaseApp.app() == nil,
           Self.sendsUsageToFirebase(isSelfTest: SelfTest.isActive) {
            startUsageReporting(isLaunch: false)
            return
        }
        TelemetryPreferences.applyToFirebase(enabled: enabled)
    }

    /// Firebase を初期化して利用状況の送信を始める。起動時 (`isLaunch` — app_open を
    /// 送る) と、設定でオンに戻されたとき (telemetryPreferenceDidChange) の 2 経路。
    /// 呼ぶ前に sendsUsageToFirebase で可否を判定していること (ここでは判定しない)
    private func startUsageReporting(isLaunch: Bool) {
        FirebaseApp.configure()
        // «オンに戻す» 経路 (isLaunch == false) では、configure() の直後は Crashlytics
        // の自動収集が «前回オフにした» 設定 (永続化) のまま無効なため、
        // deleteUnsentReports の «自動収集が無効のときだけ効く» 適用条件を満たす。
        // ここで **オフの期間に記録された未送信のクラッシュレポートを削除する** —
        // 削除せずに収集を再開すると、次の起動の自動アップロードで «オフの間の
        // クラッシュ» が送られてしまう (CodeRabbit レビュー指摘)。
        // **起動経路 (isLaunch) では呼ばない** — 設定オンのまま起動したときは前回
        // セッションのクラッシュの報告を送るのが通常動作のため
        if !isLaunch {
            Crashlytics.crashlytics().deleteUnsentReports()
        }
        // 以前に設定でオフにしたとき Firebase 側に永続化された «収集停止» を解除する。
        // Analytics / Crashlytics の収集スイッチは起動をまたいで残るため、configure()
        // だけでは «オフにして終了 → オフで起動 → オンへ戻す» の経路で送信が再開
        // しない (TelemetryPreferences.applyToFirebase のコメント)
        TelemetryPreferences.applyToFirebase(enabled: true)
        // Analytics の初期化は project.yml の OTHER_LDFLAGS: -ObjC に依存する。
        // -ObjC が無いと Analytics の ObjC クラスが「どこからも参照されない」扱いで
        // dead-strip され、configure() してもフレームワークが初期化されない
        // (2026-09-23 実測: -ObjC を付けると configure() 単独で Analytics started)。
        // macOS には UIApplicationDelegate swizzling が無く app_open は自動送信
        // されないので、最初のイベントとして明示的に送る。**ユーザー プロパティを
        // 先に設定する** — プロパティは過去のイベントに遡って適用されないため、
        // 先に app_open を送ると初回起動の app_open にチャネルが載らない
        // (CodeRabbit レビュー指摘)
        UsageAnalytics.setUserProperties()
        if isLaunch {
            Analytics.logEvent("app_open", parameters: nil)
        }
        // クラッシュ解析 (issue #210)。FirebaseCrashlytics をリンクしていれば
        // configure() が自動で有効にし、次回起動時に前回のクラッシュを送る。
        // 明示的に取り出すのは «リンクされて初期化されている» ことをコードに残すため。
        // セルフテスト・Debug 構成・設定オフでは上の configure() 自体を呼ばないので、
        // クラッシュも送らない。
        //
        // **NSApplicationCrashOnExceptions は有効にしない。** Firebase は macOS で
        // これを YES にするよう勧めているが、有効にすると AppKit が握りつぶしていた
        // メインスレッドの未捕捉例外でアプリが落ちるようになる — 録画中なら
        // «必ずファイナライズする» という最重要要件 (CLAUDE.md §1) を壊しうる。
        // その種の例外は報告されない代わりに、シグナル・Swift のトラップ・
        // メインスレッド外の未捕捉例外といった本物のクラッシュは報告される
        _ = Crashlytics.crashlytics()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Firebase Analytics (issue #135)。GoogleService-Info.plist を読んで計測を始める。
        // **plist が無い・不正な場合 configure() は NSException を投げて起動即クラッシュ
        // する** (Swift から捕捉できない)。握りつぶしのガードは足さない — plist は
        // 両ターゲットの resources に必須で、漏れは配布ビルド (Release 構成) の初回
        // 起動で即気づく方が、計測が黙って欠けるより安全 (Debug 構成では送らないため
        // 検出はアーカイブ時になる — sendsUsageToFirebase 参照)
        // 送信を始める条件は sendsUsageToFirebase — セルフテストに加え **Debug 構成でも
        // 送らない** (issue #219、理由は関数のコメント)。ユーザーが設定でオフにして
        // いるときも呼ばない (issue #435)。**Sparkle と分岐は違う** —
        // Sparkle は KILDE_GUI_SELFTEST_UPDATE=1 でも起動する (updaterStartsAtLaunch)
        // が、Firebase はセルフテスト・Debug 構成のどちらでも起動しない
        let isSelfTest = SelfTest.isActive
        if Self.sendsUsageToFirebase(isSelfTest: isSelfTest) {
            startUsageReporting(isLaunch: true)
        }
        // 通知の許可要求はここで 1 回だけ。拒否されても録画は完全に動くので、
        // 失敗として扱わない (通知が出ないだけ)
        notifier.start()
        recording.notifier = notifier
        // Pro 権利 (issue #169/#170)。起動時に必ず組み立てる — ポップオーバーを
        // 一度も開かずに (自動録画だけで) 使うセッションでも、文字起こしの要約
        // ゲートが実行時点の権利を見られるようにするため。licenseProvider の
        // 既定は «権利なし» (フェイルセーフ) なので、この配線が無いと購入済み
        // ユーザーの要約まで弾かれる
        // セルフテストの要約付き経路 (KILDE_GUI_SELFTEST_SUMMARY) は StoreKit を
        // 無効化したまま権利ありで走らせる (MAS ビルドでも issue #163 の経路を
        // 検証できるようにするため — CodeRabbit 指摘)
        transcription.licenseProvider = { [pro] in
            SelfTest.isSummaryPath
                ? LicenseContext(entitlement: .directDistribution)
                : pro.license
        }
        Task { await pro.refreshEntitlements() }
        // 録画完了通知の «文字起こし» アクション → キューへ (issue #392)。配線の
        // 持ち主はここ (onCompletion と同じ向き)。«録画したときの設定» の
        // スナップショットは通知の側に無いため、**押した時点の setup 値**を使う —
        // ライブラリの «後から文字起こし» (issue #321) がライブラリ側の設定で
        // 確定するのと同じ位置づけ。要約は運ばない («文字起こし» という文言の
        // とおりの最小動作。要約はパネルのトグル経路で明示的に選ぶ)。
        // bookmark は通知が録画完了時点で作って運んでいるもの — 保存先変更後の
        // 再起動ではここで作り直せないので、nil のときだけ Coordinator に任せる
        notifier.onTranscribe = { [weak self] url, elapsed, bookmark in
            guard let self else { return }
            guard self.setup.transcriptionAvailable else { return }
            self.transcription.enqueue(TranscriptionCoordinator.Job(
                recordingURL: url,
                format: self.setup.transcriptFormat,
                summaryTemplate: nil,
                localeID: self.setup.transcriptLocale,
                // 通知が持っていた実収録時間 (再起動後のクリックでも userInfo から
                // 復元される)。nil の扱いは «後から文字起こし» と同じ — 区分だけ送る
                recordingDuration: elapsed,
                directoryBookmark: bookmark))
        }
        // 文字起こしの完了 → 通知 (issue #147)。Coordinator は UserNotifications を
        // 知らない (RecordingController.notifier と同じ依存の向き) — 配線の持ち主は
        // ここ。onCompletion は MainActor 上で 1 対 1 に呼ばれるので sink の
        // willSet 問題 (@Published は前値を流す) が無い
        transcription.onCompletion = { [weak self] completion in
            guard let self else { return }
            // 議事録の書き出し (issue #164)。通知の前に走らせる — 失敗の案内を
            // 通知の本文に載せられるようにするため。失敗しても文字起こし自体は
            // 成功なので、案内を設定パネルにも残すのみで終了コード等は変えない
            let (exportedURL, exportNote) = self.setup.exportTranscript(
                sidecarURL: completion.sidecarURL,
                recordingURL: completion.job.recordingURL)
            if let note = exportNote {
                self.setup.exportNotice = note
            }
            // セルフテスト (KILDE_GUI_SELFTEST_EXPORT_DIR): 書き出しの検査に使う
            if let exportDir = ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_EXPORT_DIR"] {
                print("selftest: exported file=\(exportedURL?.lastPathComponent ?? "(none)")"
                    + " dir=\(exportDir)")
            }
            self.notifier.notifyTranscriptionCompleted(
                sidecarURL: completion.sidecarURL,
                summaryGenerated: completion.summary != nil,
                summaryNote: completion.summaryNote)
        }

        // 録画中は経過時間を横に出すので可変幅にする
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem(phase: .idle, elapsed: 0)

        let p = NSPopover()
        p.contentSize = Self.panelContentSize
        // パネル外のクリックで閉じる (メニューバーアプリの標準挙動)。閉じても録画は止まらない
        p.behavior = .transient
        p.contentViewController = NSHostingController(
            rootView: ContentView(
                setup: setup, recording: recording, permissions: permissions, updater: updater,
                transcription: transcription, meetingAutoRecorder: meetingAutoRecorder,
                tips: tips, pro: pro))
        popover = p
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        // 録画の状態と経過時間をアイコンに反映する。@Published は willSet で通知するので、
        // プロパティを読み直さず流れてきた値を使う
        recording.$phase.combineLatest(recording.$elapsed)
            .sink { [weak self] phase, elapsed in
                self?.updateStatusItem(phase: phase, elapsed: elapsed)
            }
            .store(in: &cancellables)

        // 録画が終わった瞬間にパネルを開いたままでも既定サイズへ戻す (issue #417)。
        // 開き直しの経路は showPopover のリセットで拾えるが、開いている間に
        // sessionView (コンパクト) → 待機中レイアウトへ切り替わるこの経路では
        // リセットが走らないまま、縮んだ高さで ScrollView が圧縮されてしまう。
        // 表示中の contentSize 変更はアニメーションされるので、切替のちらつきも無い
        recording.$phase
            .sink { [weak self] phase in
                if !RecordingController.isActive(phase), let popover = self?.popover, popover.isShown {
                    popover.contentSize = Self.panelContentSize
                }
            }
            .store(in: &cancellables)

        // 録画完了 → 文字起こしキューへ (issue #146)。@Published は willSet で新値を
        // 流すが、この時点で RecordingController は completed イベントの処理中なので
        // 出力ファイルは確定済み。.failed は録画ファイルが不完全 (または無い) ので
        // 文字起こししない。選択値は**録画が終わったとき**の setup の値で確定する
        // («開始したとき» ではない — 録画中に選択を変えるとこちらが優先される)。
        // enqueue した時点で Job にコピーされるので、実行が後になった場合 (キュー) の
        // その後の設定変更に引きずられない
        recording.$phase
            .sink { [weak self] phase in
                guard let self, case .finished(let url) = phase else { return }
                guard self.setup.transcribeEnabled, self.setup.transcriptionAvailable else { return }
                self.transcription.enqueue(TranscriptionCoordinator.Job(
                    recordingURL: url,
                    format: self.setup.transcriptFormat,
                    // 要約 (issue #163): トグルがオンかつ Apple Intelligence が使えるときだけ
                    // テンプレートを運ぶ。録画完了時点の setup 値で確定する (文字起こしと同じ)。
                    // **Pro の権利はここで見ない** — 起動直後 (権利の組み立て中) や録画直後の
                    // 購入でテンプレートを失う競合があるため、判定は実行時
                    // (TranscriptionCoordinator のゲート) に一任する (cubic レビュー指摘)
                    summaryTemplate: (self.setup.summaryEnabled && self.setup.summaryAvailable)
                        ? self.setup.summaryTemplate : nil,
                    localeID: self.setup.transcriptLocale,
                    // 録画の長さ。計測 (issue #153) の区分だけに使う。elapsed は
                    // .finished の時点で最後の progress 値のまま (次の start() まで
                    // リセットされない)。progress は 0.5 秒周期なので実長より最大
                    // 0.5 秒短いが、区分 (1 分 / 5 分…) の精度には影響しない
                    recordingDuration: self.recording.elapsed))
            }
            .store(in: &cancellables)

        // 録画 «開始» → その保存先フォルダの bookmark を文字起こし側に先取りさせる
        // (issue #230)。録画 «中» に保存先が変更されると SandboxOutputDirectory.persist()
        // が録画完了より前に旧フォルダの sandbox extension を解放し、完了時 (enqueue) の
        // bookmark 作成が失敗する — 開始時点 (extension が生きている) にとっておけば、
        // そのような録画でも文字起こしが旧フォルダを読み・サイドカーを書ける。
        // willSet の時点で setup.request.outputDirectory は開始に使われた値に確定済み
        // (保存先の選択は start より前に行われる)。transcribe がオフでも保持は無害
        // (bookmark データの差し替えのみで、アクセスの start/stop は伴わない)
        recording.$phase
            .sink { [weak self] phase in
                guard let self, case .recording = phase else { return }
                self.transcription.holdDestinationForRecording(
                    at: self.setup.request.outputDirectory)
            }
            .store(in: &cancellables)

        // 録画の成功完了 → 評価依頼の判定 (issue #156)。«成功した録画の完了 3 回目»
        // を数える。判定は次の MainActor ひと仕事で行う — @Published は willSet で
        // 流れるのでこの場で isActive を読むとまだ .finalizing («録画中») になる
        // (下の updateStatusItem の sink と同じ落とし穴)。長さは elapsed ではなく
        // lastRecordedDuration — elapsed は 0.5 秒周期の刻みなので、閾値ぎりぎりの
        // 録画で最後の更新が 14.5 秒のまま «15 秒以上録ったのに数えられない» ことがある
        recording.$phase
            .sink { [weak self] phase in
                guard let self, case .finished = phase else { return }
                let duration = self.recording.lastRecordedDuration
                Task { @MainActor in
                    self.reviewPrompt.noteRecordingCompleted(
                        duration: duration,
                        recordingActive: self.recording.isActive,
                        // 文字起こしは直前の sink で既に enqueue 済みなので
                        // isBusy に反映されている
                        transcriptionBusy: self.transcription.isBusy)
                }
            }
            .store(in: &cancellables)

        // 文字起こしの開始・終了でメニューバーの表示を取り直す。
        // 進捗 (パーセント) はメニューバーに出さない — «処理中» と分かれば十分で、
        // 0.5 秒間隔の数値更新はステータス項目の幅のちらつきを招く
        transcription.$running.combineLatest(transcription.$queue)
            .sink { [weak self] _, _ in
                guard let self else { return }
                // @Published は willSet で通知するため、この場で isBusy を読むと
                // **古い値**になる。とりわけ最後のジョブの完了 (running=nil) では
                // この後 @Published が更新されないので、同期的に読むと «文字起こし中»
                // 表示が残り続ける。全更新が済んだ次の MainActor ひと仕事で読み直す
                Task { @MainActor in
                    self.updateStatusItem(phase: self.recording.phase, elapsed: self.recording.elapsed)
                }
            }
            .store(in: &cancellables)

        applyHotkeyFromConfig()

        // 会議の自動録画の監視を始める。**セルフテスト中は始めない** — 検証中に
        // 実際の会議を検知して録画が始まると、録画スロットと検証結果の両方が壊れる
        if !isSelfTest {
            meetingAutoRecorder.activate()
        }

        // セルフテストは 1 回ランループを回してから始める — applicationDidFinishLaunching の
        // 中ではステータス項目のボタンがまだウィンドウに載っておらず、NSPopover を出せないため
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            SelfTest.runIfRequested(
                setup: self.setup, recording: self.recording, permissions: self.permissions,
                updater: self.updater, transcription: self.transcription,
                popover: SelfTest.PopoverControl(
                    show: { [weak self] in self?.showPopover() },
                    // performClose は「閉じる要求」なので transient の popover では
                    // 遅延・無視されうる。検証では確実に閉じたいので close() を使う
                    close: { [weak self] in self?.popover?.close() },
                    isShown: { [weak self] in self?.popover?.isShown ?? false }))
        }
    }

    /// 録画中に終了 (メニューの終了・ログアウト等) されたら、停止してファイナライズを待ってから終わる。
    /// 「停止しても必ずファイナライズする」は CLI (SIGINT / SIGTERM / SIGHUP) と同じ最重要要件
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 録画は終わっていても、**完了通知の登録待ちなら終了を保留する** —
        // 待たずに落ちると、録画直後に終了した人に結果が届かない (issue #20 の目的)。
        // 待ちには 2 秒の上限があるので終了が止まり続けることはない。
        // `isActive` に含めない理由は RecordingController 側のコメントを参照
        if !recording.isActive, recording.awaitingNotification {
            recording.whenSessionEnds {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // **文字起こし中は終了を待たない。** サイドカーの書き出しは
        // TranscriptWriter が最後に 1 回だけ原子的に行う (一時ファイル + rename) ので、
        // 途中で終了しても壊れたファイルは残らない。モデルの取得も «部分インストール»
        // が無く中断は無害。長時間の文字起こしで終了を保留すると «終了できないアプリ»
        // になるため、録画のファイナライズ待ち (壊れたファイルを残す) とは扱いを変える。
        // 未書き出しの文字起こし結果は失われるが、再試行は録画ファイルが残っている限り
        // 可能 (サイドカーだけの損失)
        guard recording.isActive else { return .terminateNow }
        recording.whenSessionEnds {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        recording.stop()
        // 猶予を設けて終了を許す案は採らない: writer は Recorder の preparing の途中で作られ、
        // 状態イベントからは「作られた瞬間」が分からない。マイク初期化が長引くと、writer 生成後
        // なのに preparing のまま猶予が切れ、ファイナライズされないファイルを残しうる。
        // 準備中に stop() が効かず終了できない問題は Recorder 側で直す (issue #56)
        return .terminateLater
    }

    /// 設定のホットキーを登録し直す (issue #20)。設定画面からの変更でも呼ぶ。
    ///
    /// **新しい登録が成功するまで旧モニターを捨てない。** 先に解除してから登録すると、
    /// 登録に失敗したときに**旧ホットキーまで失われる** (設定だけ新しい値が残り、
    /// どのキーも効かない状態になる)。`revert` が渡されているときは、
    /// 失敗した設定を書き戻さないよう永続設定も旧値へ巻き戻す。
    ///
    /// 登録失敗 (他アプリとの競合) 自体は録画機能を止める理由にならないので、
    /// notice に出して続ける — 黙って無効にすると «押しても効かない» になる
    /// `revert` を渡すと、登録に失敗したときに設定をその値へ巻き戻す。
    /// **`Optional<String?>` にしているのは «巻き戻さない» と «nil (未設定) へ戻す» を
    /// 区別するため** — 未設定からホットキーを足して登録に失敗したとき、
    /// 区別できないと競合するキーが設定に残り、次回起動でも GUI と CLI が同じ失敗を繰り返す
    func applyHotkeyFromConfig(revert: String?? = nil) {
        let previous = revert ?? nil
        // 解除に失敗して持ち越したモニターを、まず再試行する
        pendingRelease.removeAll { $0.stop() }
        let source: String?
        do {
            source = try HotkeySettings.resolve(explicit: nil, config: setup.config)
        } catch {
            setup.notice = String(localized: "ホットキーの設定を解釈できません: \(error)")
            if revert != nil { setup.restoreHotkey(previous) }
            return
        }

        // 新しい登録を先に作る。ここで失敗しても旧モニターは生きたまま
        var replacement: HotkeyMonitor?
        if let source {
            do {
                let monitor = try HotkeyMonitor(source) { [weak self] in
                    self?.toggleRecordingByHotkey()
                }
                // **既に同じキーが登録済みなら何もしない。** 解除して登録し直すと、
                // その隙に Carbon の登録が失敗したとき旧キーも新キーも失われる
                // (共有設定で previous が nil だと復旧分岐にも入れない)
                if hotkeyMonitor?.source == source { return }
                try monitor.start()
                replacement = monitor
            } catch {
                setup.notice = String(localized: "ホットキーを登録できません (旧設定のままにします): \(error)")
                if revert != nil { setup.restoreHotkey(previous) }
                return
            }
        }
        // 新しい登録が成功した (または設定が空になった) のでここで旧モニターを手放す。
        // **解除に失敗したら置き換えない** — 上書きすると旧モニターへの参照が消え、
        // 新旧のホットキーが両方効いたまま、旧モニターを再解除する機会も失われる
        guard releaseHotkeyMonitor() else {
            // 新モニターの解除にも失敗したら、**参照を保持して次回の適用で再試行する**。
            // 捨てると Carbon が新キーを握ったまま追跡対象から外れ、旧設定へ戻した後も
            // そのキーが録画をトグルし続ける (HotkeyMonitor.stop() の契約どおり)
            if let replacement, !replacement.stop() {
                pendingRelease.append(replacement)
            }
            // 旧モニターが動いたままなので、設定も旧値へ戻す。戻さないと
            // **実際に効くキーと設定ファイルの値が食い違い**、次回起動で
            // 設定側のキーが登録されて挙動が変わる
            if revert != nil { setup.restoreHotkey(previous) }
            return
        }
        hotkeyMonitor = replacement
    }

    /// 旧モニターを解除する。`stop()` が false を返したら解除しきれていない —
    /// HotkeyMonitor は «参照を保持したままリークさせ、再 stop() で再試行できる»
    /// 契約なので、失敗時は参照を捨てずに残す
    @discardableResult
    private func releaseHotkeyMonitor() -> Bool {
        guard let monitor = hotkeyMonitor else { return true }
        if monitor.stop() {
            hotkeyMonitor = nil
            return true
        }
        setup.notice = String(
            localized: "前のホットキーを解除できませんでした (もう一度「適用」を押すと再試行します)")
        return false
    }

    /// ホットキーでの開始/停止。録画中なら止め、そうでなければ今の選択で始める。
    /// Carbon のハンドラはメインスレッドで呼ばれるので、そのまま MainActor の状態を触れる
    private func toggleRecordingByHotkey() {
        if recording.isActive {
            recording.stop()
            return
        }
        permissions.refresh()
        // 開始ボタンと同じ判定を通す — ここを «権限だけ» にしていたために、
        // 列挙中でもホットキーで録画を始められる経路ができていた (cubic P2)。
        // issue #70 で実測したとおり、列挙と録画開始の競合は両方を無期限に止める
        if let reason = setup.startBlockReason(permissions: permissions) {
            // ポップオーバーを開いていないと notice は見えないので、開いて理由を見せる。
            // 他アプリの前面で押されている前提なので «黙って何も起きない» を避ける
            setup.notice = reason
            showPopover()
            return
        }
        do {
            let options = try setup.makeOptions()
            setup.notice = nil
            // パネルの選択を次回起動時の初期選択として保存する (issue #345)。
            // 開始ボタンと同じ意味論 — ボタン経由でしか保存しないと、ホットキー運用の
            // ユーザーの選択が次回に引き継がれない。保存に失敗しても録画開始は止めない
            setup.persistSessionDefaults()
            // 保存に失敗したときはポップオーバーを開いて案内を見せる — この経路は
            // 他アプリの前面から始まるため、開かないと «次回に引き継がれない» ことに
            // 気付けない (cubic レビュー指摘)。直前で notice を nil にしているので、
            // 非 nil は persist の失敗を意味する
            if setup.notice != nil { showPopover() }
            recording.start(options)
        } catch {
            setup.notice = String(localized: "開始できません: \(error)")
            showPopover()
        }
    }

    // MARK: - ショートカット (AppIntents) の窓口 (issue #167)

    /// ショートカットからの録画開始 (KildeIntents.swift の StartRecordingIntent が呼ぶ)。
    /// 開始をかけたなら nil、かけられなければ理由 (そのままインテントの dialog に出す)。
    /// **start() をかけられた時点で nil を返す** — 準備 (デバイス解決・ストリーム構築) は
    /// 非同期で、失敗したら録画の失敗通知 (RecordingNotifier) が届く仕組みがある。
    /// 準備の完了まで待つと、権限ダイアログのような長い待ちでショートカットが
    /// 固まって見える
    func startRecordingForIntent(mode: KildeRecordingMode) -> String? {
        if recording.isActive {
            return String(localized: "すでに録画中です")
        }
        permissions.refresh()
        // 音声ソース・トラック方針・保存先はパネルの現在の選択を引き継ぎ、対象だけを
        // モードで差し替える。«画面 / ウィンドウ» はパネルで選ばれている対象
        // (ディスプレイまたはウィンドウ) を録る — 音声のみになっていたら
        // メインディスプレイへ戻す (音声の選択はそのまま)
        var request = setup.request
        switch mode {
        case .window:
            if case .audioOnly = request.target {
                request.target = .display(index: 0)
            }
        case .audioOnly:
            request.target = .audioOnly
        }
        // 権限は «どれが足りないか» を具体的に返す — パネルを開いていないユーザーには
        // «なぜ始まらないか» を知る手段がインテントの返答しかないため
        let missing = permissions.missing(for: request)
        if !missing.isEmpty {
            let names = missing.map { requirement -> String in
                switch requirement {
                case .screen: return String(localized: "画面収録")
                case .mic: return String(localized: "マイク")
                }
            }.joined(separator: ", ")
            return String(localized: "\(names)の権限が足りないため開始できません")
        }
        // ボタン・ホットキーと同じ判定 (issue #70 の列挙との競合を避ける)。
        // 音声のみ + システム音声オフの構成は画面列挙と競合しないので待たされない
        if let reason = setup.startBlockReason(for: request, permissions: permissions) {
            return reason
        }
        do {
            let options = try setup.makeOptions(for: request)
            recording.start(options)
            return nil
        } catch {
            // error の補間は deprecated 警告になる (debug description を入れる意思表示) ので
            // String(describing:) で明示する
            return String(localized: "開始できません: \(String(describing: error))")
        }
    }

    /// ショートカットからの録画停止。停止をかけたなら nil、かけられなければ理由。
    /// 停止はファイナライズ完了を待たない — 保存の完了は既存の録画完了通知で届く
    func stopRecordingForIntent() -> String? {
        guard recording.isActive else {
            return String(localized: "録画中ではありません")
        }
        // ボタン・ホットキーと同じ経路 (Recorder.stop → ファイナライズ)
        recording.stop()
        return nil
    }

    /// ショートカット用: 最新の文字起こしの内容。見つからなければ nil。
    /// アプリ内で最後に完了した文字起こしを優先し、再起動でメモリ内の記録が消えていたら
    /// 保存先の走査で最新のサイドカーを探す (録画と同じディレクトリに書かれる)。
    /// ファイルの走査とテキストの読み込みは MainActor の外 (Task.detached) で行う —
    /// 保存先が遅いボリュームでもメニューバーの UI を止めないため
    /// («最近の録画» の走査と同じ扱い)
    func latestTranscriptForIntent() async -> String? {
        let lastURL = transcription.lastCompletion?.sidecarURL
        let directory = setup.request.outputDirectory
        return await Task.detached {
            if let lastURL,
               let text = try? String(contentsOf: lastURL, encoding: .utf8),
               !text.isEmpty {
                return text
            }
            return TranscriptLookup.latestText(in: directory)
        }.value
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        // 開くたびに既定サイズへ戻す (panelContentSize のコメント参照 — issue #417)。
        // 前回開いたときのサイズ (録画中に縮んだまま閉じた等) を引き継がない
        popover.contentSize = Self.panelContentSize
        // setup は起動時に 1 回だけ生成され、パネルの再オープンでは init が走らない。
        // 開いている間に CLI 側で変更された文字起こし設定を古い表示が握り続けると、
        // このままトグルを触ったとき古い値が保存される — 開くたびに config から
        // 再読み込みして表示を実体へ追従させる (reloadTranscriptionSettings のコメント参照)
        setup.reloadTranscriptionSettings()
        // PANEL_PRO のセルフテスト (審査用スクリーンショット — issue #169/#170) では
        // 縦を広げて文字起こしセクション (ロック行 + 購入導線) まで 1 画面に収める。
        // ContentView 側のスクロール領域の高さ上限も同じ条件で広げている
        if SelfTest.isPanelPro {
            popover.contentSize = NSSize(width: popover.contentSize.width, height: 1400)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // キャプチャ パネルを開いた (issue #343)。Firebase が無い構成
        // (セルフテスト・Debug) では UsageAnalytics 内で跳ねる
        UsageAnalytics.screenView(.capturePanel)
        // NSPopover の内容は key window にならないため didBecomeKey では拾えない。
        // 開くたびに通知して一覧を更新させる (閉じている間のウィンドウ・デバイスの増減を拾う)
        NotificationCenter.default.post(
            name: .kildePopoverDidShow, object: popover.contentViewController)
    }

    /// 録画ライブラリを開く (issue #165)。ポップオーバーを閉じてからウィンドウを
    /// 出す — ポップオーバーを開いたままにすると、フォーカスがウィンドウに移らず
    /// 検索欄にキー入力できず、見た目も二重になる
    func openLibrary() {
        popover?.performClose(nil)
        libraryController.present(fromDirectory: setup.request.outputDirectory)
    }

    private func updateStatusItem(phase: RecordingController.Phase, elapsed: TimeInterval) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let tint: NSColor?
        let title: String
        // 文字起こし (issue #146)。**録画が進行中なら録画の表示が優先** — «今何を
        // しているか» で失うものが大きいのは録画であり、文字起こしは録画が終わって
        // から走るもの。録画中に文字起こしが並走してもアイコンは録画を示す。
        // 録画の進行判定は **引数の phase から計算する** — この関数は @Published の
        // willSet sink から呼ばれるため、recording.isActive (phase プロパティ) は
        // まだ前の値を見る。録画が .finished になった瞬間 (willSet) に isActive は
        // まだ true なので «録画終了 → 文字起こし表示» への切替がこの後一切
        // 駆動されず、«文字起こし中» が永続的に欠落する
        // (正本は RecordingController.isActive(_:) — willSet でも安全な引数版)
        let recordingActive = RecordingController.isActive(phase)
        if !recordingActive, transcription.isBusy {
            symbol = "waveform"
            tint = .systemPurple
            title = String(localized: "文字起こし中")
        } else {
            switch phase {
            case .recording:
                symbol = "record.circle.fill"
                tint = .systemRed
                title = RecordingController.formatElapsed(elapsed)
            case .paused:
                symbol = "pause.circle.fill"
                tint = .systemOrange
                title = String(localized: "PAUSED") + " " + RecordingController.formatElapsed(elapsed)
            case .starting:
                symbol = "record.circle"
                tint = .systemOrange
                title = String(localized: "準備中")
            case .finalizing:
                symbol = "record.circle"
                tint = .systemOrange
                title = String(localized: "保存中")
            case .idle, .finished, .failed:
                symbol = "record.circle"
                tint = nil
                title = ""
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "kilde")
        // template のまま contentTintColor で色を付ける (待機中はライト/ダークの自動反転に任せる)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " \(title)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                                 weight: .regular)])
        // ツールチップは String なので明示的にローカライズする (title は上で解決済み)
        button.toolTip = title.isEmpty
            ? "kilde"
            : String(localized: "kilde — \(title)")
    }
}

extension Notification.Name {
    /// ポップオーバーを開いた直後に発火 (ContentView の再読込トリガ)
    static let kildePopoverDidShow = Notification.Name("kildePopoverDidShow")

    /// セルフテストの PANEL モードから Pro 購入導線を開くために使う (審査用
    /// スクリーンショットの撮影 — issue #170)。通常操作では使わない
    static let kildeProPurchaseReveal = Notification.Name("kildeProPurchaseReveal")
}
