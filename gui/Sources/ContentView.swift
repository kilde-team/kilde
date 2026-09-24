import SwiftUI
import AppKit
import KildeCore

/// ポップオーバーの中身 (issue #18): 収録対象・音声ソース・トラック方針・保存先の選択と、
/// Rec / Stop・経過時間・ソース別レベルメーター。
/// 状態は AppDelegate が持つモデル (RecordingSetup / RecordingController) にあり、このビューは
/// 表示と操作の受け渡しだけ — ポップオーバーを閉じても録画は続く
struct ContentView: View {
    @ObservedObject var setup: RecordingSetup
    @ObservedObject var recording: RecordingController
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var updater: UpdaterCoordinator
    @ObservedObject var transcription: TranscriptionCoordinator
    /// 文字起こしの状態 (issue #146)。実体は AppDelegate が持つ — このビューは表示だけ

    private enum Mode: Hashable {
        case display, window, audioOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if recording.isActive {
                sessionView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 権限の案内はスクロール領域の**先頭**に置く。下に積むと、
                        // ウィンドウ一覧が長いときに固定高さ (600) のポップオーバーから
                        // はみ出して、肝心の案内が見えなくなる
                        permissionGuide
                        form
                        // 「最近の録画」もスクロール領域の中に入れる。外に置くと、
                        // 5 件並んだ通常の状態で開始ボタンが固定 600pt の外へ
                        // 押し出されて**録画を始められなくなる**
                        recentRecordings
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 420)
                resultView
                transcriptionStatusView
                startButton
            }
            if let notice = setup.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("終了") {
                    // 録画中なら AppDelegate.applicationShouldTerminate がファイナライズを待つ
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        // 録画中は選択肢を出さないので列挙しない (止められない SCK の列挙を録画と並走させない)
        .onAppear {
            // 権限は録画中でも取り直す (案内の表示だけで、SCK の列挙とは無関係)
            permissions.refresh()
            if !recording.isActive {
                setup.reload()
                setup.reloadRecentRecordings()
            }
        }
        // 録画が終わった瞬間に一覧を取り直す。ポップオーバーを開いたまま録画を終えると、
        // onAppear も kildePopoverDidShow も発火しないので、閉じて開き直すまで
        // 出来たばかりのファイルが «最近の録画» に出てこない
        .onChange(of: recording.phase) { _, newPhase in
            if case .finished = newPhase { setup.reloadRecentRecordings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kildePopoverDidShow)) { _ in
            // macOS 15 以降、画面収録権限は一度許可しても定期的に再確認されて失効しうる
            // (DESIGN.md F4)。開くたびに取り直して、失効していれば案内を出す
            permissions.refresh()
            // 録画中は選択肢を出さないので列挙しない (SCK の列挙を録画と並走させない)
            if !recording.isActive {
                setup.reload()
                // onAppear だけでは再表示を拾えない (この通知を足した理由そのもの)。
                // 閉じている間に終わった録画を一覧に出すため、ここでも取り直す
                setup.reloadRecentRecordings()
            }
        }
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("kilde")
                .font(.headline)
            Spacer()
            if !recording.isActive {
                if setup.loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    setup.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("ディスプレイ・ウィンドウ・入力デバイスの一覧を更新")
            }
        }
    }

    // MARK: - 選択フォーム

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("収録対象") {
                Picker("収録対象", selection: modeBinding) {
                    Text("画面").tag(Mode.display)
                    Text("ウィンドウ").tag(Mode.window)
                    Text("音声のみ").tag(Mode.audioOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 読み込み中は前回のエラーを隠す (再試行中に古い権限エラーが今の結果に見えてしまう)
                if !setup.loading, let error = setup.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch mode {
                case .display:
                    displayList
                case .window:
                    windowList
                case .audioOnly:
                    Text("映像は録らず、音声だけを M4A に保存します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            section("音声") {
                audioToggles
            }
            section("複数の音声ソース") {
                Picker("複数の音声ソース", selection: $setup.request.trackPolicy) {
                    Text("1 トラックに合成").tag(AudioTrackPolicy.mixed)
                    Text("ソースごとに分離").tag(AudioTrackPolicy.separate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(setup.request.audioSourceCount < 2)
            }
            section("文字起こし") {
                transcriptionSection
            }
            section("保存先") {
                outputRow
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
            // App Store ビルドには更新項目を出さない (issue #126)。MAS では配信が
            // App Store に一本化されるため「アップデートを確認」の手段自体が無い
#if !APPSTORE
            section("アップデート") {
                updateRow
            }
#endif
        }
    }

    /// 現在のバージョンと「アップデートを確認」ボタン (issue #122)。
    /// Sparkle 標準の更新ウィンドウが出る。録画中に適用した場合はファイナライズ完了後に
    /// 再起動する (UpdateInstallGate)
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
                // Sparkle の初期化が済むまで押せない (canCheckForUpdates が false)
                .disabled(!updater.canCheckForUpdates)
            }
            Text("録画中に更新を適用したときは、録画を停止してファイルの保存が終わってから再起動します")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// CFBundleShortVersionString と CFBundleVersion (Sparkle の sparkle:version と
    /// 同じ値) を並べて出す。ビルド番号はリリースごとに単調増加する。
    /// String として連結されるため SwiftUI の暗黙ローカライズが効かない — 明示的に解決する
    private var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(localized: "\(short) (build \(build))")
    }

    private var mode: Mode {
        switch setup.request.target {
        case .display: return .display
        case .window: return .window
        case .audioOnly: return .audioOnly
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .display:
                    setup.request.target = .display(index: 0)
                case .window:
                    // 面積が最大のウィンドウを仮選択する (一覧は面積の降順)
                    if let first = setup.windows.first {
                        setup.request.target = .window(id: first.windowID)
                    } else {
                        setup.notice = String(
                            localized: "収録できるウィンドウが見つかりません (更新ボタンで一覧を取り直せます)")
                    }
                case .audioOnly:
                    setup.request.target = .audioOnly
                }
            })
    }

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if setup.displays.isEmpty && !setup.loading {
                Text("ディスプレイが見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(setup.displays, id: \.displayID) { display in
                selectableRow(selected: setup.request.target == .display(index: display.index)) {
                    setup.request.target = .display(index: display.index)
                } content: {
                    Image(systemName: "display")
                    Text("ディスプレイ \(display.index)")
                    Spacer()
                    Text("\(display.width)×\(display.height)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if setup.windows.isEmpty && !setup.loading {
                Text("収録できるウィンドウが見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(setup.windows, id: \.windowID) { window in
                selectableRow(selected: setup.request.target == .window(id: window.windowID)) {
                    setup.request.target = .window(id: window.windowID)
                } content: {
                    thumbnail(for: window)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(windowTitle(window))
                            .lineLimit(1)
                        Text(window.bundleIdentifier ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func windowTitle(_ window: WindowInfo) -> String {
        if let title = window.title, !title.isEmpty { return title }
        return String(localized: "(タイトルなし)")
    }

    private func thumbnail(for window: WindowInfo) -> some View {
        Group {
            if let image = setup.thumbnails[window.windowID] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "macwindow").foregroundStyle(.secondary))
            }
        }
        .frame(width: 64, height: 40)
    }

    private var audioToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("システム音声 (相手の声・アプリの音)", isOn: $setup.request.captureSystemAudio)
            Toggle("マイク (既定の入力デバイス)", isOn: $setup.request.captureMic)
            ForEach(setup.inputDevices, id: \.uid) { device in
                Toggle(isOn: Binding(
                    get: { setup.isSelected(device: device) },
                    set: { setup.setSelected($0, device: device) })) {
                    Text(device.name)
                }
            }
            if case .window = setup.request.target, setup.request.captureSystemAudio {
                // ウィンドウ単位の収録では SCK がそのアプリの音声だけを渡す (SPIKE-NOTES F-B)
                Text("ウィンドウ収録ではシステム音声もそのアプリの音だけになります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "folder")
                Text((setup.request.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(setup.request.outputDirectory.path)
                Spacer()
                Button("変更…") {
                    setup.chooseOutputDirectory()
                }
            }
            Button("この音声・保存先の選択を既定にする") {
                setup.saveAsDefaults()
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("~/.kilde/config.json に保存します (CLI の kilde rec の既定値も変わります)")
        }
    }

    /// ホットキーの設定 (issue #20)。値は CLI と同じ `~/.kilde/config.json` の `hotkey` に入るので、
    /// ここで設定すると `kilde rec` も待機モードで起動するようになる (DESIGN.md の優先順位どおり)
    private var hotkeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "keyboard")
                TextField("例: cmd+shift+r", text: $setup.hotkeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyHotkey() }
                // 保存済みの値と同じでも押せるようにする — 設定ファイルへの保存が
                // 成功しても Carbon への登録が失敗する (他アプリとの競合) ことがあり、
                // そのとき draft == config なので無効にすると**再試行できなくなる**
                Button("適用") { applyHotkey() }
            }
            Text("他のアプリを使っている間でも、このキーで録画を開始・停止できます。空にすると無効になります")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 保存 → AppDelegate に再登録させる。登録の成否は notice に出る。
    ///
    /// 設定ファイルへ書くのと Carbon への登録は別物なので、**書けても登録に失敗しうる**。
    /// 保存に失敗したまま登録へ進むと、旧ホットキーの解除だけが行われて何も登録されない
    /// 状態になるため、**保存が成功したときだけ登録へ進む**。登録に失敗した場合は
    /// AppDelegate 側が設定を旧値へ巻き戻す (設定だけ新しい値が残ると、次回の起動で
    /// CLI も GUI も登録できない値を読むことになる)
    private func applyHotkey() {
        // 巻き戻し値は **保存直前にファイルにあった値** を使う。setup.config は GUI
        // 起動時のスナップショットなので、その間に CLI が変更していると上書きになる
        let (saved, previous) = setup.saveHotkey()
        guard saved else { return }
        // `NSApp.delegate` からは取れない — @NSApplicationDelegateAdaptor が
        // 挟むプロキシのせいで `as? AppDelegate` が nil になる (AppDelegate.shared のコメント)。
        // ここを NSApp.delegate にしていたため「適用」を押してもホットキーが
        // 再登録されず、設定だけ書き換わって無反応になっていた
        // .some(previous) を渡すことで «失敗したら巻き戻す» を明示する
        // (previous 自体が nil = 未設定だった場合も巻き戻しの対象)
        AppDelegate.shared?.applyHotkeyFromConfig(revert: .some(previous))
    }

    // MARK: - 文字起こし (issue #145)

    /// 「録画後に文字起こし」の設定。値は CLI と同じ `~/.kilde/config.json` の
    /// `transcribe` / `locale` / `transcriptFormat` に入るため、ここで変えると
    /// `kilde rec` の既定も変わる。変更は即座に保存する (ホットキーの「適用」のような
    /// 確定操作を挟まない — トグルと Picker の UI に確認ボタンを足すと操作が2段になるうえ、
    /// 「閉じたのに保存していない」状態を作ってしまう)。
    /// macOS 26 未満 (Transcriber.isSupported == false) では操作を無効化し、
    /// 理由を 1 行出すだけで構成を変えない — セクションごと隠すと、
    /// 機能の存在自体が分からなくなる (issue の受け入れ条件 [2] はどちらでもよい)
    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("録画後に文字起こし", isOn: transcribeBinding)
                .toggleStyle(.checkbox)
                // 非対応環境でも OFF への変更は許す — config.json の手編集等で
                // transcribe=true が残っている機械では、トグルが「チェック付き・無効」の
                // まま凍ると解除できず、理由文だけではなぜチェックが付いているか分からない
                .disabled(!setup.transcriptionAvailable && !setup.transcribeEnabled)
                // MAS 版の ConfigStore は SandboxSupport がコンテナ内へ退避させるため
                // ~/.kilde/config.json (CLI と共有) ではない — 「CLI の kilde rec にも
                // 効く」系の文言は MAS 版では誤りになるので分岐する
                #if APPSTORE
                .help("このアプリの設定に保存します (録画が終わると自動で文字起こしします)")
                #else
                .help("~/.kilde/config.json に保存します (CLI の kilde rec の既定値も変わります)")
                #endif
            if setup.transcriptionAvailable && setup.transcribeEnabled {
                Picker("言語", selection: transcriptLocaleBinding) {
                    Text("自動 (端末の言語設定)").tag(String?.none)
                    Text("日本語 (ja-JP)").tag(String?.some("ja-JP"))
                    Text("英語 (en-US)").tag(String?.some("en-US"))
                    // 手で編集した config.json に他の言語が入っているときは、
                    // 選択を壊さないようにその値も選択肢に出す
                    if let custom = setup.transcriptLocale,
                       custom != "ja-JP", custom != "en-US" {
                        Text(custom).tag(String?.some(custom))
                    }
                }
                Picker("出力形式", selection: transcriptFormatBinding) {
                    ForEach(TranscriptOutputFormat.allCases, id: \.self) { format in
                        Text(Self.formatLabel(format)).tag(format)
                    }
                }
                // 合成 1 トラックでは話者の区別が付かない。ソース数に関係なく案内を出す —
                // 1 ソース構成でもトラックが合成なら話者ラベルは付かず、足すべき選択
                // (「複数の音声ソース」+「ソースごとに分離」) は同じだから。既定値は変えない (issue の指定)
                if setup.request.trackPolicy != .separate {
                    Label("話者ラベルを付けるには「複数の音声ソース」で「ソースごとに分離」を選んでください",
                          systemImage: "person.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 録画が終わると自動で文字起こしが走る (issue #146)。進捗と中止は
                // パネルの transcriptionStatusView に出るので、ここでは繰り返さない。
                // MAS 版は ConfigStore がコンテナ内に退避されるため CLI にも適用の
                // 文言は誤りになる (#if で分岐)
                #if APPSTORE
                Text("録画が終わると自動で文字起こしします")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("録画が終わると自動で文字起こしします。設定は CLI (kilde rec) での録画にも適用されます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            if let reason = setup.transcriptionUnsupportedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Binding の set で保存まで行う。onChange で保存すると、保存失敗時の巻き戻しが
    /// 再び onChange を発火させて保存を再試行してしまう (値が戻った瞬間にもう一回走る)。
    /// set の中で直接呼べば巻き戻しは表示の更新だけで済む
    private var transcribeBinding: Binding<Bool> {
        Binding(
            get: { setup.transcribeEnabled },
            set: {
                setup.transcribeEnabled = $0
                setup.saveTranscriptionSetting(.enable)
            })
    }

    private var transcriptLocaleBinding: Binding<String?> {
        Binding(
            get: { setup.transcriptLocale },
            set: {
                setup.transcriptLocale = $0
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

    /// 文字起こしの進捗・結果 (issue #146)。録画中 (sessionView) と待機中の
    /// **両方**に出す — «文字起こし中に次の録画» をすると、録画中の画面に
    /// 進捗と中止が無いと処理が見えなくなる。busy 中は進捗と中止、そうでなければ
    /// 直近の失敗 (再試行つき) / 完了を 1 件だけ出す
    @ViewBuilder
    private var transcriptionStatusView: some View {
        if transcription.isBusy {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(transcriptionRunLabel, systemImage: "waveform")
                        .font(.caption)
                    Spacer()
                    Button("中止") { transcription.cancelAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                transcriptionProgressBar
                if !transcription.queue.isEmpty {
                    Text("他に \(transcription.queue.count) 件待機中 — 順に処理します (録画は文字起こしを待ちません)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
        }
        if !transcription.isBusy {
            if let failure = transcription.lastFailure {
                VStack(alignment: .leading, spacing: 2) {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    // モデル取得の失敗 (オフライン) はネットワークが戻れば同じジョブの
                    // 再実行で成功する — 失敗を見せっぱなしにせず回復の入り口を出す
                    Button("再試行") { transcription.retryLastFailure() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if let completion = transcription.lastCompletion {
                HStack {
                    Label(completion.sidecarURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Finder で表示") {
                        RecordingNotifier.revealInFinder(completion.sidecarURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptionProgressBar: some View {
        switch transcription.runPhase {
        case .preparingModel(let progress):
            // モデルの総サイズが取れる前 (0) は不定長表示。進捗ポーリングは
            // 0.5 秒間隔で必ず正の値に進むので、0 のまま固まることはない
            if progress > 0 {
                ProgressView(value: progress)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        case .transcribing(let progress):
            ProgressView(value: progress)
        case nil:
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var transcriptionRunLabel: String {
        switch transcription.runPhase {
        case .preparingModel(let progress):
            return progress > 0
                ? String(localized: "言語モデルを取得中… \(Int(progress * 100))%")
                : String(localized: "言語モデルを準備中…")
        case .transcribing(let progress):
            return String(localized: "文字起こし中… \(Int(progress * 100))%")
        case nil:
            return String(localized: "文字起こしの準備中…")
        }
    }

    // MARK: - 開始・結果

    private var startButton: some View {
        Button {
            start()
        } label: {
            Label(mode == .audioOnly ? "録音開始" : "録画開始", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        // 開始可否の判定は RecordingSetup に集約してある — グローバルホットキー
        // (ボタンを経由しない開始経路) と条件がずれないようにするため。
        // 理由は startBlockReason のコメントを参照 (issue #20 / #70)
        .disabled(setup.startBlockReason(permissions: permissions) != nil)
        .help(setup.startBlockReason(permissions: permissions) ?? "")
    }

    private func start() {
        // 開始の直前に取り直す — ポップオーバーを開いたまま権限を取り消された場合や、
        // macOS 15 以降の定期再確認 (DESIGN.md F4) で失効した場合に、SCK のエラーではなく
        // 案内で止めるため
        permissions.refresh()
        if let reason = setup.startBlockReason(permissions: permissions) {
            setup.notice = reason
            return
        }
        do {
            let options = try setup.makeOptions()
            setup.notice = nil
            recording.start(options)
        } catch {
            setup.notice = String(localized: "開始できません: \(error)")
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch recording.phase {
        case .finished(let url):
            VStack(alignment: .leading, spacing: 2) {
                Label("保存しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                ForEach(recording.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            // **失敗時も warnings を出す (CodeRabbit の指摘。issue #107)。**
            // ファイナライズと `stopCapture()` が**両方**失敗すると、`Recorder` は
            // `cleanupWarnings` を積んでから `.failed` を出す。ここで `message` しか
            // 見せないと、**停止が replayd に届かなかったことが GUI では一切分からない** —
            // 画面収録インジケータが点いたままの理由も、次の録画が重なりうることも
            // 伝わらない。成功時 (`.finished`) と同じ形で並べる
            VStack(alignment: .leading, spacing: 2) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(recording.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        default:
            EmptyView()
        }
    }

    /// 直近の録画 (issue #20)。クリックで Finder に表示する。
    /// 保存先を走査して作るので、CLI で録ったファイルもここに出る。
    /// 行の右端には文字起こしのアクション (issue #147) を置く:
    /// サイドカーが有れば «開く»、無ければ «文字起こしする»
    @ViewBuilder
    private var recentRecordings: some View {
        if !setup.recentRecordings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("最近の録画")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(setup.recentRecordings) { item in
                    HStack(spacing: 6) {
                        Button {
                            RecordingNotifier.revealInFinder(item.url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "film")
                                    .foregroundStyle(.secondary)
                                Text(item.url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Finder で表示: \(item.url.path)")
                        recentTranscriptAction(item)
                    }
                }
            }
        }
    }

    /// «最近の録画» の 1 行の右端に置く文字起こしアクション (issue #147)。
    /// 本体クリック (Finder 表示) は issue #20 からの既存挙動なので変えず、
    /// ボタンを足すだけにする。«文字起こしする» は «現在の» 設定 (形式・言語) で
    /// 投入する — «録画したときの設定» ではない点が録画完了の自動投入と違う
    @ViewBuilder
    private func recentTranscriptAction(_ item: RecordingSetup.RecentRecording) -> some View {
        if let transcript = item.transcriptURL {
            Button {
                NSWorkspace.shared.open(transcript)
            } label: {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("文字起こしを開く: \(transcript.lastPathComponent)")
        } else {
            let busy = transcription.isQueuedOrRunning(item.url)
            Button {
                transcription.enqueue(TranscriptionCoordinator.Job(
                    recordingURL: item.url,
                    format: setup.transcriptFormat,
                    localeID: setup.transcriptLocale,
                    // 後から文字起こしする録画は録音長を持たないため nil (計測では長さ区分を送らない)。
                    // SelfTest の Job 生成と同じ扱い。
                    recordingDuration: nil))
            } label: {
                Image(systemName: "waveform")
                    .foregroundStyle(busy ? Color(nsColor: .disabledControlTextColor) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(busy
                  ? "この録画の文字起こしは実行中 (または待機中) です"
                  : "この録画を文字起こしする")
        }
    }

    // MARK: - 録画中

    private var sessionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                switch recording.phase {
                case .recording:
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(RecordingController.formatElapsed(recording.elapsed))
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: recording.outputBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                case .finalizing:
                    ProgressView()
                        .controlSize(.small)
                    Text("ファイルを仕上げています…")
                default:
                    ProgressView()
                        .controlSize(.small)
                    Text("準備中…")
                }
            }
            if let url = recording.outputURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !recording.peaks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recording.peaks.keys.sorted(), id: \.self) { label in
                        LevelMeter(label: sourceName(label), peak: recording.peaks[label] ?? 0)
                    }
                }
            }
            Button {
                recording.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            // 準備中の停止も受け付ける (Recorder は録画開始直後に停止要求を処理する)
            .disabled(recording.phase == .finalizing)
            // 文字起こし中に次の録画ができる (キューで順に処理される) ため、
            // 録画中の画面でも進捗と中止を見せる (issue #146)
            transcriptionStatusView
            Text("ポップオーバーを閉じても録画は続きます。経過時間はメニューバーに表示されます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Recorder のソースラベル (system / mic / dev:<名前>) を表示名にする
    private func sourceName(_ label: String) -> String {
        switch label {
        case "system": return String(localized: "システム音声")
        case "mic": return String(localized: "マイク")
        default: return label.hasPrefix("dev:") ? String(label.dropFirst("dev:".count)) : label
        }
    }

    // MARK: - 権限の案内

    /// 今の構成に足りない権限だけを案内する (issue #19)。
    /// 音声のみ + システム音声オフの録音に画面収録権限を求めない、のように
    /// 「要らない権限を要求しない」ことを優先する
    @ViewBuilder
    private var permissionGuide: some View {
        let missing = permissions.missing(for: setup.request)
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(missing, id: \.self) { requirement in
                    switch requirement {
                    case .screen: screenGuide
                    case .mic: micGuide
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        }
    }

    private var screenGuide: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("画面収録の権限がありません", systemImage: "lock.circle")
                .font(.caption)
                .foregroundStyle(.orange)
            // 許可しても、プロセスを再起動するまで CGPreflightScreenCaptureAccess() は false のまま。
            // 「許可したのに録画できない」と見えるので、要求後は再起動を明示する
            Text(permissions.didRequestScreen
                ? "システム設定で許可したら、kilde を終了して起動し直してください (許可は再起動後に反映されます)"
                : "システム設定 → プライバシーとセキュリティ → 画面とオーディオを収録 で kilde を許可してください")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("許可を求める") { permissions.requestScreen() }
                Button("システム設定を開く") { permissions.openScreenSettings() }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private var micGuide: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("マイクの権限がありません", systemImage: "mic.slash")
                .font(.caption)
                .foregroundStyle(.orange)
            if case .notDetermined = permissions.micStatus {
                Text("「許可する」を押すと確認ダイアログが出ます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("許可する") {
                    Task { await permissions.requestMic() }
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                // 拒否済みではダイアログが出ないので、システム設定へ誘導するしかない
                Text("システム設定 → プライバシーとセキュリティ → マイク で kilde を許可してください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("システム設定を開く") { permissions.openMicSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    // MARK: - 部品

    // タイトルは LocalizedStringKey で受け、Text() の評価時に言語に応じて解決する
    // (String で受けるとどの言語でも ja のキーがそのまま出てしまう)
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func selectableRow<Content: View>(
        selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                content()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
