import SwiftUI
import AppKit
import KildeCore

/// 設定ウィンドウの中身 (issue #478)。パネル (ContentView) を Tailscale 風に
/// «日常操作» に絞り込んだため、**«1 回設定すればよい» 機能をここへ集約する** —
/// ホットキー・ログイン時起動・会議の自動録画・告知文・テレメトリ・更新・応援、
/// ならびに文字起こしの詳細 (言語・形式・要約テンプレート・カスタム指示・書き出し先)。
///
/// 状態は AppDelegate が持つモデル (ContentView と同じインスタンス) にあり、
/// このビューは表示と操作の受け渡しだけ。ウィンドウ自体は AppDelegate.openSettings()
/// が管理する (閉じても設定は保存済み — 即時保存の契約は各設定の実装と同じ)。
///
/// 選定の根拠 (issue #478): GA4 は録画・文字起こし・要約系しか計測しておらず
/// (PRIVACY.md «kilde コマンドラインは解析を行いません» の方針)、未計測セクションの
/// 多くは «1 回設定したら変えない» 性質のものである。GA4 で計測済みの機能のうち
/// «録画の直前に変えるもの» (収録対象・音声ソース・保存先・文字起こし / 要約の
/// トグル) はパネルに残す — 依頼者指示 «日常的に使う録画ボタンなどは残し»。
struct SettingsPaneView: View {
    @ObservedObject var setup: RecordingSetup
    @ObservedObject var meetingAutoRecorder: MeetingAutoRecorder
    /// チップの購入 (issue #171)。MAS 版のみ商品が出る (直接配布版はスタブで空 = 非表示)
    @ObservedObject var tips: TipCoordinator
    /// Pro の権利。カスタム指示の入力欄のロック判定で使う
    @ObservedObject var pro: ProCoordinator
    /// 自動更新 (直接配布版のみ。MAS 版はスタブ — CLAUDE.md §5-15)
    @ObservedObject var updater: UpdaterCoordinator

    /// 利用統計・クラッシュレポートの送信設定 (issue #435)。ContentView から移設。
    /// 正本は UserDefaults (TelemetryPreferences) で、この @State は表示を追従させる写し
    @State private var telemetryEnabled = TelemetryPreferences.isEnabled()
    /// カスタム指示セクション (issue #472) の開閉。ContentView から移設。
    /// 設定値自体は UserDefaults が正本なので開閉状態の保存はしない
    @State private var showsComposerInstructions = false
    /// SpeechTranscriber の対応ロケールの一覧 (issue #486)。固定の ja-JP / en-US だと
    /// 端末言語が対応外の利用者に対応言語を選ぶ導線が無かった (GA4 unsupported_locale
    /// — #478 コメント)。取り寄せはローカル照会で、Settings を開いたときの 1 回だけ
    @StateObject private var localeCatalog = TranscriptionLocaleCatalog()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("録音") {
                    // 複数の音声ソース (issue #478 でパネルから移設)。録画の直前に
                    // 変えるものではない (構成の好み) — 上級設定として Settings 扱い
                    Picker("複数の音声ソース", selection: $setup.request.trackPolicy) {
                        Text("1 トラックに合成").tag(AudioTrackPolicy.mixed)
                        Text("ソースごとに分離").tag(AudioTrackPolicy.separate)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(setup.request.audioSourceCount < 2)
                    Text("ソースごとに分離すると、システム音声・マイク・入力デバイスが別トラックで保存されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                section("文字起こしの詳細") {
                    transcriptionDetails
                }
                section("グローバルホットキー") {
                    hotkeyRow
                }
                section("起動") {
                    Toggle("ログイン時に kilde を起動する", isOn: Binding(
                        get: { setup.launchesAtLogin },
                        set: { setup.setLaunchesAtLogin($0) }))
                        .toggleStyle(.checkbox)
                }
                section("会議の自動録画") {
                    meetingAutoRecordSection
                }
                section("録音の告知文") {
                    noticeSection
                }
                section("プライバシー") {
                    privacySection
                }
                // App Store ビルドには更新項目を出さない (issue #126)
#if !APPSTORE
                section("アップデート") {
                    updateRow
                }
#endif
                // チップ (issue #171)。«控えめに置く» 方針は維持 — パネル最下部から
                // Settings へ移しただけで、目立たせ方は変えない
#if APPSTORE
                if !tips.isUnavailable {
                    section("アプリを応援") {
                        tipSection
                    }
                }
#else
                section("アプリを応援") {
                    sponsorsSection
                }
#endif
                if let notice = setup.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // パネルと同じ幅の根拠 (ContentView の frame コメント): 縦 ScrollView の
            // 子の理想幅を固定しないと横に広がって左右が切れる
            .frame(width: 340, alignment: .leading)
            .padding(.trailing, 16)
        }
        .padding(12)
        // チップの商品一覧 (issue #171)。録画中に Settings を開くとパネル側の
        // 取り寄せが走らない (cubic レビュー指摘) ので、ここでも取りに行く
        // (loadProducts は二重取得を Coordinator 側で防ぐ)
        .onAppear {
            Task { await tips.loadProducts() }
            // 対応ロケールの一覧も表示時に取り寄せる (issue #486 — refresh は
            // 毎回呼んでよい。2 回目以降は installed フラグの再取得になる)
            localeCatalog.refresh()
            // カレンダー権限 (issue #393) も表示時に取り直す — «システム設定で
            // 許可する…» ボタンで許可して戻った直後に案内を更新するため
            // (EventKit は権限の変化を通知しない)
            meetingAutoRecorder.refreshCalendarStatus()
        }
        // システム設定から戻った (アプリが active になった) ときも取り直す
        // (保持された NSHostingView は onAppear を再実行しないため)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            meetingAutoRecorder.refreshCalendarStatus()
            // 対応ロケールも取り直す — 設定を開いたまま文字起こしが走ってモデルを
            // 取得したあとに «未取得» が残るのを防ぐ (issue #486 — cubic レビュー指摘)
            localeCatalog.refresh()
        }
    }

    // MARK: - 文字起こしの詳細 (パネルのトグルは ContentView に残す)

    /// パネルの «文字起こし» トグルの下にあった詳細設定 (issue #478 で移設)。
    /// 表示条件は移設前と同じ — トグルがオンのときだけ編集に意味がある項目は
    /// 同じ条件で出す。カスタム指示だけは «ライブラリ経路にも効く» ため
    /// transcribeEnabled に依らず出す (ContentView で確定した条件を踏襲)
    private var transcriptionDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if setup.transcriptionAvailable && setup.transcribeEnabled {
                Picker("言語", selection: localeSelection) {
                    // «端末の言語設定» が SpeechTranscriber 非対応のときはラベルで示す
                    // (issue #486)。実行時は録音からの判定にフォールバックする
                    // (TranscriptionCoordinator) — その挙動は下の警告文で案内する
                    Text(localeCatalog.deviceLocaleSupported
                         ? "端末の言語設定"
                         : "端末の言語設定 (非対応 — 録音から判定)")
                        .tag(String?.none)
                    // 録音の冒頭から言語を自動判定 (kilde#409)。判定不能のトラックは
                    // 端末の言語設定にフォールバックする (kilde-cli-swift#131)
                    Text("自動 (録音から判定)").tag(String?.some("auto"))
                    // SpeechTranscriber の対応ロケールを実環境から出す (issue #486)。
                    // 固定の ja-JP / en-US だと、端末言語が対応外の利用者に対応言語を
                    // 選ぶ導線が無かった。未取得の言語は文字起こし実行時にモデルの
                    // 取得が走る (TranscriptionCoordinator) ので «未取得» を併記する
                    ForEach(localeCatalog.entries) { entry in
                        Text(entry.installed ? entry.label : entry.label + " (未取得)")
                            .tag(String?.some(entry.id))
                    }
                    // 手で編集した config.json に他の言語が入っているときは、
                    // 選択を壊さないようにその値も選択肢に出す (動的一覧に正規化のうえ
                    // 重複しないときだけ — «自動» は上の固定枠があるため出さない)
                    if let custom = setup.transcriptLocale,
                       custom.lowercased() != "auto",
                       !localeCatalog.containsNormalized(custom) {
                        Text(custom).tag(String?.some(custom))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 明示言語の適用範囲の案内 (issue #486 — cubic レビュー指摘)。«自動» と
                // «端末の言語設定» はトラックごとに判定するが、明示言語は録音全体を
                // その言語で書く (エンジンの transcribeWithSpeakers にロケール列を渡さない
                // 経路)。«分離にしたのに話者ごとに言語が変わる» と期待すると裏切るため
                if let selected = setup.transcriptLocale,
                   selected.lowercased() != "auto" {
                    Text("言語を指定すると録音全体をその言語で文字起こしします。トラックごとに言語を判定するには「自動 (録音から判定)」を選んでください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 対応外の選択への警告 (issue #486)。表示のみで挙動は変えない —
                // «端末の言語設定» 非対応時の実行時フォールバックは
                // TranscriptionCoordinator が担う
                if let warning = localeCatalog.selectionWarning(for: setup.transcriptLocale) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Picker("出力形式", selection: transcriptFormatBinding) {
                    ForEach(TranscriptOutputFormat.allCases, id: \.self) { format in
                        Text(Self.formatLabel(format)).tag(format)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 合成 1 トラックでは話者の区別が付かない (移設前と同じ案内)。
                // Label は折り返さないため HStack に分ける (issue #195)
                if setup.request.trackPolicy != .separate {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "person.wave.2")
                        Text("話者ラベルを付けるには上の «録音» で «ソースごとに分離» を選んでください")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if pro.isUnlocked, setup.transcriptionAvailable && setup.summaryEnabled {
                    Picker("テンプレート", selection: summaryTemplateBinding) {
                        Text("汎用").tag(MeetingTemplate.standard)
                        Text("定例会議").tag(MeetingTemplate.recurring)
                        Text("商談").tag(MeetingTemplate.sales)
                        Text("面接").tag(MeetingTemplate.interview)
                        Text("1on1").tag(MeetingTemplate.oneOnOne)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "doc.text")
                        Text("要約をつけると出力は Markdown (.md) になります")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // カスタム指示 (issue #472)。summaryEnabled に依らず出す
                // («ライブラリ経路にも効く» — ContentView で確定した条件)
                // 議事録の書き出し先 (issue #164)
                if setup.transcriptionAvailable && setup.transcribeEnabled {
                    HStack(spacing: 6) {
                        Text("議事録の書き出し先")
                        Spacer()
                        Text(setup.exportDirectory.map { $0.lastPathComponent } ?? "なし")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("変更…") { setup.chooseExportDirectory() }
                        if setup.exportDirectory != nil {
                            Button("解除", role: .destructive) { setup.clearExportDirectory() }
                        }
                    }
                    Text("文字起こしした .md をこのフォルダにも書き出します (出力形式が Markdown のとき。要約も含まれます)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exportNotice = setup.exportNotice {
                    Text(exportNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // カスタム指示 (issue #472)。ライブラリの «議事録を作成» と
            // «フォローアップを下書き» にも効くため、transcribeEnabled に依らず出す
            // (cubic レビュー指摘 — ContentView で確定した条件と同じ)
            if pro.isUnlocked, setup.transcriptionAvailable {
                composerInstructionsSection
            }
            if let reason = setup.transcriptionUnsupportedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 移設したセクション (ロジックは ContentView から移動 — 挙動は不変)

    private var summaryTemplateBinding: Binding<MeetingTemplate> {
        Binding(
            get: { setup.summaryTemplate },
            set: { setup.summaryTemplate = $0 })
    }

    /// RecordingSetup の文字列プロパティへの双方向 Binding (カスタム指示の入力欄用)。
    /// 保存は didSet が担うため巻き戻しは不要
    private func setupBinding(
        _ keyPath: ReferenceWritableKeyPath<RecordingSetup, String>
    ) -> Binding<String> {
        Binding(
            get: { setup[keyPath: keyPath] },
            set: { setup[keyPath: keyPath] = $0 })
    }

    /// 言語 Picker の選択 Binding (issue #486)。動的一覧の tag はエンジンの正規化形
    /// (小文字、例 «ja-jp» — Transcriber.supportedLocales の戻り値) で、config.json の
    /// 保存値は大小任意 («ja-JP» の実績) がある。SwiftUI Picker の選択一致は tag の
    /// **完全一致**なので、正規化のうえ一致する tag へ写して表示する — 表示の写像だけ
    /// で、書くときは選ばれた tag の値をそのまま保存する (一致しない値を書き戻さない)。
    /// これがないと «既存の ja-JP 設定が未選択表示になる»
    private var localeSelection: Binding<String?> {
        Binding(
            get: {
                guard let value = setup.transcriptLocale else { return nil }
                if value.lowercased() == "auto" { return "auto" }
                let normalized = Transcriber.normalizedBCP47(value)
                if let matched = localeCatalog.entries.first(where: { $0.id == normalized }) {
                    return matched.id
                }
                // 動的一覧に無い値 (カスタム枠) は生値の tag と対応させる
                return value
            },
            set: { value in
                // «自動» の値は大小無視で "auto" に正規化して保持する (既存契約)
                setup.transcriptLocale = value?.lowercased() == "auto" ? "auto" : value
                setup.saveTranscriptionSetting(.locale)
            })
    }

    private var transcriptFormatBinding: Binding<TranscriptOutputFormat> {
        Binding(
            get: { setup.transcriptFormat },
            set: {
                setup.transcriptFormat = $0
                setup.saveTranscriptionSetting(.format)
            })
    }

    private static func formatLabel(_ format: TranscriptOutputFormat) -> String {
        switch format {
        case .markdown: return String(localized: "Markdown (.md)")
        case .srt: return String(localized: "SubRip 字幕 (.srt)")
        case .vtt: return String(localized: "WebVTT 字幕 (.vtt)")
        case .txt: return String(localized: "プレーンテキスト (.txt)")
        case .json: return String(localized: "JSON (.json)")
        }
    }

    /// カスタム指示の入力セクション (issue #472)。ContentView から移設 —
    /// 入力は生の文字列のまま RecordingSetup が UserDefaults に保存し、
    /// «実質空» 判定と正規化はエンジン側に一任する
    private var composerInstructionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $showsComposerInstructions) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("トーン")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("例: カジュアルに / 丁寧に", text: setupBinding(\.instructionsTone))
                        .textFieldStyle(.roundedBorder)
                    Text("宛先")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("例: 社内のチーム向け / 初めてお会いする相手", text: setupBinding(\.instructionsRecipients))
                        .textFieldStyle(.roundedBorder)
                    Text("署名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("例: 田中 (営業部)", text: setupBinding(\.instructionsSignature))
                        .textFieldStyle(.roundedBorder)
                    Text("強調してほしいポイント (1 行に 1 つ)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: setupBinding(\.instructionsExtraPoints))
                        .font(.caption)
                        .frame(minHeight: 40, maxHeight: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.15)))
                    Text("自由記述の指示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: setupBinding(\.instructionsFreeform))
                        .font(.caption)
                        .frame(minHeight: 40, maxHeight: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.15)))
                }
                .padding(.leading, 4)
            } label: {
                Text("カスタム指示")
                    .font(.caption)
                    .bold()
            }
            Text("要約とフォローアップの下書きに、ここで指定した内容が反映されます (処理は端末内で完結し、入力が外部に送られることはありません)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - グローバルホットキー (issue #20)

    private var hotkeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "keyboard")
                TextField("例: cmd+shift+r", text: $setup.hotkeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyHotkey() }
                // 保存済みの値と同じでも押せる (移設前と同じ理由 — 登録だけ失敗する
                // ことがあり、そのとき draft == config なので無効にすると再試行できない)
                Button("適用") { applyHotkey() }
            }
            Text("他のアプリを使っている間でも、このキーで録画を開始・停止できます。空にすると無効になります")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 保存 → AppDelegate に再登録させる (移設前と同じ契約 — 保存が成功したときだけ
    /// 登録へ進む。失敗時は AppDelegate 側が旧値へ巻き戻す)
    private func applyHotkey() {
        let (saved, previous) = setup.saveHotkey()
        guard saved else { return }
        AppDelegate.shared?.applyHotkeyFromConfig(revert: .some(previous))
    }

    // MARK: - 会議の自動録画 (issue #197 / #393)

    private var meetingAutoRecordSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("会議を検知したら会議ウィンドウを自動で録画する", isOn: $meetingAutoRecorder.enabled)
                .toggleStyle(.checkbox)
                .disabled(!meetingAutoRecorder.isSupported && !meetingAutoRecorder.enabled)
            if meetingAutoRecorder.isSupported {
                Text("Zoom・Google Meet・Teams・Slack ハドル・Webex でマイクが使われ始めたら、その会議ウィンドウだけをシステム音声とマイクで録画し、ウィンドウを閉じると停止します。録画の前に参加者の同意を得てください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                calendarTitleToggle
            } else {
                Text("この機能は macOS 14.2 以降で利用できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var calendarTitleToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("カレンダーの予定名を録画ファイル名に使う", isOn: $meetingAutoRecorder.usesCalendarTitles)
                .toggleStyle(.checkbox)
                .disabled(!meetingAutoRecorder.enabled && !meetingAutoRecorder.usesCalendarTitles)
            if meetingAutoRecorder.usesCalendarTitles {
                if meetingAutoRecorder.calendarStatus.canRead {
                    Text("検知した会議と時間帯が重なるカレンダーの予定があるとき、その予定名を録画ファイル名と議事録の見出しに使います。カレンダーの内容は端末内でだけ使われ、ネットワークには送信されません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if meetingAutoRecorder.calendarStatus == .notDetermined {
                    Text("カレンダーの予定名を使うには、表示されたダイアログでカレンダーへのアクセスを許可してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("カレンダーへのアクセスが許可されていないため、予定名は使われません (録画は通常どおり動きます)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("システム設定で許可する…") {
                        meetingAutoRecorder.openCalendarSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.leading, 8)
    }

    // MARK: - 録音の告知文 (issue #166)

    private var noticeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(
                get: { setup.effectiveNoticeText },
                set: { setup.customNoticeText = $0 }))
                .frame(minHeight: 60)
                .font(.body)
            HStack {
                Spacer()
                Button("既定に戻す") { setup.resetNoticeText() }
                    .disabled(setup.customNoticeText == nil)
                Button("コピー") { setup.copyNoticeToClipboard() }
            }
            Text("この文案は «録音の告知文をコピー» ボタンでも使われます。録音の同意は利用者の責任で取得してください")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - プライバシー (issue #435)

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("アプリの利用統計とクラッシュレポートを送信する", isOn: Binding(
                get: { telemetryEnabled },
                set: { setTelemetryEnabled($0) }))
                .toggleStyle(.checkbox)
            Text("アプリの改善に使う利用統計と、不具合修正に使うクラッシュレポートです。録画や文字起こしの内容・ファイル名は含まれません。オフにすると、利用統計はすぐに止まり、クラッシュレポートは次の起動から送られなくなります")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 保存してから Firebase へ反映する (順序は固定 — 先に保存しないと古い値で
    /// 反映される。移設前と同じ)
    private func setTelemetryEnabled(_ enabled: Bool) {
        telemetryEnabled = enabled
        TelemetryPreferences.setEnabled(enabled)
        AppDelegate.shared?.telemetryPreferenceDidChange()
    }

    // MARK: - アップデート (issue #122 / 直接配布版のみ)

    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.triangle.2.circle.circle")
                Text(currentVersion)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentVersion)
                Spacer()
                Button("アップデートを確認") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            Text("録画中に更新を適用したときは、録画を停止してファイルの保存が終わってから再起動します")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(localized: "\(short) (build \(build))")
    }

    // MARK: - アプリを応援 (issue #171)

#if APPSTORE
    private var tipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(tips.items) { item in
                    Button {
                        Task { await tips.purchase(item) }
                    } label: {
                        VStack(spacing: 1) {
                            Text(item.title)
                            Text(item.price)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(tips.isPurchasing)
                }
            }
            if tips.isPurchasing {
                ProgressView()
                    .controlSize(.small)
            } else if tips.lastPurchasedID != nil {
                Text("ありがとう!kilde の開発を応援しています")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if tips.purchaseFailed {
                Text("購入を開始できませんでした。しばらくしてからもう一度お試しください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
#else
    private var sponsorsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("開発の支援は GitHub Sponsors からも")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("GitHub Sponsors で応援") {
                    if let url = URL(string: Self.sponsorsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// FUNDING.yml と同じ行き先 (issue #171)
    private static let sponsorsURL = "https://github.com/sponsors/takezou621"
#endif

    // MARK: - 共通

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
