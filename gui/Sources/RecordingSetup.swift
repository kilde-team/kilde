import AppKit
import ServiceManagement
import KildeCore

/// ポップオーバーの選択状態と、選択肢 (ディスプレイ・ウィンドウ・入力デバイス) の列挙 (issue #18)。
/// 選択 → 録画オプションの変換は KildeCore の `RecordRequest` に任せる (CLI と同じ解決規則)
@MainActor
final class RecordingSetup: ObservableObject {
    @Published var request: RecordRequest
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]
    /// 実行中のアプリ («アプリの音声» ピッカーの選択肢 — issue #364)。
    /// NSWorkspace の列挙はサンドボックス下 (MAS ビルド) でも全アプリの bundleID と
    /// アイコンを返すことを実測済み (フェーズ 0 のスパイク — PR の «サンドボックス・スパイク» 参照)。
    /// 画面の列挙 (SCShareableContent) と違い権限不要・即時に終わるので、reload() のたびに
    /// 同期で取り直す
    @Published private(set) var runningApps: [RunningApp] = []
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    /// 操作の結果 (保存しました / 開始できません 等) を一時的に出す
    @Published var notice: String?
    /// «最近の録画» の 1 行 (issue #147)。録画ファイルと、隣に置かれた文字起こし
    /// サイドカー (無ければ nil)
    struct RecentRecording: Identifiable, Equatable {
        let url: URL
        /// この録画の文字起こしサイドカー。実在が確認できたものだけを入れる —
        /// ビューはこれを «開く» ので、«あると表示されているのに開けない» を作らない
        let transcriptURL: URL?
        var id: URL { url }
    }
    /// 保存先にある直近の録画 (issue #20、サイドカーの有無は issue #147)。新しい順
    @Published private(set) var recentRecordings: [RecentRecording] = []

    /// 一覧に出す件数。メニューを縦に伸ばさない範囲に留める
    private static let recentLimit = 5
    /// 最近の録画の走査の世代。遅れて返った古い走査で新しい一覧を上書きしないために使う
    private var recentGeneration = 0
    /// 最新の走査が完了したか。0 件のディレクトリと «まだ終わっていない» を区別する
    @Published private(set) var recentScanFinished = false

    /// ホットキー入力欄の編集中の値 (issue #20)。適用するまで config には書かない —
    /// 入力途中の "cmd+" のような不完全な文字列で登録を試みないため
    @Published var hotkeyDraft = ""

    /// 「録画後に文字起こし」のオン/オフ (issue #145)。CLI と同じ `transcribe` キーに
    /// 保存するため、GUI で変えた内容は `kilde rec` の既定にもなる。
    /// 未設定 (nil) は CLI の既定と同じオフとして扱う
    @Published var transcribeEnabled = false
    /// 文字起こしの言語 (BCP 47)。nil は「自動」— CLI の省略時と同じく端末の言語設定に従う
    @Published var transcriptLocale: String?
    /// 文字起こし結果のサイドカー形式。CLI と同じ `transcriptFormat` キーに保存する
    @Published var transcriptFormat: TranscriptOutputFormat = .markdown

    /// 録画後の要約 (issue #163)。**GUI ローカルの設定 (UserDefaults)** —
    /// CLI は要約を `--summary` フラグで明示指定する仕組みで設定キーを持たないため、
    /// config.json を共有する文字起こし系設定 (transcribe / locale / format) と違い、
    /// 保存先を UserDefaults にしている
    @Published var summaryEnabled: Bool =
        UserDefaults.standard.bool(forKey: "summaryEnabled") {
        didSet { UserDefaults.standard.set(summaryEnabled, forKey: "summaryEnabled") }
    }
    /// 要約のテンプレート (定例会議 / 商談 / 面接 / 1on1 — kilde-cli-swift#67)
    @Published var summaryTemplate: MeetingTemplate =
        MeetingTemplate(rawValue: UserDefaults.standard.string(forKey: "summaryTemplate") ?? "")
            ?? .standard {
        didSet { UserDefaults.standard.set(summaryTemplate.rawValue, forKey: "summaryTemplate") }
    }

    /// 議事録 (.md) の自動書き出し先 (issue #163)。nil は «書き出さない»。
    /// MAS 版は security-scoped bookmark (SandboxExportDirectory)、直接配布版は
    /// サンドボックスが無いため素のパス (UserDefaults) で持つ — 詳細は
    /// restoreExportDirectory() / chooseExportDirectory() の #if 分岐を参照
    @Published var exportDirectory: URL?
    /// 書き出しの失敗などの案内。設定パネルに表示する (成功時は nil)
    @Published var exportNotice: String?

    // MARK: 録音の告知文 (issue #166)

    /// 利用者が編集した告知文。nil は «既定文案» (現在のアプリ言語のもの)。
    /// **GUI ローカルの設定 (UserDefaults)** — 告知文は録音の同意を取るための
    /// 利用者ごとの文案で、CLI と共有する性質のものではない
    @Published var customNoticeText: String? =
        UserDefaults.standard.string(forKey: "customNoticeText") {
        didSet { saveCustomNotice(customNoticeText) }
    }

    /// コピー・編集の対象になる告知文。編集がなければ現在のアプリ言語の既定文案
    var effectiveNoticeText: String {
        customNoticeText ?? Self.defaultNoticeText
    }

    /// 既定の告知文案 (ローカライズ済み — Localizable.xcstrings に
    /// ja / en / zh-Hans / ko / es の 5 言語を持つ)
    static var defaultNoticeText: String {
        String(localized: "この会議は録音しています。議事録を作成するため、音声を録音させてください。")
    }

    /// 告知文をクリップボードへコピーする。成功したかは戻り値で判別する
    @discardableResult
    func copyNoticeToClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(effectiveNoticeText, forType: .string)
    }

    /// 編集済み告知文を保存する。**既定文案と同一なら UserDefaults を消す** —
    /// アプリの言語を変えたときに «旧言語の固定文案» が残るのを防ぐ
    /// (nil = 既定文をその都度ローカライズして使う)
    private func saveCustomNotice(_ text: String?) {
        if let text, text != Self.defaultNoticeText {
            UserDefaults.standard.set(text, forKey: "customNoticeText")
        } else {
            UserDefaults.standard.removeObject(forKey: "customNoticeText")
        }
    }

    /// 編集を既定文案に戻す
    func resetNoticeText() {
        customNoticeText = nil
    }

    /// 設定ファイル (~/.kilde/config.json) の内容。CLI と共有する (issue #14)
    private(set) var config = KildeConfig()

    /// 収録対象の保存先。**既定は .standard だがセルフテストは別スイートを注入する** —
    /// 共有の standard を検証で消去・復元すると、同時に走っている別プロセスの GUI が
    /// 保存したばかりの収録対象を消してしまうため (cubic レビュー指摘)
    private let defaults: UserDefaults

    /// 列挙の多重実行を防ぐ。UI の読み込み表示 (loading) はタイムアウトで解除して再試行を
    /// 許すが、SCShareableContent の列挙自体は止められない (権限プロンプト保留中は返らない
    /// こともある)。実列挙の完了まで次を始めず、その間の要求は記録して完了後に 1 回だけ再実行する
    /// (PR #45 で ContentView に入れた対策をモデルへ移したもの)
    private var enumerationInFlight = false
    private var needsReload = false
    private var hasLoadedOnce = false
    /// 列挙の世代。タイムアウト後に遅れて返ってきた古い結果 (一覧・サムネイル) を捨てるために使う
    private var generation = 0
    /// 実際に走っている列挙の数。タイムアウトしても SCShareableContent の列挙自体は止められないので、
    /// 上限を設けて「応答しない環境で更新を連打するとタスクが無限に積み上がる」のを防ぐ
    @Published private(set) var enumerationsRunning = 0
    private static let maxConcurrentEnumerations = 3
    /// 入力デバイスの列挙も、返らないことがある (デバイス構成の変更中)。1 本だけ走らせる
    private var audioEnumerationInFlight = false
    /// 入力デバイス列挙の世代。タイムアウト後に始めた新しい列挙の結果を、古い列挙が
    /// 上書きしないようにする (画面の列挙とは独立した世代で数える)
    private var audioGeneration = 0
    /// 実際に走っている入力デバイス列挙の数。タイムアウトでフラグを解放する以上、
    /// 上限を設けないと返らない環境でタスクが積み上がる (画面側と同じ扱い)
    private var audioEnumerationsRunning = 0

    private static let enumerationTimeout: TimeInterval = 10
    /// サムネイルを撮るウィンドウ数の上限 (1 枚ごとに SCScreenshotManager の撮影が走るため)
    private static let thumbnailLimit = 24
    private static let ownBundleID = Bundle.main.bundleIdentifier
#if APPSTORE
    /// 保存先を bookmark に記録できなかったときの警告。**比較に使うので定数にしている** —
    /// 選び直しが成功したらこの警告だけを消すため (cubic レビュー指摘)。
    /// String(localized:) は言語がプロセス内で不変なので、比較の安定性は保たれる
    private static let bookmarkFailureNotice = String(
        localized: "保存先を変更しました。ただし記録できなかったため、次にアプリを起動したときは既定の保存先に戻ります")
#endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
#if APPSTORE
        // **ConfigStore に触るより先に**設定の保存先をコンテナ内へ退避させる (issue #126)。
        // 既定の ~/.kilde はサンドボックス下で読み書きできないため
        SandboxSupport.redirectConfigStoreIntoContainer()
        // サンドボックス下の .moviesDirectory は **コンテナ内の** Movies を返す。
        // そのまま持ち回ると録画がコンテナに落ち、保存先の表示も通知の「Finder で表示」も
        // ユーザーがアクセスできないパスになり、App Store 審査で
        // Guideline 2.4.5(i) としてリジェクトされる (2026-09-17)。
        // 詳細は SandboxSupport.userVisibleMoviesDirectory()
        let fallback = SandboxSupport.userVisibleMoviesDirectory()
#else
        let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
#endif
        request = RecordRequest(outputDirectory: fallback)
        do {
            config = try ConfigStore.load()
        } catch {
            // 壊れた設定でも GUI 自体は開けるようにし、録画開始時に CLI と同じエラーを出す
            notice = String(localized: "設定ファイルを読めません (既定値で表示します): \(error)")
        }
        request = RecordRequest.initial(config: config, fallbackDirectory: fallback)
#if APPSTORE
        // config.json に «コンテナ内のパス» が残っていることがある (リジェクトされた
        // 版で「既定にする」を押した場合)。ユーザーから見えるパスへ正規化してから
        // bookmark の復元にかける
        request.outputDirectory = SandboxSupport.userVisible(request.outputDirectory)
        // 前回 NSOpenPanel で選んだ保存先を bookmark から復元する (issue #126)。
        // サンドボックスでは設定ファイルで知ったパスにはアクセスできないため、
        // 選択で得たディレクトリだけを security-scoped bookmark で持ち越す。
        // **最後の request 再作成より後で行う** — 先に復元すると initial(config:) が
        // request を作り直して復元結果を上書きする (CodeRabbit レビュー指摘)
        if let restored = SandboxOutputDirectory.restore() {
            request.outputDirectory = restored
        } else if !FileManager.default.isWritableFile(atPath: request.outputDirectory.path) {
            // bookmark が無い・復元できない (外付けを外した等) とき、config に残った
            // 保存先はサンドボックスから開けないことがある。そのままだと録画のたびに
            // 開始前で失敗し、既定へ戻る手段もユーザーに見えない (cubic レビュー指摘)。
            // `isWritableFile` はサンドボックスの権限を反映する — movies エンタイトルメント
            // だけのとき ~/Movies=true, ~/Desktop=false になることを実測 (2026-09-18)
            request.outputDirectory = fallback
        }
#endif
        // 前回録画したときの収録対象を復元する (issue #345)。音声ソース・トラック方針・
        // 保存先は上の RecordRequest.initial が config.json から復元済みだが、収録対象
        // (画面 / ウィンドウ / 音声のみ) だけは config.json にキーが存在しないため
        // GUI ローカル (UserDefaults) で持ち越す。ユーザー報告 «「既定値として保存」を押しても
        // capture source selector が保存されない» の直接の原因はここ (保存・復元の両方が無い)
        if let restored = Self.restoreCaptureTarget(defaults: defaults) {
            request.target = restored
        }
        hotkeyDraft = config.hotkey ?? ""
        transcribeEnabled = config.transcribe ?? false
        transcriptLocale = Self.normalizedLocale(config.locale)
        transcriptFormat = config.transcriptFormat
            .flatMap(TranscriptOutputFormat.init(rawValue:)) ?? .markdown
        restoreExportDirectory()
    }

    /// この環境で文字起こしが使えるか。判定は KildeCore の `Transcriber.isSupported`
    /// (macOS 26 以上かつ SpeechTranscriber 利用可能) に任せる — 自前で OS バージョンを
    /// 見ると、SpeechTranscriber が対応しない環境を «対応している» と誤表示する
    var transcriptionAvailable: Bool { Transcriber.isSupported }

    /// 要約 (Apple Intelligence / Foundation Models) がこの環境で使えるか。
    /// 判定は KildeCore の `MeetingSummarizer.unsupportedReason` に任せる
    /// (transcriptionAvailable と同じ方針 — OS バージョンを自前で見ない)
    var summaryAvailable: Bool { MeetingSummarizer.unsupportedReason == nil }

    /// 要約が使えないときの案内文。使えるなら nil
    var summaryUnsupportedReason: String? { MeetingSummarizer.unsupportedReason }

    /// 文字起こしが使えないときの案内文。使えるなら nil
    var transcriptionUnsupportedReason: String? {
        if transcriptionAvailable { return nil }
        // isSupported が false でも理由は 2 通りある。旧 macOS なら案内で足りるが、
        // macOS 26 以上なのに使えない場合は音声データ (対応ロケール) の問題なので文言を分ける
        if #available(macOS 26, *) {
            return String(localized: "この環境では文字起こしを利用できません (macOS 26 以降で、対応言語の音声データが必要です)")
        }
        return String(localized: "文字起こしは macOS 26 以降で利用できます")
    }

    /// config の locale を UI の選択値へ正規化する。空・空白のみは「自動」(nil) と同じ扱いにする —
    /// 手で編集した config.json に空文字が入っていても Picker が壊れないようにするため
    private static func normalizedLocale(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - 開始できるか (issue #20)

    /// 今の選択で録画を開始できない理由。`nil` なら開始できる。
    ///
    /// **開始ボタンとグローバルホットキーの両方がここを通る。** 判定を UI 側
    /// (`disabled` 修飾子) に置くと、ホットキーのようにボタンを経由しない経路が
    /// 素通りしてしまう — 実際 issue #20 の最初の実装がそうなっていて、
    /// **列挙中でも録画を始められる状態を作っていた**。issue #70 で実測したとおり、
    /// `SCShareableContent` の列挙と録画開始が競合すると両方が無期限にブロックするので、
    /// これは «行儀の悪い操作» ではなく実害のある経路になる。
    ///
    /// 文字列を返すのは、ホットキー経路が «なぜ始まらないか» を出す必要があるため
    /// (ボタンは押せないことで伝わるが、他アプリ前面で押したキーには何も見えない)
    func startBlockReason(permissions: PermissionsModel) -> String? {
        startBlockReason(for: request, permissions: permissions)
    }

    /// パネルの現在の選択とは別の構成で同じ判定を行う版 — ショートカット
    /// (AppIntents, issue #167) がモードに応じて target を差し替えた request で使う。
    /// **録画を始める全経路がこの判定を (または同等の自前判定を) 通る**ことで、
    /// «この経路だけ列挙中でも録画を始められる» 状態を作らない。ボタン・ホットキー・
    /// ショートカットはこのメソッドを使い、会議の自動録画 (MeetingAutoRecorder) は
    /// 開始を待ち合わせる形の都合上、同じ条件 (列挙の完了待ちと権限の不足) を
    /// 自前で判定する
    func startBlockReason(for request: RecordRequest,
                          permissions: PermissionsModel) -> String? {
        // SCK を使う構成でだけ列挙との競合を避ける (音声のみ + システム音声オフは競合しない)。
        // 判定は RecordRequest が持つ — ここに書き写すと Recorder 側とずれる (issue #72)
        let usesScreenCapture = request.usesScreenCapture
        // loading も列挙の状態なので SCK を使う構成にだけ効かせる。
        // 無条件に塞ぐと、**SCK を一切使わないマイクのみの録音まで画面列挙の完了待ちに
        // なる** — Recorder はその構成で SCK に触れないので、待たせる理由が無い
        if usesScreenCapture && loading {
            return String(localized: "画面/ウィンドウの一覧を読み込み中です")
        }
        if usesScreenCapture && enumerationsRunning > 0 {
            return String(localized: "画面/ウィンドウの列挙中です (録画開始と同時に行うと両方が止まります)")
        }
        if request.target == .audioOnly && request.audioSourceCount == 0 {
            return String(localized: "音声ソースが選ばれていません (録れるものがありません)")
        }
        if !permissions.missing(for: request).isEmpty {
            return String(localized: "権限が足りないため開始できません")
        }
        return nil
    }

    // MARK: - 録画オプション

    /// 現在の選択から録画オプションを作る。設定ファイルは CLI で変更されている可能性があるので
    /// 開始のたびに読み直す (壊れていれば CLI と同じく開始しない)
    func makeOptions() throws -> RecordOptions {
        try makeOptions(for: request)
    }

    /// パネルの選択とは別の構成で録画オプションを作る (会議の自動録画)。
    /// 設定ファイルの読み直しと保存先の予約は makeOptions() と同じ経路を通す
    func makeOptions(for request: RecordRequest) throws -> RecordOptions {
        config = try ConfigStore.load()
        return try request.makeOptions(config: config)
    }

    /// 選択中の音声ソース・トラック方針・保存先を設定ファイルの既定値にする (CLI の既定も変わる)
    func saveAsDefaults() {
        do {
            let updated = try request.savingDefaults(into: try ConfigStore.load())
            try ConfigStore.save(updated)
            config = updated
            notice = String(localized: "既定値として保存しました (\(ConfigStore.fileURL.path))")
        } catch {
            notice = String(localized: "既定値を保存できません: \(error)")
        }
        // 収録対象も«既定»の対象に含める (issue #345)。«この音声・保存先の選択を既定にする» と
        // ボタンにある以上、収録対象 (capture source selector) が抜けるのはユーザー報告のとおり
        // 不自然 — config.json にキーが無いため GUI ローカルへ保存する
        persistCaptureTarget()
    }

    // MARK: - 録画に使った構成の引き継ぎ (issue #345)

    /// 収録対象を保存する UserDefaults のキー。**GUI ローカル** — config.json (CLI と共有) には
    /// «収録対象» のキーが存在せず (KildeConfig のキー一覧を参照)、エンジン
    /// (kilde-team/kilde-cli-swift) を変更せずに持たせるため。セルフテストから参照するため non-private
    static let captureTargetDefaultsKey = "lastCaptureTarget"

    /// 録画開始時に、パネルの選択を次回起動時の初期選択として保存する (issue #345)。
    ///
    /// **パネルからの録画開始経路 (ボタン・グローバルホットキー) からだけ呼ぶ。**
    /// ポップオーバー操作のたびのディスク書き込みを避けることと、«実際に使った構成が
    /// 次回の既定になる» という意味論のため。会議の自動録画・ショートカット
    /// (AppIntents) はパネルと別の構成 (または対象の差し替え) で始まりうるため呼ばない。
    /// セルフテストの録画経路 (SelfTest の makeOptions → recording.start) も通らない —
    /// «セルフテストはユーザーの config を書き換えない» 規約を守るため、このメソッドは
    /// makeOptions 内ではなく開始経路の側から呼ぶ
    ///
    /// config.json に書くのは音声ソース (`defaultAudioSources`)・トラック方針
    /// (`audioTracks`)・文字起こし (`transcribe`)。変換は `RecordRequest.audioSourceStrings`
    /// (`--audio` と同じ文字列表現) をそのまま使う。**保存先 (`outputDirectory`) は触らない** —
    /// MAS 版は security-scoped bookmark 経由で独立に永続化されており
    /// (SandboxOutputDirectory)、config のパスはコンテナ内を指しえて CLI でも解釈できない。
    /// 収録対象は config.json にキーが無いため UserDefaults へ保存する (persistCaptureTarget)
    ///
    /// 書き込みは load → 反映 → save の順 (saveTranscriptionSetting と同じ理由 —
    /// GUI はメニューバー常駐のため立ち上がったまま長く経つので、起動時スナップショットで
    /// CLI 側の変更を握りつぶさない)。失敗しても**録画開始は止めない** —
    /// 既定値の保存は本質ではなく、開始を妨げる理由がない (案内のみ出す)
    func persistSessionDefaults() {
        do {
            var updated = try ConfigStore.load()
            updated.defaultAudioSources = request.audioSourceStrings
            updated.audioTracks = request.trackPolicy.name
            updated.transcribe = transcribeEnabled
            try ConfigStore.save(updated)
            config = updated
        } catch {
            // 隣の saveAsDefaults と違い String(describing:) を明示する — Error の素の補間は
            // «debug description を使う» deprecation 警告になるため、新規のコードで
            // 警告を増やさない (出力は同じ debug description になる)
            notice = String(localized: "次回起動用の設定を保存できません: \(String(describing: error))")
        }
        persistCaptureTarget()
    }

    /// 収録対象を UserDefaults へ保存する。config.json にこのキーは無い
    /// (captureTargetDefaultsKey のコメント)
    private func persistCaptureTarget() {
        defaults.set(
            Self.encodedCaptureTarget(request.target), forKey: Self.captureTargetDefaultsKey)
    }

    /// RecordRequest.Target を UserDefaults に保存できる文字列へ変換する
    /// ("audioOnly" / "display:<index>" / "window:<id>:<bundleIdentifier>")。
    /// タグを含まない素の列挙なので Codable が使えず、CLI の `--display` / `--window`
    /// と同じ語彙の文字列で持つ
    ///
    /// ウィンドウ選択は **所有アプリの bundle identifier を一緒に保存する** —
    /// windowID は再起動後に別のウィンドウへ再利用されることがあり、ID の存続確認だけでは
    /// «別ウィンドウへすり替わった» ものを復元してしまう (cubic レビュー指摘)。
    /// 復元時は ID の存続と bundle の一致の両方を要求する (restoreCaptureTarget)。
    /// ウィンドウが見つからないときは bundle を空で保存する — 復元時の一致確認は
    /// 必ず失敗し、既定 (ディスプレイ 0) に倒れる
    static func encodedCaptureTarget(
        _ target: RecordRequest.Target, liveWindows: [WindowIdentity]? = nil
    ) -> String {
        switch target {
        case .audioOnly: return "audioOnly"
        case .display(let index): return "display:\(index)"
        case .window(let id):
            let windows = liveWindows ?? Self.currentWindows()
            let bundle = windows.first { $0.id == id }?.bundleIdentifier ?? ""
            return "window:\(id):\(bundle)"
        }
    }

    /// 保存済みの収録対象を、**今の環境で意味が通るか検証してから**復元する。
    /// ディスプレイ番号と windowID は環境で変わる値なので、存在しない対象をそのまま
    /// 選択状態にすると «選んだのに一覧に無い» 状態になる。無効と判断したら nil を返し、
    /// 呼び出し側は既定 (ディスプレイ 0) のままにする
    ///
    /// - ディスプレイ: NSScreen は権限不要で取れる。SCShareableContent の列挙数と
    ///   一致する保証はないが、範囲外の番号を落とす用途には足りる。判定は
    ///   **`0 <= index && index < 台数` の単一規則**にする — «0 は常に有効» の
    ///   特例を入れると、0 台の環境で範囲検証が壊れても見逃される (cubic レビュー指摘)。
    ///   範囲内でも列挙後に消えていた場合は apply の既定経路がディスプレイ 0 へ戻す
    /// - ウィンドウ: **windowID は WindowServer の起動単位で振り直される**ため、
    ///   再起動後の同一ウィンドウ保証は無い。ID の存続に加えて
    ///   **保存時に記録した所有アプリの bundle identifier との一致**を要求する —
    ///   存続確認だけだと、再利用された ID が別アプリのウィンドウを指したまま
    ///   復元され、パネルを開かないホットキー開始で意図しないウィンドウを録りえる
    ///   (cubic レビュー指摘)。bundle の取れないウィンドウはパネルから選べない
    ///   (apply のフィルタ) ので、空の bundle を要求することはない
    static func restoreCaptureTarget(
        defaults: UserDefaults = .standard,
        screens: [NSScreen] = NSScreen.screens,
        liveWindows: [WindowIdentity]? = nil
    ) -> RecordRequest.Target? {
        guard let raw = defaults.string(forKey: captureTargetDefaultsKey) else { return nil }
        if raw == "audioOnly" { return .audioOnly }
        if raw.hasPrefix("display:") {
            guard let index = Int(raw.dropFirst("display:".count)),
                  index >= 0, index < screens.count else { return nil }
            return .display(index: index)
        }
        if raw.hasPrefix("window:") {
            // "window:<id>:<bundleIdentifier>" — bundle は encodedCaptureTarget の
            // コメントのとおり再利用検出のため。ID と bundle の区切りは最初の ":"
            let rest = raw.dropFirst("window:".count)
            guard let separator = rest.firstIndex(of: ":"),
                  separator > rest.startIndex,
                  let id = UInt32(rest[..<separator]) else { return nil }
            let bundle = String(rest[rest.index(after: separator)...])
            guard !bundle.isEmpty else { return nil }
            let windows = liveWindows ?? Self.currentWindows()
            guard let live = windows.first(where: { $0.id == id }),
                  live.bundleIdentifier == bundle else { return nil }
            return .window(id: id)
        }
        return nil
    }

    /// いま生きているウィンドウの識別情報 (CGWindowID と所有アプリの bundle identifier)。
    /// 存在するすべてのウィンドウを対象にする — **最小化・別 Space・画面外のウィンドウも
    /// 復元の対象**にするため (画面上のものだけだと、最小化したまま保存したウィンドウが
    /// 復元できなくなる。cubic レビュー指摘)。MeetingDetector と同じ
    /// CGWindowListCopyWindowInfo の問い合わせで、収録対象の列挙に SCK を使わない
    /// 理由もそちらのコメント。bundle identifier は CGWindowList の辞書には載らないため
    /// (未文書のキーが実測で空。2026-10-15)、MeetingDetector と同じく
    /// 所有プロセスの NSRunningApplication から取る
    struct WindowIdentity {
        let id: UInt32
        let bundleIdentifier: String
    }

    private static func currentWindows() -> [WindowIdentity] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        // NSRunningApplication の問い合わせは PID 単位でまとめる — 同じアプリの
        // ウィンドウごとに LaunchServices を叩かない
        var bundleCache: [pid_t: String?] = [:]
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            let ownerPID = pid_t(pid)
            let bundle: String?
            if let cached = bundleCache[ownerPID] {
                bundle = cached
            } else {
                bundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
                bundleCache[ownerPID] = bundle
            }
            return WindowIdentity(id: UInt32(number), bundleIdentifier: bundle ?? "")
        }
    }

    /// ホットキーを設定ファイルに保存する (issue #20)。CLI の `hotkey` と同じキーなので、
    /// ここで設定すると `kilde rec` も待機モードで起動する。
    /// 空文字は «無効» として unset 相当にする。
    /// 保存前に `HotkeyParser` で検証する — 不正な値を書くと CLI 側が起動時に
    /// エラーになり、GUI から直せない状態に陥る
    /// 戻り値は保存できたか。**失敗したら呼び出し元は登録処理へ進んではいけない** —
    /// 進むと、旧ホットキーの解除だけが行われて何も登録されない状態になりうる
    /// 戻り値は `(保存できたか, 保存直前にファイルにあった hotkey)`。
    /// **巻き戻しには «保存直前の実際の値» を使う** — `setup.config.hotkey` は GUI 起動時に
    /// 読んだ値なので、その間に CLI (`kilde config set hotkey`) が変更していると、
    /// 巻き戻しで CLI の設定を古い値に上書きしてしまう
    func saveHotkey() -> (saved: Bool, previous: String?) {
        let trimmed = hotkeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var onDisk: String?
        do {
            if !trimmed.isEmpty {
                _ = try HotkeyParser.parse(trimmed)
            }
            var updated = try ConfigStore.load()
            onDisk = updated.hotkey
            updated.hotkey = trimmed.isEmpty ? nil : trimmed
            try ConfigStore.save(updated)
            config = updated
            hotkeyDraft = trimmed
            notice = trimmed.isEmpty
                ? String(localized: "ホットキーを無効にしました")
                : String(localized: "ホットキーを \(trimmed) に設定しました")
            return (true, onDisk)
        } catch {
            notice = String(localized: "ホットキーを保存できません: \(error)")
            return (false, onDisk)
        }
    }

    /// 設定ファイルのホットキーを元の値へ戻す (登録に失敗したときの巻き戻し)。
    /// 設定だけ新しい値が残ると、次回の起動で **CLI も GUI も登録できない値**を読む
    func restoreHotkey(_ previous: String?) {
        do {
            var updated = try ConfigStore.load()
            updated.hotkey = previous
            try ConfigStore.save(updated)
            config = updated
            hotkeyDraft = previous ?? ""
        } catch {
            notice = String(localized: "ホットキーの設定を元に戻せません: \(error)")
        }
    }

    // MARK: - 文字起こし (issue #145)

    /// 保存時に書き戻すキー。変更箇所だけを書くための指定 (saveTranscriptionSetting を参照)
    enum TranscriptionSettingKey {
        case enable
        case locale
        case format
    }

    /// 文字起こし設定のうち、変更されたキーだけを CLI と同じ設定ファイルに書き戻す。
    /// トグルと Picker の変更時に呼ぶ (即時保存)。
    ///
    /// 3 キーをまとめて書くと、GUI 起動後に CLI 側 (kilde config set 等) で変更された
    /// 他のキーを**起動時スナップショットで握りつぶす** — GUI はメニューバー常駐のため
    /// 立ち上がったまま長時間経つので、この窓は実際に開いている。
    /// saveHotkey を「触ったキーだけ」の書き込みに絞ったのと同じ理由
    ///
    /// load → 書き換え → save の順で行うのも saveHotkey と同じで、GUI を開いている間に
    /// CLI 側で変更された他のキーを壊さないため。保存に失敗したら変更されたキーの表示を
    /// **直前に読んだ** config の値へ戻す — load 自体が失敗した場合に限り起動時スナップショット
    /// (`config`) を使う。save 失敗時点でファイルの実体は `updated` の内容
    /// (CLI 側の変更込み) なので、古いスナップショットへ戻すと表示が実体とずれる。
    /// 戻さないと「保存したつもり」の選択が次回起動で消え、ずれが続く。成功時は通知を
    /// 出さない (chooseOutputDirectory と同じ方針 — 通知は bookmarkFailureNotice のような
    /// 消えては困る常設警告の受け皿なので、トグル操作のたびに上書きすると警告が消える)
    func saveTranscriptionSetting(_ key: TranscriptionSettingKey) {
        // load に成功したら巻き戻しの基準は新鮮な config (CLI 側の変更を反映した実体) に切り替える
        var rollbackConfig = config
        do {
            var updated = try ConfigStore.load()
            rollbackConfig = updated
            switch key {
            case .enable: updated.transcribe = transcribeEnabled
            case .locale: updated.locale = transcriptLocale
            case .format: updated.transcriptFormat = transcriptFormat.rawValue
            }
            try ConfigStore.save(updated)
            config = updated
        } catch {
            notice = String(localized: "文字起こしの設定を保存できません: \(error)")
            config = rollbackConfig
            switch key {
            case .enable: transcribeEnabled = rollbackConfig.transcribe ?? false
            case .locale: transcriptLocale = Self.normalizedLocale(rollbackConfig.locale)
            case .format: transcriptFormat = rollbackConfig.transcriptFormat
                .flatMap(TranscriptOutputFormat.init(rawValue:)) ?? .markdown
            }
        }
    }

    /// パネルを開くたびに表示中の 3 キーを設定ファイルから読み直す (AppDelegate.showPopover から呼ぶ)。
    /// setup はアプリ起動時に 1 回だけ生成され、パネルを閉じて開き直しても init は走らない。
    /// そのため起動後に CLI (`kilde config set` 等) で変更された値を表示が握り続け、
    /// このままユーザーがトグルを触ると**古い表示値**が保存されてしまう — 開いた時点で
    /// 実体へ追従させておく (保存経路が load から始まるのは saveTranscriptionSetting のとおりで、
    /// ここは表示の再同期だけを担う)
    func reloadTranscriptionSettings() {
        guard let fresh = try? ConfigStore.load() else { return }
        config = fresh
        transcribeEnabled = fresh.transcribe ?? false
        transcriptLocale = Self.normalizedLocale(fresh.locale)
        transcriptFormat = fresh.transcriptFormat
            .flatMap(TranscriptOutputFormat.init(rawValue:)) ?? .markdown
    }

    // MARK: - ログイン時に起動 (issue #20)

    /// ログイン項目に登録されているか。`SMAppService` は状態を同期で返す。
    ///
    /// `.requiresApproval` も**登録済み**として扱う — 登録は成功していて、ユーザーの
    /// 承認待ちなだけ。false にすると登録直後に Toggle が未チェックへ戻り、
    /// 「押したのに効かない」ように見える (承認が要ることは notice で案内する)
    var launchesAtLogin: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// ログイン時起動の切り替え。
    ///
    /// **自動テストでは実行しない** — 登録は利用者のシステム設定 (ログイン項目) を
    /// 実際に書き換える副作用があり、検証のために環境を変えるのは筋が悪い。
    /// `.requiresApproval` はユーザーがシステム設定で承認するまで有効にならないので、
    /// «登録したのに起動しない» と見えないよう案内を出す
    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                notice = SMAppService.mainApp.status == .requiresApproval
                    ? String(localized: "ログイン項目の承認が必要です (システム設定 → 一般 → ログイン項目 で許可してください)")
                    : String(localized: "ログイン時に起動します")
            } else {
                try SMAppService.mainApp.unregister()
                notice = String(localized: "ログイン時の起動を解除しました")
            }
            objectWillChange.send()
        } catch {
            notice = String(localized: "ログイン項目を変更できません: \(error)")
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = request.outputDirectory
        panel.prompt = String(localized: "選択")
        // LSUIElement のアプリはアクティブでないとパネルが他のウィンドウの後ろに出る
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
#if APPSTORE
            // 選択を bookmark に永続化して再起動後も使えるようにする (issue #126)。
            // 保存しないと、選んだ保存先が次回起動時には既定 (~/Movies) へ戻ってしまう。
            // **パネル由来の URL のアクセス可否はここで判定しない** — powerbox が
            // 開始済みで、重ねて start すると extension がリークする
            // (SandboxSupport.persist の説明。Codex レビュー指摘)
            // bookmark を作れなかったときは **選択を採用したうえで** 知らせる —
            // このプロセスでは選んだ保存先を使えるが、次回起動では既定に戻るため
            // (CodeRabbit レビュー指摘)
            if !SandboxOutputDirectory.persist(url) {
                notice = Self.bookmarkFailureNotice
            } else if notice == Self.bookmarkFailureNotice {
                // 前回の «持ち越せなかった» 警告は、選び直しが成功した時点で嘘になる。
                // **他の理由の通知は消さない** — 設定ファイルの読み込みエラーのような、
                // 保存先とは無関係で消えては困る警告が同じ notice に出る
                // (cubic レビュー指摘。提案の «成功したら nil» はそれらも巻き込む)
                notice = nil
            }
#endif
            request.outputDirectory = url
            // 「最近の録画」は保存先を走査して作るので、変更したら取り直す。
            // 忘れると変更前のディレクトリの一覧が残り、クリックすると別の場所が開く
            reloadRecentRecordings()
        }
    }

    // MARK: - 議事録の書き出し先 (issue #164)

    /// 前回起動時に選んだ書き出し先を復元する (init から呼ぶ)。
    /// MAS 版は security-scoped bookmark、直接配布版は素のパス
    private func restoreExportDirectory() {
        #if APPSTORE
        exportDirectory = SandboxExportDirectory.restore()
        #else
        if let path = UserDefaults.standard.string(forKey: "exportDirectoryPath") {
            exportDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
    }

    /// 書き出し先を NSOpenPanel で選ばせる。選択は即座に採用し、
    /// MAS 版では bookmark に永続化する (録画の保存先と同じ流儀)
    func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #if APPSTORE
        // bookmark への永続化に失敗しても選択自体は有効 (この起動中は powerbox の
        // 許可で書ける) — 持ち越せなかったことだけ案内する
        let persisted = SandboxExportDirectory.persist(url)
        exportDirectory = url
        if !persisted {
            exportNotice = String(localized: "書き出し先を変更しました。ただし記録できなかったため、次にアプリを起動したときは書き出しません")
        }
        #else
        UserDefaults.standard.set(url.path, forKey: "exportDirectoryPath")
        exportDirectory = url
        #endif
    }

    /// 書き出し先の解除
    func clearExportDirectory() {
        #if APPSTORE
        SandboxExportDirectory.clear()
        #else
        UserDefaults.standard.removeObject(forKey: "exportDirectoryPath")
        #endif
        exportDirectory = nil
    }

    /// 文字起こしのサイドカー (.md) を書き出しフォルダへ複製する (issue #163 の
    /// 要約つき .md もそのまま運ぶ)。先頭に Obsidian などで文脈が分かる
    /// フロントマター (題名・日時・録画ファイル名) を付ける。
    ///
    /// 戻り値は (書き出した URL, 利用者への案内)。「書き出し先が未設定」は
    /// 正常系 (nil, nil)。すでに同名のファイルがある場合は**上書きせずスキップ**し、
    /// そのことを案内に載せる (TranscriptWriter の上書き禁止と同じ精神)。
    /// 失敗しても**文字起こし自体は成功している**ので、呼び出し側は失敗にせず
    /// 案内として扱うこと
    func exportTranscript(
        sidecarURL: URL, recordingURL: URL
    ) -> (url: URL?, note: String?) {
        guard let directory = exportDirectory else { return (nil, nil) }
        // 書き出すのは Markdown (.md) のみ。要約も .md の先頭側に載る
        guard sidecarURL.pathExtension.lowercased() == "md" else { return (nil, nil) }

        let title = sidecarURL.deletingPathExtension().lastPathComponent
        // 録画ファイルの作成日時 (録画した瞬間) を frontmatter の日時にする。
        // 取れない場合は省略する (誤った日時を付けるより無いほうがよい)
        let created = (try? recordingURL.resourceValues(
            forKeys: [.creationDateKey]))?.creationDate
        let dateLine = created.map { Self.exportDateFormatter.string(from: $0) }

        var frontmatter = "---\ntitle: \(title)\n"
        if let dateLine {
            frontmatter += "date: \(dateLine)\n"
        }
        frontmatter += "recording: \(recordingURL.lastPathComponent)\n---\n\n"

        guard let body = try? String(contentsOf: sidecarURL, encoding: .utf8) else {
            return (nil, "文字起こしの .md を読めませんでした: \(sidecarURL.path)")
        }
        let destination = directory
            .appendingPathComponent(sidecarURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            return (nil, "書き出し先に同名のファイルがあるためスキップしました: \(destination.lastPathComponent)")
        }
        do {
            try (frontmatter + body).write(to: destination, atomically: true, encoding: .utf8)
            return (destination, nil)
        } catch {
            return (nil, "議事録を書き出せませんでした: \(destination.path) (\(error.localizedDescription))")
        }
    }

    /// frontmatter の日時書式。ISO 8601 (ローカルタイムゾーン) — Obsidian などの
    /// プロパティとしてそのまま解釈できる形式
    private static let exportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// 設定ファイル・CLI の `device:<spec>` と同じ照合 (UID の完全一致、または名前の部分一致・
    /// 大文字小文字無視)。`AudioDeviceCatalog.resolveInput` と揃えないと、`device:BlackHole` が
    /// 実デバイス "BlackHole 2ch" に解決されているのに未選択と表示され、クリックすると元の指定を
    /// 残したまま UID を足して同じデバイスを二重に録ってしまう
    private func matches(_ spec: String, _ device: AudioDeviceInfo) -> Bool {
        spec == device.uid || device.name.localizedCaseInsensitiveContains(spec)
    }

    func isSelected(device: AudioDeviceInfo) -> Bool {
        request.inputDevices.contains { matches($0, device) }
    }

    func setSelected(_ selected: Bool, device: AudioDeviceInfo) {
        request.inputDevices.removeAll { matches($0, device) }
        if selected {
            // 追加は UID (完全一致) で入れるので、同名のデバイスがあっても取り違えない
            request.inputDevices.append(device.uid)
        }
    }

    // MARK: - アプリの音声 (issue #364)

    /// ピッカーの選択肢 1 件分。Audio Process Tap は bundleID で解決するので、
    /// **選択の保持も bundleID** (RecordRequest.appSources の要素)
    struct RunningApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    /// 実行中のアプリを取り直す。`reload()` の先頭から呼ぶ — 画面の列挙と違い
    /// 同期で終わるので、in-flight の guard の手前に置いても待ちが発生しない
    ///
    /// 絞り込みの根拠:
    /// - bundleID が取れないプロセスは選べない (保持値が bundleID のため)
    /// - 自アプリ自身は収録対象にしない (画面のウィンドウ一覧と同じ除外)
    /// - activationPolicy が .prohibited (UI の無いヘルパー) はピッカーの語彙として煩雑なので
    ///   外す。**エンジンの解決 (bundleID 完全一致) は prohibited も拾う** ため、
    ///   手編集の config.json がその値を指していれば録れる — ピッカーから見えないだけ
    /// - 同一 bundleID が複数動く (ヘルパー等) 場合は 1 件にまとめる。録画時には
    ///   すべての PID が tap の対象になる (ProcessTapStream.resolveTargets が複数ヒットを
    ///   すべて返すため、見た目 1 項目で録れる音に欠けがない)
    private func reloadRunningApps() {
        let own = Self.ownBundleID
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, bundleID != own else { return nil }
            switch app.activationPolicy {
            case .regular, .accessory: break
            default: return nil
            }
            guard seen.insert(bundleID).inserted else { return nil }
            return RunningApp(bundleID: bundleID,
                              name: app.localizedName ?? bundleID,
                              icon: app.icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// spec がこの実行中アプリに解決されるか。照合は**エンジンの解決順と同じ**
    /// «bundleID の完全一致 (大文字小文字を無視) → 名前の部分一致» —
    /// 手編集 config の `app:Safari` のような名前指定を、実行中アプリ
    /// «Safari» (com.apple.Safari) のメニュー項目で «未選択» と誤表示すると、
    /// クリックで同じアプリが二重に足される (CodeRabbit レビュー指摘)。
    /// 名前の部分一致は解決のフォールバック (音声を出しているプロセス限定) を
    /// 精度より採用側で広く見る — «選べるはずなのに未選択» より «選択中» 表示の
    /// 誤りのほうが被害が小さい (外す操作は同じアプリに束ねて効くため)
    func resolvesToApp(_ spec: String, app: RunningApp) -> Bool {
        app.bundleID.caseInsensitiveCompare(spec) == .orderedSame
            || app.name.localizedCaseInsensitiveContains(spec)
    }

    /// この実行中アプリに解決される選択済みの音声ソースがあるか
    /// (メニュー項目の選択表示)
    func hasSelectedSource(resolvingTo app: RunningApp) -> Bool {
        request.appSources.contains { resolvesToApp($0, app: app) }
    }

    /// 選択中のアプリ音声のうち、実行中のアプリ一覧に無いもの (前回の選択を復元したが
    /// そのアプリが終わっていた等)。ピッカーに «実行中でない» 項目として出す —
    /// 一覧から消えるだけだと «選んだ音声が何か» が見えず、外すこともできるようにするため。
    /// «実行中» の判定は resolvesToApp と同じ
    var unrunningSelectedAppSources: [String] {
        request.appSources.filter { spec in
            !runningApps.contains { resolvesToApp(spec, app: $0) }
        }
    }

    /// アプリの音声ソースの選択を切り替える (ピッカーの本体)。
    ///
    /// 選ぶときは **システム音声を先に外す** — エンジンが «app: と system の併用» を
    /// makeOptions / savingDefaults の両方で拒否するため (RecordRequest.checkSourceCombination)。
    /// UI で先に外しておかないと、選んだ直後の録画開始 («既定値として保存» も) が
    /// 必ず requestInvalid で失敗する状態になる。**マイクとの併用は可** (エンジン契約どおり)。
    /// 切替の理由はピッカーの下の案内文 (ContentView.appAudioPicker) が担う
    ///
    /// 追加は **spec をそのまま保持するが、同じ実行中アプリに解決される既存の指定を
    /// 先に外す** — `app:Safari` (名前指定) が保存済みのときに実行中アプリ «Safari» の
    /// 項目をクリックすると、`app:Safari` を外して `app:com.apple.Safari` を足す。
    /// 両方が併存するとエンジンが同じプロセスを 2 つのソースとして解決し、
    /// 同じ音を二重に録ることになる (CodeRabbit レビュー指摘)
    func setAppSource(_ selected: Bool, spec: String) {
        let sameApps = runningApps.filter { resolvesToApp(spec, app: $0) }
        request.appSources.removeAll { existing in
            existing.caseInsensitiveCompare(spec) == .orderedSame
                || sameApps.contains { resolvesToApp(existing, app: $0) }
        }
        if selected {
            request.captureSystemAudio = false
            request.appSources.append(spec)
        }
    }

    /// システム音声トグルの反映。オンにしたときアプリの音声を空にする —
    /// «system + app» の不正な組合せを作らない (setAppSource のコメント)。
    /// Binding の set から呼ぶ (UI 側で `$request.captureSystemAudio` を直接触ると
    /// この排他を踏めず、セルフテストからも検証できない)
    func setSystemAudio(_ enabled: Bool) {
        request.captureSystemAudio = enabled
        if enabled { request.appSources = [] }
    }

    // MARK: - 最近の録画 (issue #20)

    /// 保存先ディレクトリを走査して直近の録画を集める。
    ///
    /// セッションの履歴を別に持たずファイル名で拾うのは、**CLI で録ったファイルも
    /// 同じ一覧に出る**ため。kilde の既定名 (`defaultOutputName`) は
    /// `kilde-yyyyMMdd-HHmmss.{mov,mp4,m4a}` なので、この接頭辞と拡張子で絞る。
    /// `-o` で別名を付けた録画は拾えないが、一覧は補助表示なので取りこぼしを許容する
    /// (取り違えて無関係なファイルを出すより良い)
    func reloadRecentRecordings() {
        let directory = request.outputDirectory
        let extensions: Set<String> = ["mov", "mp4", "m4a"]
        // サイドカーの拡張子は TranscriptOutputFormat が持つ値を使う —
        // 形式が増えたときにここが古いままだと、その形式のサイドカーだけ
        // «文字起こしなし» と表示される。ショートカットの文字起こし探索
        // (TranscriptLookup) と同じ集合を見る
        let transcriptExtensions = Self.transcriptSidecarExtensions
        // 画面の列挙と同じ理由で世代を数える — 保存先を変えて開き直したとき、
        // 前のディレクトリ (件数が多い・遅いボリューム) の走査が後から返ってきて
        // 新しい結果を古い一覧で上書きするのを防ぐ
        recentGeneration += 1
        let generation = recentGeneration
        // ファイル走査はディレクトリの中身が多いと待たされるので UI を止めない。
        // 失敗 (権限・存在しない) は空の一覧として扱う — 補助表示なのでエラーにしない
        let scan = Task.detached { [limit = Self.recentLimit] () -> [RecentRecording] in
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { return [] }
            let regular = entries.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            // サイドカーの候補 (TranscriptOutputFormat の拡張子を持つ通常ファイル) を
            // 先に分けておく — ディレクトリの走査は 1 回で済ませる
            let sidecarCandidates = regular.filter {
                transcriptExtensions.contains($0.pathExtension.lowercased())
            }
            return regular
                .filter { url in
                    url.lastPathComponent.hasPrefix("kilde-")
                        && extensions.contains(url.pathExtension.lowercased())
                }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return da > db
                }
                .prefix(limit)
                .map { recording in
                    RecentRecording(
                        url: recording,
                        // Task.detached の @Sendable クロージャ内では self を
                        // 捕まえられないため、static は型名で明示的に呼ぶ
                        transcriptURL: RecordingSetup.transcriptSidecar(
                            for: recording, among: sidecarCandidates))
                }
        }
        // 走査を始める前に一覧を空にする。**残したままだと、保存先を変えた直後の
        // 走査中に旧ディレクトリのファイルが操作可能なまま表示され、クリックすると
        // 旧ディレクトリが開く。** 画面の列挙 (apply) が古い一覧を残さないのと同じ理由
        recentRecordings = []
        recentScanFinished = false
        Task { [weak self] in
            let urls = await scan.value
            guard let self, generation == self.recentGeneration else { return }
            self.recentRecordings = urls
            // 走査が終わったことを «結果が空でないこと» で代用しない — 本当に 0 件の
            // ディレクトリと区別できず、検証側が無駄に待つことになる
            self.recentScanFinished = true
        }
    }

    /// サイドカーの拡張子 (`TranscriptOutputFormat` の rawValue と同じ)。形式が増えた
    /// ときに呼び出し側が古い集合を持つと、その形式のサイドカーだけ «文字起こしなし»
    /// と表示されるため 1 箇所に集約する。ショートカットの文字起こし探索
    /// (TranscriptLookup, issue #167) もこれを見る。
    /// nonisolated: «最近の録画» の Task.detached と TranscriptLookup (nonisolated)
    /// から触るため
    nonisolated static let transcriptSidecarExtensions: Set<String> = Set(
        TranscriptOutputFormat.allCases.map(\.fileExtension))

    /// 録画に対応する文字起こしサイドカーを候補の中から探す (issue #147)。
    ///
    /// サイドカーの既定名は `<録画の stem>.<形式の拡張子>` (TranscriptWriter.sidecarURL)。
    /// ただし **既定名が使用済みのとき `-2`, `-3` … に退避する** ので、既定名の存在確認
    /// だけだと «2 回目の文字起こし» が «文字起こしなし» に見える。そこで
    /// **stem が完全一致、または `<stem>-<数字>`** のものをすべて集め、
    /// 更新日時が最も新しいものを «この録画の文字起こし» とする
    /// (`-2` より後の退避がどう選ばれるかは表示・開く導線のどちらでも問題にならない。
    /// どれも同じ内容の文字起こしで、最新のものが最も意図に近い)
    ///
    /// `<stem>-<数字>` は **数字だけ** の接尾辞に限る — `kilde-a.md` があるとき
    /// `kilde-a-extra.md` を «kilde-a の退避» と誤判定すると、無関係なファイルを
    /// «文字起こし» として開いてしまう
    /// nonisolated: 走査は Task.detached (UI を止めない) から呼ぶため。
    /// 純関数 (引数だけで決まり、状態を持たない) なので隔離は不要
    nonisolated static func transcriptSidecar(for recording: URL, among candidates: [URL]) -> URL? {
        let stem = recording.deletingPathExtension().lastPathComponent
        let suffixSeparator = stem + "-"
        let matches = candidates.filter { url in
            let candidate = url.deletingPathExtension().lastPathComponent
            if candidate == stem { return true }
            guard candidate.hasPrefix(suffixSeparator) else { return false }
            let digits = candidate.dropFirst(suffixSeparator.count)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        return matches.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da < db
        }
    }

    // MARK: - 列挙

    func reload() {
        // アプリの一覧 (NSWorkspace) は同期・権限不要なので、画面の列挙が in-flight でも
        // 先に取り直す — «アプリを起動したままパネルを開き直した» 選択肢の増減を拾う
        reloadRunningApps()
        guard !enumerationInFlight else {
            // 初回ロード中の要求 (onAppear とポップオーバー表示通知の同時発火) は同じ結果になるので捨てる
            if hasLoadedOnce { needsReload = true }
            return
        }
        guard enumerationsRunning < Self.maxConcurrentEnumerations else {
            // 前の列挙が返ってこないまま上限に達した (権限プロンプト保留中など)。
            // enumerationsRunning は 0 に戻らないので、録画開始もこの間は止まる
            loadError = String(localized: "画面/ウィンドウの列挙が応答しません。画面収録の権限確認が保留になっていないか確認してください")
            return
        }
        enumerationInFlight = true
        enumerationsRunning += 1
        loading = true
        generation += 1
        let generation = self.generation
        // 入力デバイスの列挙 (CoreAudio) は権限不要で普通は速いが、デバイス構成の変更中などに
        // ブロックすることがある。メニューバーの UI を止めないよう detached で回し、結果だけ反映する
        if !audioEnumerationInFlight, audioEnumerationsRunning < Self.maxConcurrentEnumerations {
            audioEnumerationInFlight = true
            audioEnumerationsRunning += 1
            audioGeneration += 1
            let audioGeneration = self.audioGeneration
            let audioTask = Task.detached { () -> [AudioDeviceInfo] in
                AudioDeviceCatalog.devices.filter { $0.inputChannels > 0 }
            }
            // 画面側と同じく、止められない列挙が実際に終わった時点で本数を戻す
            Task { [weak self] in
                _ = await audioTask.value
                self?.audioEnumerationsRunning -= 1
            }
            Task { [weak self] in
                let devices = await Self.value(of: audioTask, timeout: Self.enumerationTimeout)
                guard let self, audioGeneration == self.audioGeneration else { return }
                // タイムアウトでもフラグは解放する — 解放しないと、CoreAudio が返らない環境で
                // 入力デバイス一覧がアプリ再起動まで二度と更新されなくなる。
                // 世代で判定しているので、古い列挙が新しい結果を上書きすることはない
                self.audioEnumerationInFlight = false
                if let devices { self.inputDevices = devices }
            }
        }

        let enumerate = Task.detached { () -> Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error> in
            do { return .success(try await DisplayCatalog.snapshot()) }
            catch { return .failure(error) }
        }
        // タイムアウトしても列挙は止められないので、実際に完了した時点で本数を戻す
        Task { [weak self] in
            _ = await enumerate.value
            self?.enumerationsRunning -= 1
        }
        Task { [weak self] in
            let finished = await Self.value(of: enumerate, timeout: Self.enumerationTimeout)
            guard let self, generation == self.generation else { return }
            self.apply(finished, generation: generation)
            self.loading = false
            self.hasLoadedOnce = true
            // タイムアウトしても列挙状態は解放する — 解放しないと、権限プロンプト保留などで
            // 列挙タスクが返らない間は「更新」を押しても二度と一覧を取り直せない。
            // 遅れて返ってきた古い結果は世代で捨てるので、取り違えは起きない
            self.enumerationInFlight = false
            if self.needsReload {
                self.needsReload = false
                self.reload()
            }
        }
    }

    private func apply(_ result: Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error>?,
                       generation: Int) {
        guard let result else {
            // 古い一覧を残したままタイムアウトのエラーを出すと、表示とエラーが食い違う
            displays = []
            windows = []
            loadError = String(localized: "画面/ウィンドウの列挙がタイムアウトしました。画面収録の権限確認が保留になっていないか確認し、再度更新してください")
            return
        }
        switch result {
        case .success(let snapshot):
            loadError = nil
            displays = snapshot.displays
            windows = snapshot.windows
                .filter { window in
                    // メニューバーの項目やツールチップのような小さいもの・自分自身は収録対象にしない
                    window.isOnScreen && window.bundleIdentifier != nil
                        && window.bundleIdentifier != Self.ownBundleID
                        && window.frame.width >= 120 && window.frame.height >= 80
                }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            // 選択中の対象が消えていたら (ウィンドウが閉じた、ディスプレイが外れた) ディスプレイ 0 に戻す
            switch request.target {
            case .window(let id) where !windows.contains(where: { $0.windowID == id }):
                request.target = .display(index: 0)
            case .display(let index) where !displays.indices.contains(index):
                request.target = .display(index: 0)
            default:
                break
            }
            // 新しい一覧に古い画像を残さない (windowID は再利用されるので、別のウィンドウの
            // 見た目で選んでしまう)。取得できるまでプレースホルダを出す
            thumbnails = [:]
            loadThumbnails(generation: generation)
        case .failure(let error):
            // 画面収録の権限が無いとここに来る (オンボーディングは issue #19)
            displays = []
            windows = []
            loadError = String(localized: "画面/ウィンドウの列挙に失敗しました (画面収録の権限を確認してください): \(error)")
        }
    }

    private func loadThumbnails(generation: Int) {
        let ids = windows.prefix(Self.thumbnailLimit).map(\.windowID)
        Task.detached {
            let images = await DisplayCatalog.windowThumbnails(windowIDs: ids)
            let converted = images.mapValues { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run { [weak self] in
                // 短い間隔で更新すると古い取得が後から終わることがある。今の一覧に
                // 古い画像を貼ると、見た目で別のウィンドウを選んでしまうので捨てる
                guard let self, generation == self.generation else { return }
                self.thumbnails = converted
            }
        }
    }

    /// タスクの完了とタイムアウトの先着を返す (タイムアウトなら nil)。
    /// withTaskGroup はスコープを抜けるときに全子タスクの完了を待つので、止められない列挙の
    /// await を子に置くとタイムアウト後も戻らない。そのためポーリングで先着を拾う
    private static func value<T>(of task: Task<T, Never>, timeout: TimeInterval) async -> T? {
        let box = ResultBox<T>()
        let watcher = Task { box.store(await task.value) }
        defer { watcher.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = box.load() { return value }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return box.load()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?

        func store(_ newValue: T) {
            lock.lock(); defer { lock.unlock() }
            if value == nil { value = newValue }
        }

        func load() -> T? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
