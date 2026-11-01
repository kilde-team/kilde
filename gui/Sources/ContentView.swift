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
    /// 文字起こしの状態 (issue #146)。実体は AppDelegate が持つ — このビューは表示だけ
    @ObservedObject var transcription: TranscriptionCoordinator
    /// 会議の自動録画。«UI の設定» は SettingsPaneView へ移設したが、開くたびの
    /// カレンダー権限の取り直し (refreshCalendarStatus) と録画中の表示
    /// (activeMeeting) で使う — 実体は AppDelegate が持つ
    @ObservedObject var meetingAutoRecorder: MeetingAutoRecorder
    /// チップの商品取り寄せ (issue #171)。«アプリを応援» の UI は SettingsPaneView へ
    /// 移設したが、商品一覧はポップオーバーを開くたびに取りに行く (失敗時の再試行。
    /// Coordinator 側で二重取得は防がれる) — 実体は AppDelegate が持つ
    @ObservedObject var tips: TipCoordinator
    /// Pro (要約) の購入と権利 (issue #169 / #170)。実体は AppDelegate が持つ。
    /// MAS 版は StoreKit 2 の非消耗型 «kilde.pro»、直接配布版はスタブで常に
    /// ロック解除済み (Pro 直接販売 #172 は当面見送りのため無料開放)
    @ObservedObject var pro: ProCoordinator
    /// Pro 購入導線の開閉 (issue #170)。ロック行をクリックしたときだけ開く —
    /// ポップオーバー内にインラインで出す (NSPopover はシートを表示できない
    /// ため。チップと同じ «パネル内に導線を置く» 構成)
    @State private var showsProPurchase = false

    private enum Mode: Hashable {
        case display, window, audioOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if recording.isActive {
                sessionView
            } else {
                // ScrollViewReader はセルフテストの PANEL_PRO モード (購入導線の
                // スクリーンショット) で文字起こしセクションへスクロールするためだけに
                // 使う (kildeProPurchaseReveal のハンドラで scrollTo)
                ScrollViewReader { proxy in
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
                    // 中身の幅をパネル内幅 (380 - padding 12×2 - スクロールバー分 16) に固定する。
                    // 縦の ScrollView は子の理想幅がこれを超えると中身ごと横に広げて中央寄せし、
                    // 左右が切れる — 長い言語 (es 等) の文言でトグルがパネル外に出て操作できなくなった (issue #195)
                    .frame(width: 340, alignment: .leading)
                    // 右端はスクロールバー分を空ける。«スクロールバーを常に表示» の環境では
                    // バーが中身に重なり、右端の文字やボタンが隠れる
                    .padding(.trailing, 16)
                }
                // PANEL_PRO のセルフテスト時だけ高さを広げてフォーム全体 (購入導線込み) を
                // 1 画面に収める — スクリーンショットをスクロール操作なしで撮るため
                .frame(maxHeight: SelfTest.isPanelPro ? 1160 : 420)
                .onReceive(NotificationCenter.default.publisher(for: .kildeProPurchaseReveal)) { _ in
                    // セルフテストの PANEL モード (KILDE_GUI_SELFTEST_PANEL_PRO=1) からのみ
                    // 来る。審査用スクリーンショットのためにロック行の購入導線を開き、
                    // 見える位置までスクロールする (フォームは高さ 420 のスクロール領域に
                    // 入り切らないため — proxy がここでしか見えないのでこの位置)
                    guard !pro.isUnlocked else { return }
                    showsProPurchase = true
                    // レイアウトが済む前に scrollTo すると無視されるため、少し遅らせる
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        withAnimation {
                            proxy.scrollTo("summaryLockRow", anchor: .top)
                        }
                    }
                }
                }
                resultView
                transcriptionStatusView
                startButton
                noticeCopyRow
            }
            if let notice = setup.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                // 録画ライブラリ (issue #165)。録画は AppDelegate が持つので
                // 開閉も経由する (AppDelegate.shared — NSApp.delegate は別物)
                Button {
                    AppDelegate.shared?.openLibrary()
                } label: {
                    Label(String(localized: "ライブラリ"), systemImage: "books.vertical")
                }
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
                // チップの商品一覧 (issue #171)。取れていれば no-op、取れていなければ
                // この表示で取りに行く (失敗時は次回の表示で再試行)
                Task { await tips.loadProducts() }
                // Pro の権利と商品 (issue #169/#170)。未購入の間だけ StoreKit を
                // 確認する (ロック行の表示と購入導線の価格のため。購入済みなら
                // Transaction.updates のリスナーが返金を拾うので、ここでは触らない)
                Task { await refreshProIfLocked() }
            }
        }
        // 録画が終わった瞬間に一覧を取り直す。ポップオーバーを開いたまま録画を終えると、
        // onAppear も kildePopoverDidShow も発火しないので、閉じて開き直すまで
        // 出たばかりのファイルが «最近の録画» に出てこない
        .onChange(of: recording.phase) { _, newPhase in
            if case .finished = newPhase {
                setup.reloadRecentRecordings()
                // 録画中は loadProducts を飛ばしていたため、録画が終わった時点で
                // 商品を取り直す (録画中に開いたポップオーバーでも «アプリを応援»
                // が出るようにする — cubic レビュー指摘)
                Task { await tips.loadProducts() }
                // Pro の権利と商品も同じ理由で取り直す (cubic レビュー指摘) —
                // 録画終了までパネルを開いたままのときは onAppear /
                // kildePopoverDidShow がもう来ないため、購入導線が «読み込み中…» の
                // まま固まってしまう
                Task { await refreshProIfLocked() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kildePopoverDidShow)) { _ in
            // macOS 15 以降、画面収録権限は一度許可しても定期的に再確認されて失効しうる
            // (DESIGN.md F4)。開くたびに取り直して、失効していれば案内を出す
            permissions.refresh()
            // カレンダー権限 (issue #393) も開くたびに取り直す — EventKit は許可の変化を
            // 通知しないため、システム設定で許可した直後の再表示で案内を更新する
            // (子ビューの onAppear は初回しか走らない、この通知を足した理由と同じ)
            meetingAutoRecorder.refreshCalendarStatus()
            // 録画中は選択肢を出さないので列挙しない (SCK の列挙を録画と並走させない)
            if !recording.isActive {
                setup.reload()
                // onAppear だけでは再表示を拾えない (この通知を足した理由そのもの)。
                // 閉じている間に終わった録画を一覧に出すため、ここでも取り直す
                setup.reloadRecentRecordings()
                // チップの商品一覧 (issue #171)。初回取得に失敗したままだと再起動まで
                // «アプリを応援» が出ないため、再表示でも再試行する (既に取れていれば
                // loadProducts は no-op、二重取得は Coordinator 側で防ぐ)
                Task { await tips.loadProducts() }
                // Pro の権利 (issue #169/#170)。閉じている間に (別 Mac での購入など)
                // 権利が増えていることがあるので、未購入の間は開くたびに確認する
                Task { await refreshProIfLocked() }
                // Pro 未購入のロック行が買える状態で表示された = 購入ファネルの分母
                // (issue #456)。onAppear は NSHostingController の再利用で再表示に
                // 走らないため、ここ (開くたびに来る通知) で数える。Apple
                // Intelligence が使えない環境 (summaryAvailable が false) はロック行が
                // 表示されても購入できないので数えない (cubic レビュー指摘)。
                // 直接配布版は常にロック解除済みでこの条件に入らない
                if !pro.isUnlocked, setup.summaryAvailable {
                    UsageAnalytics.proUpsellView()
                }
            }
        }
    }

    /// Pro 未購入の間だけ権利と商品を (再) 取得する (issue #169/#170)。
    /// 購入済みなら何もしない — 権利が増える方向の変化はここで、減る方向 (返金) は
    /// Transaction.updates のリスナーが拾う
    private func refreshProIfLocked() async {
        guard !pro.isUnlocked else { return }
        await pro.refreshEntitlements()
        await pro.loadProduct()
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
            // 設定ウィンドウへの導線 (issue #478)。«1 回設定すればよい» 機能は
            // SettingsPaneView へ集約したため、パネルからはヘッダーの歯車で開く
            Button {
                AppDelegate.shared?.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("設定を開く")
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
            section("文字起こし") {
                transcriptionSection
            }
            section("保存先") {
                outputRow
            }
        }
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
                    // 仮選択は **面積が最大のウィンドウ** を明示的に選ぶ。一覧は録画対象に
                    // なりやすい順 (会議 → 動画 → その他、issue #429) に並び替えられて
                    // いるため、first を取ると並び替えに仮選択が引きずられて既存の挙動が
                    // 変わってしまう (cubic レビュー指摘)
                    if let largest = setup.windows.max(by: {
                        $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                    }) {
                        setup.request.target = .window(id: largest.windowID)
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
                        HStack(spacing: 4) {
                            Text(windowTitle(window))
                                .lineLimit(1)
                            // 一般的に録画対象になりやすいウィンドウのタグ (issue #429)。
                            // 並び替え (RecordingSetup.apply) と同じ WindowService の判定
                            if let tag = WindowService.classify(
                                bundleIdentifier: window.bundleIdentifier,
                                title: window.title).tag {
                                serviceTag(tag)
                            }
                        }
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

    /// 会議・動画のタグ (issue #429)。ウィンドウの数が多いときに録画対象になりやすい
    /// ウィンドウが一目で分かるようにする。色は区分の補助で、ラベルとセットで伝える
    /// (色だけでの区別にしない)
    private func serviceTag(_ tag: WindowService.Tag) -> some View {
        let color: Color = tag == .meeting ? .orange : .purple
        return Text(tag.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
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
            // Binding 経由にする — 直接 $request.captureSystemAudio を触ると
            // «オンのときアプリの音声を外す» 排他制御 (RecordingSetup.setSystemAudio) を
            // 踏めず、app + system の不正な組合せが作れてしまう
            Toggle("システム音声 (相手の声・アプリの音)", isOn: systemAudioBinding)
            Toggle("マイク (既定の入力デバイス)", isOn: $setup.request.captureMic)
            ForEach(setup.inputDevices, id: \.uid) { device in
                Toggle(isOn: Binding(
                    get: { setup.isSelected(device: device) },
                    set: { setup.setSelected($0, device: device) })) {
                    Text(device.name)
                }
            }
            // アプリの音声 (issue #364)。Audio Process Tap は macOS 15+ のため、
            // 14.x では UI ごと隠す (既有のトグル構成のまま — issue の受け入れ条件)
            if #available(macOS 15.0, *) {
                appAudioPicker
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

    /// システム音声トグルの Binding。排他制御はモデル側 (RecordingSetup.setSystemAudio) が
    /// 持つ — «UI で選んだ状態» をセルフテスト (KILDE_GUI_SELFTEST_APP_AUDIO) が
    /// 同じメソッドで検証できるようにするため
    private var systemAudioBinding: Binding<Bool> {
        Binding(
            get: { setup.request.captureSystemAudio },
            set: { setup.setSystemAudio($0) })
    }

    /// «アプリの音声» ピッカー (issue #364)。実行中のアプリをアイコン付きのメニューで
    /// 出し、選択は bundleID で保持する (RecordRequest.appSources — エンジンの解決が
    /// bundleID 完全一致のため)。
    ///
    /// メニューにした理由: 実行中のアプリは数十件になりうるので、入力デバイスのように
    /// トグルを並べるとパネルが縦に伸びる。Menu は折りたたまれ、アプリ数が多くても
    /// パネルの他の項目を押し出さない
    @available(macOS 15.0, *)
    private var appAudioPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(setup.runningApps) { app in
                    appAudioMenuItem(
                        title: app.name,
                        icon: app.icon,
                        selected: setup.hasSelectedSource(resolvingTo: app),
                        noteUnrunning: false,
                        action: { setup.setAppSource(
                            !setup.hasSelectedSource(resolvingTo: app),
                            spec: app.bundleID) })
                }
                // 復元した選択のうち、そのアプリが終わっていたもの。**選択を見せる** —
                // 一覧から消えるだけだと «前回選んだ音声が何か» が分からず外せない。
                // このまま録画を始めるとエンジンが «実行中に見つかりません» で失敗する
                // (黙って system に縮退しない — issue の受け入れ条件)。失敗の案内は
                // 録画開始時の通知とパネルの失敗表示にエンジンのエラーメッセージがそのまま載る
                ForEach(setup.unrunningSelectedAppSources, id: \.self) { spec in
                    appAudioMenuItem(
                        title: spec,
                        icon: nil,
                        selected: true,
                        noteUnrunning: true,
                        action: { setup.setAppSource(false, spec: spec) })
                }
                if setup.runningApps.isEmpty && setup.unrunningSelectedAppSources.isEmpty {
                    Button(String(localized: "実行中のアプリがありません")) {}
                        .disabled(true)
                }
            } label: {
                // «app» は SF Symbols 2 (macOS 11+) — deployment target 14 で確実にある
                Label(appAudioMenuTitle, systemImage: "app.fill")
            }
            // 排他の案内。**アプリを選んでいるときだけ出す** — «選んだら system が外れた»
            // の直後に理由が目に入る位置で、選んでいないときの常設行を増やさない
            // (es 等の長い訳でパネルを押し広げた前例 — issue #195 — があるため)
            if !setup.request.appSources.isEmpty {
                Text("アプリの音声とシステム音声は同時に収録できません (マイクとは併用できます)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(setup.unrunningSelectedAppSources, id: \.self) { spec in
                Text("アプリ \"\(spec)\" は実行中ではありません (起動してから録画を開始してください)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ピッカーのラベル。未選択は案内語、1 件はアプリ名、複数は件数
    @available(macOS 15.0, *)
    private var appAudioMenuTitle: String {
        switch setup.request.appSources.count {
        case 0: return String(localized: "アプリの音声を選ぶ…")
        case 1: return appNameOrSpec(setup.request.appSources[0])
        default: return String(localized: "\(setup.request.appSources.count) 個のアプリの音声")
        }
    }

    /// bundleID の表示名。実行中のアプリ一覧で見つかればそのアプリ名、
    /// 見つからなければ spec のまま (手編集 config の値や終了済みアプリ)
    private func appNameOrSpec(_ spec: String) -> String {
        setup.runningApps.first {
            $0.bundleID.caseInsensitiveCompare(spec) == .orderedSame
        }?.name ?? spec
    }

    /// メニューの 1 項目。チェックマークはシステムのメニュー規約に合わせて先頭に置き、
    /// 未選択の行も位置を揃えるため透明化せず opacity で残す。
    /// «実行中でない» の接尾辞は String として連結する (Text 同士の + だと
    /// 列の間に spacing が入ってアプリ名と離れて見える)。
    /// 選択表示と切替は呼び出し側で決める — «実行中アプリ» の項目は
    /// `hasSelectedSource(resolvingTo:)` (名前指定の復元値も選択中と見なす)、
    /// «実行中でない» の項目は常に選択中 (選ぶと外れる)
    @available(macOS 15.0, *)
    private func appAudioMenuItem(title: String, icon: NSImage?, selected: Bool,
                                  noteUnrunning: Bool, action: @escaping () -> Void) -> some View {
        let displayTitle = noteUnrunning
            ? title + " " + String(localized: "(実行中でない)")
            : title
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .opacity(selected ? 1 : 0)
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    // アイコンの取れないプロセス (実行中でない復元値など) の位置合わせ
                    Image(systemName: "app.dashed")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                }
                Text(displayTitle)
                    .lineLimit(1)
            }
        }
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
                // 言語・出力形式・テンプレート・カスタム指示・書き出し先の詳細は
                // Settings ウィンドウへ移設した (issue #478 — GA4 の分析では
                // «録画 → 文字起こし» が利用の中心で、詳細は 1 回設定すればよい項目)
                // 要約 (issue #163)。トグルと Pro ロック行はパネルに残す —
                // 0.26.0 (10-27) リリースで分析窓 (10/2〜31) をほぼカバーしておらず
                // «0 ユーザー» は未使用の証拠にならないため。次回月次で再判定する
                if pro.isUnlocked {
                    Toggle("録画後に要約も作る", isOn: summaryBinding)
                        .toggleStyle(.checkbox)
                        .disabled(!setup.summaryAvailable)
                        .help("文字起こしの後に、会議の要点・決定事項・アクションを生成して Markdown の先頭に載せます (オンデバイス処理。Apple Intelligence を使用)")
                } else {
                    summaryLockRow
                        .id("summaryLockRow")
                    // カスタム指示 (issue #472) のロック行。同じ購入導線 (proPurchasePanel)
                    // を開く — Pro は買い切り 1 商品で全機能のライセンスのため
                    composerInstructionsLockRow
                        .id("composerInstructionsLockRow")
                    if showsProPurchase {
                        proPurchasePanel
                    }
                }
                if let reason = setup.summaryUnsupportedReason, setup.transcribeEnabled {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("要約には Apple Intelligence が必要です: \(reason)")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // 議事録の書き出し先 (issue #164)。文字起こしが有効なときだけ出す
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

    /// 要約 (issue #163) の Binding。保存先は UserDefaults (RecordingSetup の didSet が
    /// 扱う) なので config.json 系の Binding のような巻き戻しは不要
    private var summaryBinding: Binding<Bool> {
        Binding(
            get: { setup.summaryEnabled },
            set: { setup.summaryEnabled = $0 })
    }

    /// 要約のロック行 (issue #170)。MAS 版で Pro 未購入のとき、トグルの代わりに
    /// 表示する。クリックで購入導線 (proPurchasePanel) を開閉する
    private var summaryLockRow: some View {
        Button {
            withAnimation {
                showsProPurchase.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("録画後に要約も作る")
                Spacer()
                Text("Pro")
                    .font(.caption2)
                    .bold()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Apple Intelligence が使えない環境では導線を開かせない (買っても要約が
        // 動かないため)。理由は下の «要約には Apple Intelligence が必要です» 行が既に出す
        .disabled(!setup.summaryAvailable)
    }

    /// カスタム指示のロック行 (issue #472)。summaryLockRow と同じ構成 —
    /// クリックで proPurchasePanel を開く (表示位置は summaryLockRow の直下)
    private var composerInstructionsLockRow: some View {
        Button {
            withAnimation {
                showsProPurchase.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("要約とフォローアップのカスタム指示")
                Spacer()
                Text("Pro")
                    .font(.caption2)
                    .bold()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!setup.summaryAvailable)
    }

    /// Pro の購入導線 (issue #170)。ロック行の直下にインラインで開く。
    /// NSPopover の中ではシートを表示できないため、パネル内の導線にする
    /// (チップの «アプリを応援» と同じ構成)。購入が完了するとロック行ごと消える
    private var proPurchasePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会議の要約とフォローアップをアンロック")
                .font(.callout)
                .bold()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "sparkles")
                Text("録画のあと、要点・決定事項・アクションアイテムを自動でまとめ、参加者へ送るメッセージの下書きも作れます")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "lock.shield")
                Text("処理はすべて端末内で完結します。録画と文字起こしは無料のままです")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            if let item = pro.purchaseItem {
                Button {
                    Task { await pro.purchase() }
                } label: {
                    HStack(spacing: 6) {
                        if pro.isPurchasing || pro.isRestoring {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("購入 — \(item.price)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // 復元中も含めて実行中は押せない — AppStore.sync と購入の並行実行を
                // 防ぐ (cubic レビュー指摘)
                .disabled(pro.isPurchasing || pro.isRestoring)
            } else {
                // 商品が取れない間のプレースホルダ。失敗時は再表示で取り直す
                // (onAppear / kildePopoverDidShow — TipCoordinator と同じ)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("読み込み中…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button("購入を復元…") {
                Task { await pro.restore() }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            // 連打・購入との同時操作で AppStore.sync が並行しないように実行中は無効
            .disabled(pro.isPurchasing || pro.isRestoring)
            // 状態は 1 行だけ («控えめ» — チップと同じ)。キャンセルは何も出さない
            if pro.purchaseFailed {
                Text("購入を開始できませんでした。しばらくしてからもう一度お試しください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pro.restoreFailed {
                Text("この Apple ID では Pro の購入が見つかりませんでした")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("買い切りです。サブスクリプションではありません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05)))
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
            set: { value in
                // «自動» の値は大小無視で "auto" に正規化して保持する — 手編集の
                // config.json に "AUTO" 等が入っていても、ピッカーの選択行
                // (tag "auto") と一致し、実行時の判定 (Coordinator の lowercased
                // 比較) とも揃う
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
                    // 生のエラー (NSError) 由来のときだけ入る診断 (domain / code / userInfo —
                    // issue #221)。«切り分けに必要な情報» なので選択可能にして、
                    // バグ報告へそのまま貼れるようにする
                    if let detail = failure.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
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
        case .detectingLocale:
            // 判定は数秒で終わるので不定長表示 (kilde#409)
            ProgressView()
                .progressViewStyle(.linear)
        case .transcribing(let progress):
            ProgressView(value: progress)
        case .summarizing(let progress):
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
        case .detectingLocale:
            return String(localized: "言語を自動判定中…")
        case .transcribing(let progress):
            return String(localized: "文字起こし中… \(Int(progress * 100))%")
        case .summarizing(let progress):
            return String(localized: "要約を生成中… \(Int(progress * 100))%")
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

    /// 録音の告知文をコピーするボタン (issue #166)。ボットが参加しない kilde では
    /// «録音されています» を相手に伝えるのが利用者の役割 — 会議のチャットに
    /// 貼る想定で、ワンクリックでクリップボードへ出す
    @ViewBuilder
    private var noticeCopyRow: some View {
        Button {
            if setup.copyNoticeToClipboard() {
                noticeCopied = true
                // 2 秒で «コピーしました» を «告知文をコピー» に戻す
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    noticeCopied = false
                }
            }
        } label: {
            Label(noticeCopied ? "コピーしました" : "録音の告知文をコピー",
                  systemImage: noticeCopied ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("会議のチャットに貼れる録音の告知文をクリップボードにコピーします")
    }

    /// «コピーしました» 表示のフラグ (2 秒で戻る)
    @State private var noticeCopied = false

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
            // パネルの選択を次回起動時の初期選択として保存する (issue #345)。
            // «実際に使った構成が次回の既定になる» の意味論。保存に失敗しても
            // 録画開始は止めない (persistSessionDefaults のコメント)
            setup.persistSessionDefaults()
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
                // 保存フォルダを開く導線 (issue #296)。録画が終わったら«すぐに再生»へ
                // 至れるようにする。開き先は «最近の録画»・通知クリックと同じ
                // revealInFinder — フォルダ内でファイルを選択した状態で開くので、
                // ダブルクリックでそのまま再生できる。ファイルが消えていたら親
                // ディレクトリを開くフォールバックも共通
                Button("フォルダを開く") {
                    RecordingNotifier.revealInFinder(url)
                }
                .buttonStyle(.link)
                .font(.caption)
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
    /// 行の右端にはフォルダを開くボタン (issue #296) と文字起こしのアクション
    /// (issue #147) を置く: サイドカーが有れば «開く»、無ければ «文字起こしする»
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
                        // 保存フォルダを開くボタン (issue #296)。行本体のクリックが
                        // Finder 表示だと気づきにくいので、«押せる導線» として見える
                        // 形にする。開き先は行クリックと同じ revealInFinder
                        Button {
                            RecordingNotifier.revealInFinder(item.url)
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("フォルダを開く")
                        // アイコンのみのボタンなので VoiceOver 用のラベルが要る
                        // (.help はツールチップであってアクセシビリティラベルではない)
                        .accessibilityLabel("フォルダを開く")
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
            // «後から文字起こしする» は «現在の» 設定で投入する (録画完了の自動投入と
            // 違い、そのときの setup を読む)。要約トグルがオンなら要約付き (.md) で走る。
            // Pro の権利はここで見ない (録画完了のスナップショットと同じ理由 — 権利の
            // 組み立て中・購入直後にテンプレートを失わないよう、判定は実行時の
            // ゲートに一任する — cubic レビュー指摘)
            let summaryTemplate: MeetingTemplate? =
                setup.summaryEnabled && setup.summaryAvailable
                    ? setup.summaryTemplate : nil
            // カスタム指示 (issue #472)。要約を生成する経路なので、録画完了時と
            // 同じ条件 (summaryEnabled && summaryAvailable) で写像を運ぶ。権利の
            // 判定は実行時ゲート (coordinator の pre-check) に一任する
            let summaryInstructions: ComposerInstructions? =
                setup.summaryEnabled && setup.summaryAvailable
                    ? setup.composerInstructions : nil
            Button {
                transcription.enqueue(TranscriptionCoordinator.Job(
                    recordingURL: item.url,
                    format: setup.transcriptFormat,
                    summaryTemplate: summaryTemplate,
                    summaryInstructions: summaryInstructions,
                    localeID: setup.transcriptLocale,
                    // 後から文字起こしする録画は録音長を持たないため nil (計測では長さ区分を送らない)。
                    // SelfTest の Job 生成と同じ扱い。
                    recordingDuration: nil))
            } label: {
                Image(systemName: summaryTemplate != nil ? "waveform.badge.waveform" : "waveform")
                    .foregroundStyle(busy ? Color(nsColor: .disabledControlTextColor) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(busy
                  ? "この録画の文字起こしは実行中 (または待機中) です"
                  : summaryTemplate != nil
                  ? "この録画を文字起こしして要約も生成する (出力は .md)"
                  : "この録画を文字起こしする")
        }
    }

    // MARK: - 録画中

    private var sessionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                switch recording.phase {
                case .recording, .paused:
                    Circle()
                        .fill(recording.isPaused ? .orange : .red)
                        .frame(width: 10, height: 10)
                    if recording.isPaused {
                        Text("一時停止中")
                            .foregroundStyle(.orange)
                    }
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
            // 自動録画なら何を録っているかを出す (本人の操作なしに始まった録画なので、
            // 何が録られているかをパネルで確かめられるようにする)
            if let meeting = meetingAutoRecorder.activeMeeting {
                VStack(alignment: .leading, spacing: 2) {
                    Label("会議を自動録画中: \(meeting.appName)", systemImage: "person.2.wave.2")
                        .font(.caption)
                    if !meeting.title.isEmpty {
                        Text(meeting.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("会議ウィンドウを閉じると自動で停止します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                recording.togglePause()
            } label: {
                Label(recording.isPaused ? "再開" : "一時停止",
                      systemImage: recording.isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(recording.phase != .recording && recording.phase != .paused)
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
