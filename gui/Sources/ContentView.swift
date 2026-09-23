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
    /// 保存先を走査して作るので、CLI で録ったファイルもここに出る
    @ViewBuilder
    private var recentRecordings: some View {
        if !setup.recentRecordings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("最近の録画")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(setup.recentRecordings, id: \.self) { url in
                    Button {
                        RecordingNotifier.revealInFinder(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Finder で表示: \(url.path)")
                }
            }
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
