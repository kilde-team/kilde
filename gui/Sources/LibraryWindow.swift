import AppKit
import SwiftUI
import AVKit
import Combine
import KildeCore
import UniformTypeIdentifiers

/// ライブラリウィンドウが閉じたことを再生に知らせる。
/// ウィンドウを閉じても LibraryView と player は生き続ける (isReleasedWhenClosed=false) ため、
/// 閉じたら必ず pause する必要がある
extension Notification.Name {
    static let kildeLibraryWindowDidClose = Notification.Name("kildeLibraryWindowDidClose")
}

/// ライブラリから文字起こしを投入するときの «押した時点の» パネル設定のスナップショット
/// (issue #321)。AppDelegate がボタンが押された時点の RecordingSetup から作る —
/// パネルの «後から文字起こし» (issue #147) と同じ «現在の設定» の規約で、
/// «録画したときの設定» ではない。ライブラリ内に設定 UI は置かず、形式・言語・
/// テンプレートの選択は設定パネルで行う
struct LibraryTranscriptionSettings {
    let format: TranscriptOutputFormat
    /// nil は «端末の言語設定»
    let localeID: String?
    /// 現在選択されている要約テンプレート («議事録を作成» で使う)
    let summaryTemplate: MeetingTemplate
    /// カスタム指示 (issue #472 — 第三弾 Pro)。nil は «未指定» («実質空» も含む —
    /// RecordingSetup.composerInstructions の写像結果をそのまま運ぶ)。«議事録を
    /// 作成» の summarize と «フォローアップを下書き» の compose の双方に渡す。
    /// 権利の判定は呼び出し側 (followupBar の proAllows / 実行時ゲート) が持つ
    let summaryInstructions: ComposerInstructions?
    /// Apple Intelligence が使えない理由。nil は «使える» — «議事録を作成» の
    /// 可否判定と、押せないときの説明 (ツールチップ) に使う
    let summaryUnsupportedReason: String?
}

/// «指定した録画を選んだ状態で開く» をウィンドウ (と保持された rootView) へ
/// 届ける運び屋 (issue #502)。Spotlight の結果からのオープンが唯一の送り手。
/// 値は «消費したら nil に戻す» 契約 — 残していると次のオープンで
/// 古い選択が再適用される
@MainActor
final class LibraryRevealCoordinator: ObservableObject {
    @Published var pending: URL?
}

/// 録画ライブラリのウィンドウ (issue #165)。
/// このアプリは LSUIElement (.accessory) で動くため、普通のウィンドウを
/// orderFront しても Dock に出ず前面に来ない。ウィンドウを出している間だけ
/// .regular に切り替え、閉じたら .accessory に戻す — 切替はこのクラスに集約する
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {

    private let store: LibraryStore
    /// パネルと共有する文字起こしコーディネーター (issue #321)。enqueue と進捗の正本。
    /// ライブラリ専用のインスタンスを作ると «同じ録画の重複投入を捨てる»
    /// coordinator の guard と «録画パネルの表示» が効かなくなるため、必ず共有する
    private let transcription: TranscriptionCoordinator
    /// Pro の権利 (issue #169/#170)。«議事録を作成» のロック表示に使う。
    /// 変化 (別デバイスでの購入・返金) をライブラリの表示に反映するため
    /// ビューまで ObservedObject として渡す (cubic レビュー指摘)
    private let pro: ProCoordinator
    /// «議事録を作成» のときに押された時点のパネル設定を読む。クロージャが
    /// RecordingSetup だけを捕まえる (AppDelegate を捕まえない) ため、
    /// ライブラリウィンドウの寿命が AppDelegate と常に同じでも循環参照は作らない
    private let settings: () -> LibraryTranscriptionSettings
    /// «この URL は録画中の出力ファイルか» (issue #523)。録画中の録画はライブラリの
    /// 一覧にも現れる (走査がフォルダを見る) ため、削除導線の無効化と実行時の
    /// 再確認に使う — «録画中のファイルを消す» は «壊れたファイルを残す» の
    /// 逆で «生きている録画を壊す» になる (cubic レビュー指摘)。AppDelegate が
    /// RecordingController の進行状態と outputURL を見て答える
    private let isRecordingOutput: (URL) -> Bool
    /// Spotlight など «指定した録画を選んだ状態で開く» 経路の受け渡し (issue #502)。
    /// ウィンドウを持ち回る (閉じても破棄しない) ため、再オープン時に rootView は
    /// 再生成されない — 選択はこの ObservableObject をビューが購読することで
    /// «後から» 届く (初回生成の前に値が入っていても、$pending は購読開始時に
    /// 現在値を流すので初期選択もこの 1 本で済む)
    let reveal = LibraryRevealCoordinator()
    private var window: NSWindow?

    init(store: LibraryStore,
         transcription: TranscriptionCoordinator,
         pro: ProCoordinator,
         settings: @escaping () -> LibraryTranscriptionSettings,
         isRecordingOutput: @escaping (URL) -> Bool) {
        self.store = store
        self.transcription = transcription
        self.pro = pro
        self.settings = settings
        self.isRecordingOutput = isRecordingOutput
    }

    /// ウィンドウを開く (既に開いていれば前面に出す)。directory は保存先 —
    /// 開くたびに走査し直すので、録画や文字起こしの追加が次回のオープンで反映される。
    /// reveal は «この録画を選んだ状態で開く» (Spotlight の結果からのオープン、issue #502)。
    /// **reveal が現在の保存先に無いときは選択されない** (走査は現在の保存先が対象。
    /// 旧保存先の録画を Spotlight から開いた場合は詳細が空のまま — 限界は PR に明記する)
    func present(fromDirectory directory: URL, reveal recordingURL: URL? = nil) {
        store.reload(directory: directory)
        if let recordingURL {
            // 一覧が並ぶのを待たずに渡してよい — ビュー側は «entries に現れたら
            // 詳細が出る» (selectedEntryID は URL の tag で照合する) だけを見る
            self.reveal.pending = recordingURL
        }
        if let window {
            showAndActivate(window)
            return
        }
        // miniaturizable は付けない — 閉じたら .accessory に戻す設計のため、
        // Dock アイコンが無い状態で最小化すると戻り口が無くなる
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "録画ライブラリ")
        window.minSize = NSSize(width: 680, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: LibraryView(store: store, transcription: transcription, pro: pro,
                                  settings: settings, reveal: reveal,
                                  canTrashRecording: isRecordingOutput))
        self.window = window
        showAndActivate(window)
    }

    private func showAndActivate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // ライブラリを表示した (issue #343)。初回生成と既存ウィンドウの前面出しの
        // 両経路がここを通るので 1 箇所で計測できる。Firebase が無い構成
        // (セルフテスト・Debug) では UsageAnalytics 内で跳ねる
        UsageAnalytics.screenView(.library)
    }

    func windowWillClose(_ notification: Notification) {
        // ステータス項目のアプリ (.accessory) に戻す — .regular のままの
        // Dock アイコンが無い状態で最小化すると戻り口が無くなる
        NSApp.setActivationPolicy(.accessory)
        // 閉じた後は画面上に UI が残らないため «音だけ流れ続ける» 状態に気づけない。
        // player は LibraryView が持つので、通知経由で pause してもらう
        NotificationCenter.default.post(name: .kildeLibraryWindowDidClose, object: nil)
    }
}

// MARK: - 再生

/// 選択中の録画の再生を管理する。AVPlayer は 1 つを持ち回り、録画が変わったときだけ
/// AVPlayerItem を差し替える (毎回生成するとプレイヤーの状態が飛ぶ)
@MainActor
final class LibraryPlayerController: ObservableObject {
    let player = AVPlayer()
    private var currentURL: URL?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // ウィンドウを閉じたら再生を止める。閉じた後も本クラス (と player) は
        // 生き続けるため、放置すると «音だけ流れ続ける» 状態になる (LSUIElement のため見えない)
        NotificationCenter.default.publisher(for: .kildeLibraryWindowDidClose)
            .sink { [weak self] _ in self?.player.pause() }
            .store(in: &cancellables)
    }

    func prepare(url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    /// 選択中の録画がゴミ箱へ移されたときに呼ぶ (issue #523)。
    /// 削除後に AVPlayerItem が実ファイルを参照し続けると «消したのに
    /// 音だけ流れ続ける» — ウィンドウを閉じたときに pause する
    /// (init の通知購読) と同じ理由の、選択解除版
    func stopIfPlaying(url: URL) {
        guard currentURL == url else { return }
        currentURL = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// 文字起こしのセグメント開始時刻へ移動して再生する。
    /// セグメントの時刻は録画開始からの経過秒で、AVPlayerItem の時間軸と一致する
    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player.play()
    }
}

/// AVKit の AVPlayerView を SwiftUI に載せる。macOS には AVKit の SwiftUI
/// ビューが無いため NSViewRepresentable を書く
private struct LibraryPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

// MARK: - ビュー

/// ライブラリの中身。上に検索欄、左右に «録画一覧 | 詳細 (再生 + 文字起こし)»、
/// 下に件数のステータス。検索語があるときは文字起こしをヒットしたセグメントだけに
/// 絞り込み、セグメント行クリックで該当時刻へ飛ぶ。
/// 詳細ペインから «後から文字起こし・議事録を作成» できる (issue #321)
struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    /// パネルと共有する文字起こしコーディネーター (issue #321)。
    /// «後から文字起こし» の投入と進捗表示に使う — パネルと同じインスタンスを
    /// 見るため、パネルで投入されたジョブの進捗もこの一覧に出る
    @ObservedObject var transcription: TranscriptionCoordinator
    /// Pro の権利 (issue #169/#170)。«議事録を作成» のロック表示のため
    /// LibraryDetailView へ流す
    @ObservedObject var pro: ProCoordinator
    let settings: () -> LibraryTranscriptionSettings
    @State private var query = ""
    @State private var results: [LibrarySearchHit] = []
    @State private var hitCounts: [URL: Int] = [:]
    @State private var selectedEntryID: URL?
    @StateObject private var playback = LibraryPlayerController()
    /// 既存ファイルの取り込み (issue #416)。コピーの進捗と案内の表示元
    @StateObject private var importer = LibraryImportCoordinator()
    /// Spotlight からの «この録画を選んで開く» (issue #502)。コントローラが持ち、
    /// このビューが購読する — ウィンドウの再オープンでは rootView が再生成されない
    /// (LibraryWindowController.reveal のコメント) ための受け渡し
    @ObservedObject var reveal: LibraryRevealCoordinator
    /// «ゴミ箱に入れる» の確認ダイアログの対象 (issue #523)。nil は «出していない»
    @State private var deleteCandidate: LibraryEntry?
    @State private var showsDeleteConfirmation = false
    /// «ゴミ箱へ移す» の結果表示 (成功・失敗)。nil は «表示なし»。録画を
    /// 切り替えても消さない — «一覧は消えた» 状態で案内も消えると理由が読めない
    @State private var deleteNotice: String?
    /// ゴミ箱移動が 1 件進行中か (issue #523)。移動はバックグラウンド Task なので
    /// 押した直後に次の削除を始められる — «同じ stem の録画を続けて削除» すると
    /// «別録画の主張» の判定が移動前の一覧で行われ、共有サイドカーが
    /// 取り残る/二重に移る (cubic レビュー指摘)。進行中は **すべての削除導線を
    /// 無効化** して移動の収集から完了までを直列化する
    @State private var isDeletingTrash = false
    /// «名前を変更» のダイアログの対象 (issue #532)。nil は «出していない»
    @State private var renameCandidate: LibraryEntry?
    @State private var showsRenameDialog = false
    /// «名前を変更» の入力 («kilde-» 接頭辞ごと、拡張子なしの stem)。
    /// ダイアログを開くときに現在の名前で満たす — «今何という名前か» と
    /// «接頭辞が保たれる» を入力欄で確実にするため
    @State private var renameText = ""
    /// «名前を変更» の結果表示 (成功・失敗)。nil は «表示なし»。ゴミ箱移動の
    /// deleteNotice と分けているのは «整理の 2 導線» の結果が同時に並んでも
    /// 別の出来事として読めるようにするため (録画を切り替えても消さない —
    /// deleteNotice と同じ理由)
    @State private var renameNotice: String?
    /// リネームが 1 件進行中か (issue #532)。ゴミ箱移動と **直列化** する —
    /// «同じ stem の録画を移し終わっていない間にリネーム» すると、companionFiles の
    /// «別録画の主張» 判定が移動前の一覧で行われ、共有サイドカーの扱いが
    /// あいまいになる (isDeletingTrash が削除同士を直列化するのと同じ理由)。
    /// 進行中はリネームと削除の **両方** の導線を無効化する
    @State private var isRenaming = false
    /// «この URL は録画中の出力ファイルか» (issue #523)。録画中の録画は
    /// 一覧にも現れるので、削除導線の無効化と実行時の再確認に使う。
    /// LibraryWindowController が AppDelegate (RecordingController) から
    /// 受け取って流す。クロージャが RecordingController を捕まえても
    /// 循環参照は作らない (両方とも AppDelegate の持ち物)
    let canTrashRecording: (URL) -> Bool

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// «ライブラリに質問» のシート (issue #547) を出しているか
    @State private var showsLibraryQA = false
    /// 書き起こしを持つ録画が 1 件以上あるか («ライブラリに質問» の有効条件)。
    /// 判定は LibraryQASupport が担う («空白でない本文» を持つセグメントが
    /// あること — 空 cue だけの SRT / VTT を «文字起こし済み» としないため。
    /// 写像 (recordings) と判定を共有する)
    private var hasTranscribedRecording: Bool {
        store.entries.contains { LibraryQASupport.hasNonEmptySegments($0) }
    }

    /// «名前を変更» ダイアログのタイトル。対象のファイル名を載せる —
    /// «どの録画の名前を変えているか» をダイアログだけでも確実にする
    /// (body の式が重くならないよう、式のまま渡さず事前計算の let を使う)
    private var renameDialogTitle: String {
        renameCandidate.map {
            String(localized: "\($0.recordingURL.lastPathComponent) の名前を変更")
        } ?? String(localized: "名前を変更")
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(8)
            Divider()
            HSplitView {
                listPane
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                detailPane
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 680, minHeight: 440)
        // 既存の音声・動画ファイルのドロップ (issue #416)。許容する型に
        // UTType.fileURL を含める — Finder などは concrete な型 (public.mpeg-4-audio 等)
        // を登録せず public.file-url だけを提供することがあり、audio / movie だけを
        // 受け付けると onDrop 自体が呼ばれないため (cubic 指摘)。対応外の拡張子は
        // importFiles がステータス行に案内する
        .onDrop(of: [UTType.fileURL, UTType.audio, UTType.movie], isTargeted: nil) { providers in
            // 設定と保存先の bookmark の固定はドロップの受け付け時点 (startImport と同じ規約)
            let snapshot = settings()
            let bookmark = store.directory.flatMap {
                TranscriptionCoordinator.directoryBookmarkData(forDirectory: $0)
            }
            return importer.handleDrop(
                providers, into: store.directory,
                onImported: { enqueueImported($0, snapshot: snapshot, directoryBookmark: bookmark) },
                onComplete: { finishImport() })
        }
        .onChange(of: query) { _, _ in recomputeResults() }
        .onChange(of: store.entries) { _, _ in recomputeResults() }
        // 文字起こしが完了したら一覧を作り直す (issue #321)。
        // ウィンドウを開き直さなくても «後から作成» の結果が一覧・検索・詳細に出る
        // ための受け入れ条件。**完了した録画がこのライブラリの保存先にあるときだけ**
        // 再走査する — パネルからの投入など別フォルダの録画で一覧をいったん空に
        // して作り直す (reload の仕様) のを避けるため
        .onChange(of: transcription.lastCompletion) { _, completion in
            guard let completion, let directory = store.directory,
                  Self.recordingBelongsToDirectory(completion.job.recordingURL, directory)
            else { return }
            store.reload(directory: directory)
        }
        // Spotlight の結果からのオープン (issue #502)。«該当の録画を選んだ状態»
        // にする — 検索語が残っていると一覧が絞り込まれて目的の録画が見えないので
        // クエリを一旦クリアする («Spotlight から開いた» = «目的の録画が決まっている»
        // ため、全文検索の続きを期待しない)。entries に無い URL (旧保存先) は
        // 詳細が空になるだけ (present のコメント参照)
        .onReceive(reveal.$pending) { pending in
            guard let pending else { return }
            query = ""
            recomputeResults()
            selectedEntryID = pending
            reveal.pending = nil
        }
        // «ゴミ箱に入れる» の確認 (issue #523)。録画と同じ stem の文字起こし・
        // 議事録のファイルが一緒に移ることと、«ゴミ箱に戻す» で復元できることを
        // 明示する — «消す» ではなく «移す» であることを言葉の面でも揃える
        .confirmationDialog(
            deleteCandidate.map {
                String(localized: "\($0.recordingURL.lastPathComponent) をゴミ箱に移します")
            } ?? String(localized: "ゴミ箱に移します"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "ゴミ箱に入れる"), role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                deleteCandidate = nil
                moveToTrash(candidate)
            }
            Button(String(localized: "キャンセル"), role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text(String(localized: "録画と、同じ名前の文字起こし・議事録のファイルを一緒に移します。Finder の「ゴミ箱」から「戻す」で復元できます"))
        }
        // «名前を変更» の入力ダイアログ (issue #532)。確認ダイアログ (confirmationDialog)
        // ではなく alert を使う — 入力欄を置けるのはこちら。TextField を含む
        // alert は macOS 13+ で動く (デプロイ対象は 14.0)。実行は «名前を変更» ボタン
        // (role を付けない — destructive ではない: 元に戻す手段はあるし、
        // «壊す» 操作ではない)。検証と実行は rename(_:to:) の正門で行い、
        // 案内はステータス行に出る (ゴミ箱移動と同じ «押してから案内» の流儀)。
        // タイトルは事前に計算した let へ出す — «map ?? 既定値» を式のまま
        // 渡すと型検査が重くなり «unable to type-check in reasonable time» で
        // ビルドが落ちる (実測。body を分割しなくて済む最小の分割)
        .alert(renameDialogTitle, isPresented: $showsRenameDialog) {
            TextField(String(localized: "新しい名前"), text: $renameText)
                .autocorrectionDisabled()
            Button(String(localized: "名前を変更")) {
                guard let candidate = renameCandidate else { return }
                renameCandidate = nil
                rename(candidate, to: renameText)
            }
            Button(String(localized: "キャンセル"), role: .cancel) {
                renameCandidate = nil
            }
        } message: {
            // «接頭辞 «kilde-» は保たれる» をダイアログで先に伝える — ライブラリの
            // 一覧対象の契約 (LibraryRecordingRename.libraryStem のコメント) で、
            // 実行後に «kilde- が勝手に付いた» と驚かせないため
            Text(String(localized: "録画と、同じ名前の文字起こし・議事録のファイルの名前を一緒に変更します (拡張子は変わりません。接頭辞 «kilde-» は保たれます)"))
        }
    }

    /// 録画ファイルがディレクトリの直下にあるか。path 文字列で比べるのは
    /// TranscriptionCoordinator.directoryBookmarkData と同じ — getpwuid 経路の URL が
    /// 末尾 «/» を持つため URL 同士の等価では false になり、symlink 解決 (サンドボックス
    /// のコンテナ内 Movies が実 ~/Movies への symlink になりうる) を先にする
    static func recordingBelongsToDirectory(_ recording: URL, _ directory: URL) -> Bool {
        isSameDirectory(recording.deletingLastPathComponent(), directory)
    }

    /// 2 つの URL が同じディレクトリか (取り込み (issue #416) の «コピー先は今の
    /// 保存先のままか» の確認にも使う)。正規化は recordingBelongsToDirectory と同じ
    static func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func recomputeResults() {
        results = store.index?.search(query) ?? []
        hitCounts = Dictionary(grouping: results, by: \.entryID).mapValues(\.count)
    }

    // MARK: 検索欄

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("文字起こしを検索", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if searching {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("検索をクリア")
            }
            // 既存ファイルの取り込み (issue #416)。文字起こしが使えない環境では
            // «文字起こしを作成« と同じ案内で無効化する (ドロップも coordinator が
            // 同じ判定で案内する)
            Button {
                chooseFilesToImport()
            } label: {
                Label(String(localized: "ファイルを取り込む…"), systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // 取り込みの実行中も無効化 — coordinator は実行中の再投入を無視するので、
            // «押せるのに押しても何も起きない» を «押せない» にする (パネルの流儀と同じ)
            .disabled(!Transcriber.isSupported || importer.isImporting)
            .help(Transcriber.isSupported
                ? String(localized: "既存の音声・動画ファイルを選んで保存先にコピーし、文字起こしします (元のファイルはそのままです)")
                : String(localized: "文字起こしは macOS 26 以降で利用できます"))
            // «ライブラリに質問» (issue #547 — 第五弾 Pro)。検索欄の横に置く —
            // «検索で絞り込んだうえで質問» を 1 つの流れにするため (検索語は
            // エンジンの選定 (searchTerms) に渡り、ヒットのある録画が優先される)。
            // 有効条件と無効理由は LibraryQASupport («環境 → Pro → 書き起こし» の順)
            Button {
                showsLibraryQA = true
            } label: {
                Label(String(localized: "ライブラリに質問"), systemImage: "books.vertical")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!LibraryQASupport.isButtonEnabled(
                hasTranscribedRecording: hasTranscribedRecording,
                appleIntelligenceUnavailableReason: MeetingSummarizer.unsupportedReason,
                proAllows: pro.license.allows(.libraryQA)))
            .help(LibraryQASupport.buttonTooltip(
                hasTranscribedRecording: hasTranscribedRecording,
                appleIntelligenceUnavailableReason: MeetingSummarizer.unsupportedReason,
                proAllows: pro.license.allows(.libraryQA)))
        }
        // «ライブラリに質問» のシート (issue #547)。ボタンが有効なのは
        // 書き起こし済みの録画があるときだけなので、録画列は常に非空
        // (無効のまま開かれる経路は無い — TranscriptQASheet の sheet と同じ考え方)
        .sheet(isPresented: $showsLibraryQA) {
            LibraryQASheet(
                recordings: LibraryQASupport.recordings(from: store.entries),
                license: pro.license,
                // 検索欄の語 «実質空» は nil («絞り込みなし» — エンジンは
                // 質問語だけで選定する)
                searchTerms: LibraryQASupport.searchTerms(from: query),
                // カスタム指示 (issue #472)。«実質空» は写像側で nil。権利の
                // 確認はシート側 ask() の pre-check が担う (TranscriptQASheet と
                // 同じ契約)
                instructions: settings().summaryInstructions)
        }
    }

    // MARK: 取り込み (issue #416)

    /// NSOpenPanel でファイルを選んで取り込む。コピー先はライブラリが今見ている
    /// 保存先。許容する型は audio / movie (エンジンが文字起こしできる対象と同じ)
    private func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.title = String(localized: "ファイルを取り込む")
        panel.message = String(localized: "選んだファイルを保存先にコピーして文字起こします")
        guard panel.runModal() == .OK else { return }
        startImport(panel.urls)
    }

    private func startImport(_ urls: [URL]) {
        guard let directory = store.directory else { return }
        // 文字起こしの設定 (言語・形式) と保存先フォルダの security-scoped bookmark は
        // **取り込みの開始時点** で固定する — GB 級ファイルのコピー中に設定パネルや
        // 保存先を変えても、取り込んだ分は «取り込んだときの設定・フォルダ» で処理される
        // (cubic 指摘。「録画したときの設定» のスナップショットと同じ考え方。
        // bookmark は録画完了通知の «文字起こし» アクション (#392) と同じ先取り —
        // コピー完了時点では旧保存先の sandbox extension が解放されていることがある)
        let snapshot = settings()
        let bookmark = TranscriptionCoordinator.directoryBookmarkData(forDirectory: directory)
        importer.importFiles(
            urls, into: directory,
            onImported: { enqueueImported($0, snapshot: snapshot, directoryBookmark: bookmark) },
            onComplete: { finishImport() })
    }

    /// 取り込みが済んだファイルをその場で文字起こしキューへ。言語・形式は
    /// 取り込みの開始時点の設定 (startImport のスナップショット — ライブラリの
    /// «文字起こしを作成» (#321) と同じ «押された時点» の契約)、要約は付けない —
    /// 要約が欲しいときは取り込み後に «議事録を作成» を使う (完了通知の
    /// «文字起こし» アクション (#392) と同じ扱い。Apple Intelligence が使える
    /// 環境が必要 — 設定パネルと同じ条件)。
    /// **このファイルに既にサイドカーがある場合は投入しない** — TranscriptWriter は
    /// 上書きしないため、再取り込みで `-2` の重複サイドカーができる
    /// (完了通知のアクションと同じ判定。既存のサイドカーは一覧の再走査で詳細に並ぶ)
    private func enqueueImported(
        _ url: URL, snapshot: LibraryTranscriptionSettings, directoryBookmark: Data?) {
        if TranscriptionCoordinator.existingSidecar(for: url, directoryBookmark: directoryBookmark) == nil {
            transcription.enqueue(TranscriptionCoordinator.Job(
                recordingURL: url,
                format: snapshot.format,
                summaryTemplate: nil,
                localeID: snapshot.localeID,
                recordingDuration: nil,
                directoryBookmark: directoryBookmark))
        }
        // 取り込んだファイルを一覧で選んだ状態にする (reload で並んだ直後に詳細が出る)
        selectedEntryID = url
    }

    /// 取り込みの完了。**ライブラリがまだ同じ保存先を見ているときだけ** 再走査する —
    /// コピーの間に保存先を切り替えていたら、旧フォルダの一覧に差し替えてしまうため
    /// (文字起こし完了時の再走査と同じ考え方)
    private func finishImport() {
        guard let directory = store.directory,
              let importedInto = importer.importedDirectory,
              Self.isSameDirectory(directory, importedInto) else { return }
        store.reload(directory: directory)
    }

    // MARK: 録画一覧

    private var listPane: some View {
        Group {
            if store.entries.isEmpty && !store.isScanning {
                ContentUnavailableCompat(
                    title: String(localized: "録画がありません"),
                    detail: String(localized: "保存先に録画ファイルが見つかりませんでした"))
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(store.entries) { entry in
                        LibraryEntryRow(entry: entry,
                                        hitCount: searching ? hitCounts[entry.id] : nil,
                                        isTranscribing: transcription.isQueuedOrRunning(entry.id))
                            .tag(entry.id)
                            // «ゴミ箱に入れる» は一覧の右クリックからも (issue #523)。
                            // 文字起こしの実行中・待機中の録画は出せない — 処理中の
                            // ファイルを消さない (詳細ペインのボタンと同じ判定)
                            .contextMenu {
                                // «名前を変更» は «ゴミ箱に入れる» と並ぶ整理の導線
                                // (issue #532)。«壊す» 操作ではないため «…» を
                                // 付けず確認ダイアログではなく入力ダイアログが出る。
                                // 無効化の判定は «ゴミ箱に入れる» と同じ «押した時点»
                                // の軽い判定 + リネーム・削除の直列化
                                Button(String(localized: "名前を変更…")) {
                                    requestRename(entry)
                                }
                                .disabled(isDeletingTrash || isRenaming
                                          || transcription.isQueuedOrRunning(entry.id)
                                          || canTrashRecording(entry.id))
                                Button(String(localized: "ゴミ箱に入れる…")) {
                                    requestDelete(entry)
                                }
                                // 無効化は «押した時点» の軽い判定 (完全一致 + 録画中)。
                                // canonical 比較 (symlink 解決 = IO) を描画ごとの全行で
                                // 行うとネットワーク保存先で一覧が止まるため、表記違いの
                                // 実行中文字起こしは «押せるが押すと案内が出る» に寄せ、
                                // 実行時 (moveToTrash) の canonical 再確認が正門になる
                                // (cubic レビュー指摘)
                                .disabled(isDeletingTrash || isRenaming
                                          || transcription.isQueuedOrRunning(entry.id)
                                          || canTrashRecording(entry.id))
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: 詳細 (再生 + 文字起こし)

    @ViewBuilder
    private var detailPane: some View {
        if let entry = store.entries.first(where: { $0.id == selectedEntryID }) {
            LibraryDetailView(entry: entry, query: searching ? query : "",
                              hits: hits(for: entry), playback: playback,
                              transcription: transcription, pro: pro, settings: settings,
                              isLibraryMutating: isDeletingTrash || isRenaming,
                              canRename: !isDeletingTrash && !isRenaming
                                  && !transcription.isQueuedOrRunning(entry.id)
                                  && !canTrashRecording(entry.id),
                              onRename: { requestRename(entry) },
                              canTrash: !isDeletingTrash && !isRenaming
                                  && !transcription.isQueuedOrRunning(entry.id)
                                  && !canTrashRecording(entry.id),
                              onTrash: { requestDelete(entry) })
        } else {
            ContentUnavailableCompat(
                title: String(localized: "録画を選択してください"),
                detail: String(localized: "左の一覧から録画を選ぶと再生と文字起こしの検索ができます"))
        }
    }

    private func hits(for entry: LibraryEntry) -> [LibrarySearchHit] {
        guard searching else { return [] }
        return results.filter { $0.entryID == entry.id }
    }

    // MARK: ゴミ箱へ移す (issue #523)

    /// «ゴミ箱に入れる» の確認ダイアログを出す。コンテキストメニューと
    /// 詳細ペインのボタンの共通の入口
    private func requestDelete(_ entry: LibraryEntry) {
        deleteNotice = nil
        deleteCandidate = entry
        showsDeleteConfirmation = true
    }

    /// 確認ダイアログの «ゴミ箱に入れる» での実行。
    /// 文字起こしと録画の進行中チェックはここでも再確認する — ボタンの無効化は
    /// «押した時点» の判定で、ダイアログを出している間に «後から文字起こし» が
    /// 始まったり、その録画が «録画中の出力ファイル» になったりするかもしれない
    /// (処理中・書き込み中のファイルは消さない)
    private func moveToTrash(_ entry: LibraryEntry) {
        guard let directory = store.directory else { return }
        // ジョブが持つ URL と一覧の URL は表記違いがありうる (symlink の
        // `/var` ↔ `/private/var`、MAS コンテナ内 Movies の symlink など) ので、
        // canonical path で比べる — 完全一致だと «表記が違うだけで実行中の
        // 文字起こし» を通してしまう (cubic レビュー指摘)
        // 2 件目の移動を始めない — «同じ stem の録画を続けて削除» すると、
        // 後から始めた方の «別録画の主張» 判定が移動前の一覧で行われ、
        // 共有サイドカーが取り残る (cubic レビュー指摘)。リネームとの直列化も
        // 同じ理由 (issue #532) — 伴走の収集と «別録画の主張» 判定が
        // 他の整理操作と重なると、共有サイドカーの扱いがあいまいになる
        guard !isDeletingTrash && !isRenaming else { return }
        // 正門はここ (実行時点) の canonical 比較 — 描画時の無効化は軽い判定の
        // ため、表記違い (symlink の /var ↔ /private/var、MAS コンテナ内 Movies の
        // symlink など) の «実行中文字起こし» はここで止める (cubic レビュー指摘)
        guard !transcription.isQueuedOrRunningSameFile(entry.recordingURL) else {
            deleteNotice = String(localized: "文字起こしが進行中のためゴミ箱に移せません")
            return
        }
        guard !canTrashRecording(entry.recordingURL) else {
            deleteNotice = String(localized: "録画中のためゴミ箱に移せません")
            return
        }
        isDeletingTrash = true
        // カスタム保存先 (サンドボックス) は security-scoped bookmark を開いてから
        // 触る — TranscriptionCoordinator.existingSidecar の探索と同じ形。
        // ~/Movies は entitlement のため bookmark は作られない (nil が返る)。
        // **scope は移動が完了するまで開いたままにする** — ファイル操作を
        // MainActor の外へ出す (cubic レビュー指摘 — 外付け・ネットワーク
        // ボリュームで UI を止めない) ので、この関数では解放せず、
        // バックグラウンド Task の最後 (defer) で解放する
        var scoped: URL?
        if let data = TranscriptionCoordinator.directoryBookmarkData(forDirectory: directory) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale),
                resolved.startAccessingSecurityScopedResource() {
                scoped = resolved
            }
        }
        Task.detached(priority: .userInitiated) { [entry, directory] in
            defer { scoped?.stopAccessingSecurityScopedResource() }
            do {
                let companions = try LibraryRecordingCleanup.companionFiles(
                    forRecording: entry.recordingURL, in: directory)
                let leftovers = try LibraryRecordingCleanup.moveToTrash(
                    recording: entry.recordingURL,
                    companionFiles: companions,
                    trasher: LibraryRecordingCleanup.systemTrasher)
                await MainActor.run {
                    self.finishMoveToTrash(entry: entry, leftovers: leftovers)
                    self.isDeletingTrash = false
                }
            } catch {
                // «黙って失敗しない» — 権限の無い保存先・ネットワークボリュームでは
                // ゴミ箱へ移せないので、Finder での削除を案内する。
                // «保存先を読めなかった» は原因が違う (フォルダの消失・権限の喪失)
                // ので分けて案内する
                let notice: String
                if (error as? LibraryRecordingCleanup.CleanupError)
                    == .directoryUnreadable {
                    notice = String(localized: "保存先フォルダを読めなかったためゴミ箱に移せませんでした")
                } else {
                    notice = String(localized: "ゴミ箱に移せませんでした — Finder で削除してください (\(error.localizedDescription))")
                }
                await MainActor.run {
                    self.deleteNotice = notice
                    self.isDeletingTrash = false
                }
            }
        }
    }

    /// ゴミ箱移動の成功後の UI 反映 (MainActor)。プレイヤーの停止 → 一覧の
    /// 再走査 → 選択解除 → 結果の案内の順に済ませる
    private func finishMoveToTrash(entry: LibraryEntry, leftovers: [URL]) {
        // プレイヤーがこの録画を持っていれば止める («消したのに音だけ流れる» 防止)。
        // 選択を外すと詳細ペインが «録画を選択してください» に代わり、player は
        // 生き続ける (LibraryPlayerController のコメント) ので、ここでの停止が要る
        playback.stopIfPlaying(url: entry.recordingURL)
        // 一覧を作り直して «消えた» を反映 (Spotlight への索引削除は既存の
        // 差分同期が次の sync で行う — ファイルが無くなった録画は削除対象)。
        // 選択していた録画なら選択も外す
        if let directory = store.directory {
            store.reload(directory: directory)
        }
        if selectedEntryID == entry.id {
            selectedEntryID = nil
        }
        let name = entry.recordingURL.lastPathComponent
        deleteNotice = leftovers.isEmpty
            ? String(localized: "\(name) をゴミ箱に移しました")
            : String(localized: "\(name) をゴミ箱に移しました (残ったサイドカー \(leftovers.count) 件は Finder で消してください)")
    }

    // MARK: 名前を変更 (issue #532)

    /// «名前を変更» の入力ダイアログを出す。コンテキストメニューと
    /// 詳細ペインのボタンの共通の入口。入力は現在の名前 (拡張子なし、
    /// «kilde-» 接頭辞ごと) で満たしておく — «今何という名前か» と
    /// «接頭辞が保たれる» ことをダイアログで読み取れるようにするため
    private func requestRename(_ entry: LibraryEntry) {
        renameNotice = nil
        renameText = entry.recordingURL.deletingPathExtension().lastPathComponent
        renameCandidate = entry
        showsRenameDialog = true
    }

    /// ダイアログの «名前を変更» での実行。文字起こしと録画の進行中チェックは
    /// ここでも再確認する — ボタンの無効化は «押した時点» の判定で、ダイアログを
    /// 出している間に «後から文字起こし» が始まったり、その録画が
    /// «録画中の出力ファイル» になったりするかもしれない (ゴミ箱移動と同じ正門)。
    /// 名前の検証 (空・区切り・衝突) はデータ層 (LibraryRecordingRename) が行い、
    /// 失敗はステータス行の案内に化ける — «押したのに何も起きない» を作らない
    private func rename(_ entry: LibraryEntry, to newName: String) {
        guard let directory = store.directory else { return }
        // canonical 比較と直列化の理由は moveToTrash と同じ —
        // 表記違いの実行中文字起こしはここで止め、整理操作は 1 件ずつ
        guard !isDeletingTrash && !isRenaming else { return }
        guard !transcription.isQueuedOrRunningSameFile(entry.recordingURL) else {
            renameNotice = String(localized: "文字起こしが進行中のため名前を変更できません")
            return
        }
        guard !canTrashRecording(entry.recordingURL) else {
            renameNotice = String(localized: "録画中のため名前を変更できません")
            return
        }
        isRenaming = true
        // security-scoped bookmark の取得と «完了まで開いたまま» の契約は
        // moveToTrash と同じ (カスタム保存先のサンドボックス権限。~/Movies は
        // entitlement のため bookmark は作られない)。解放はバックグラウンド
        // Task の最後 (defer) で行う — ファイル操作を MainActor の外へ出す
        var scoped: URL?
        if let data = TranscriptionCoordinator.directoryBookmarkData(forDirectory: directory) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale),
                resolved.startAccessingSecurityScopedResource() {
                scoped = resolved
            }
        }
        Task.detached(priority: .userInitiated) { [entry] in
            defer { scoped?.stopAccessingSecurityScopedResource() }
            do {
                let companions = try LibraryRecordingCleanup.companionFiles(
                    forRecording: entry.recordingURL, in: directory)
                let oldStem = entry.recordingURL.deletingPathExtension().lastPathComponent
                // «ライブラリに載る stem» への変換はデータ層の正門 (libraryStem) で
                // 行う — 一覧の契約 «kilde- 接頭辞 + 録画形式» を保ち、接頭辞を
                // 外した名前に変えても録画が一覧・最近の録画・Spotlight から
                // 消えないようにする (LibraryRecordingRename.libraryStem のコメント)
                let newStem = try LibraryRecordingRename.libraryStem(
                    fromUserInput: newName, currentStem: oldStem)
                let leftovers = try LibraryRecordingRename.rename(
                    recording: entry.recordingURL,
                    companionFiles: companions,
                    newStem: newStem,
                    renamer: LibraryRecordingRename.systemRenamer)
                // リネーム後の URL は «走査と同じ表記のディレクトリ» (entry.recordingURL
                // は走査結果) から組む — reload 後の entry.id と表記が揃い、
                // 選択の維持が URL 同士の一致で効く (LibraryImport が «走査の表記を
                // そのまま使う» のと同じ理由)
                let newURL = entry.recordingURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        newStem + (entry.recordingURL.pathExtension.isEmpty
                            ? "" : ".\(entry.recordingURL.pathExtension)"))
                await MainActor.run {
                    self.finishRename(entry: entry, newURL: newURL, leftovers: leftovers)
                    self.isRenaming = false
                }
            } catch {
                // «黙って失敗しない» — 入力の問題 (検証エラー) とフォルダの問題
                // (衝突・読めない) を分けて案内する。«その他» は権限の無い保存先・
                // ネットワークボリュームなので Finder での変更を案内する。
                // «保存先を読めなかった» は 2 経路で来る — rename 前段の
                // companionFiles (CleanupError.directoryUnreadable) と rename 内の
                // 衝突検査の走査 (RenameError.directoryUnreadable)。前者を
                // «その他» に落とすと «Finder で変更してください» に化けて、
                // «フォルダが消えた・権限が落ちた» という本当の原因が伝わらない
                // (cubic レビュー指摘 — moveToTrash が CleanupError を区別するのと同じ)
                let renameError = error as? LibraryRecordingRename.RenameError
                let cleanupError = error as? LibraryRecordingCleanup.CleanupError
                let notice: String
                if renameError == .directoryUnreadable
                    || cleanupError == .directoryUnreadable {
                    notice = String(localized: "保存先フォルダを読めなかったため名前を変更できませんでした")
                } else {
                    switch renameError {
                    case .invalidName:
                        notice = String(localized: "その名前は使えません — 空でなく、「/」「:」を含まず、先頭が「.」でない名前を入力してください (名前が長すぎるときも使えません)")
                    case .nameUnchanged:
                        notice = String(localized: "名前が変わっていないため何もしませんでした")
                    case .conflict:
                        notice = String(localized: "同じ名前のファイルがあるため名前を変更できません")
                    default:
                        notice = String(localized: "名前を変更できませんでした — Finder で変更してください (\(error.localizedDescription))")
                    }
                }
                await MainActor.run {
                    self.renameNotice = notice
                    self.isRenaming = false
                }
            }
        }
    }

    /// リネームの成功後の UI 反映 (MainActor)。プレイヤーの停止 → 一覧の
    /// 再走査 → 選択の維持 → 結果の案内の順に済ませる。
    /// «選択の維持» は削除と逆の契約 — 録画は消えていないので、
    /// «詳細を見ていた人» が新しい名前の詳細にそのまま乗り換えられる
    private func finishRename(entry: LibraryEntry, newURL: URL, leftovers: [URL]) {
        // プレイヤーが旧 URL を持っていれば止める — reload 後の onChange(of: entry.id)
        // が新しい URL で差し替えるが、旧 URL を参照した item のまま一瞬
        // «変えたのに前の名前のファイルが鳴る» 状態になるのを避ける
        playback.stopIfPlaying(url: entry.recordingURL)
        // 一覧を作り直して «名前が変わった» を反映 (Spotlight への反映は既存の
        // 差分同期が行う — «旧名の削除 + 新名の追加» は同期の実行時に現れる)
        if let directory = store.directory {
            store.reload(directory: directory)
        }
        // 選択をリネーム後の録画へ移す。reload で entries が組み直るまで詳細は
        // «録画を選択してください» に代わるが、取り込み (issue #416) の
        // «選択を先に置く» と同じ — 一覧が並ぶと詳細が戻る
        selectedEntryID = newURL
        let oldName = entry.recordingURL.lastPathComponent
        let newName = newURL.lastPathComponent
        renameNotice = leftovers.isEmpty
            ? String(localized: "\(oldName) を \(newName) に変更しました")
            : String(localized: "\(oldName) を \(newName) に変更しました (残ったサイドカー \(leftovers.count) 件は旧名のままです — Finder で名前を変更してください)")
    }

    // MARK: ステータス

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("読み込み中…")
            } else {
                let withTranscript = store.entries.count { $0.segments != nil }
                Text("\(store.entries.count) 件の録画 · 文字起こし \(withTranscript) 件")
            }
            if importer.isImporting {
                ProgressView()
                    .controlSize(.small)
                Text("取り込んでいます…")
            } else if let notice = importer.lastNotice {
                Text(notice)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // «ゴミ箱へ移す» の結果 (issue #523)。成功の案内も出す — 一覧から
            // 消えたことは分かるが «サイドカーごと移った» ことは一覧だけでは読めない
            if let deleteNotice {
                Text(deleteNotice)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // «名前を変更» の結果 (issue #532)。ゴミ箱移動の案内と分けて並べる —
            // «整理の 2 導線» の結果が同時に出ても別の出来事として読めるように
            if let renameNotice {
                Text(renameNotice)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if searching {
                Text("検索: \(results.count) 件のセグメント")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let directory = store.directory {
                Text(directory.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 録画一覧の 1 行
private struct LibraryEntryRow: View {
    let entry: LibraryEntry
    let hitCount: Int?
    /// この録画の文字起こしが実行中 (または待機中) か (issue #321)。
    /// «文字起こしなし» の代わりに処理中を見せる — 詳細ペインを選ばなくても
    /// 一覧で処理の途中が分かるようにする
    let isTranscribing: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// 長さの表示 (1 時間未満は m:ss、以上は h:mm:ss)。
    /// duration はサイドカーの最終セグメント終了時刻由来の近似値である
    private static func durationText(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: entry.segments != nil ? "film.stack" : "film")
                    .foregroundStyle(.secondary)
                Text(entry.recordingURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Text(Self.dateFormatter.string(from: entry.recordedAt))
                if let duration = entry.duration {
                    Text(Self.durationText(duration))
                }
                if entry.segments == nil {
                    if isTranscribing {
                        // «文字起こし中» は既存のカタログ鍵 («Transcribing») を流用する —
                        // 進みつつあることはスピナーが担うので «…» は付けない
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(String(localized: "文字起こし中"))
                        }
                    } else {
                        Text(String(localized: "文字起こしなし"))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let hitCount {
                    Text(String(localized: "\(hitCount) 件ヒット"))
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let preview = entry.preview {
                // 要約/文字起こしの冒頭 (issue #165 スコープの «要約の冒頭»)
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 選択中の録画の詳細。上にプレイヤー、下に文字起こしのセグメント列。
/// セグメント行クリックで該当時刻へシークして再生する (issue #165 の受け入れ条件)。
/// 検索語があるときはヒットしたセグメントだけを表示し、ヒット箇所をハイライトする。
/// 文字起こしの無い録画では «後から文字起こし・議事録を作成» のアクションと
/// 進捗を出す (issue #321)
private struct LibraryDetailView: View {
    let entry: LibraryEntry
    let query: String
    let hits: [LibrarySearchHit]
    @ObservedObject var playback: LibraryPlayerController
    @ObservedObject var transcription: TranscriptionCoordinator
    /// Pro の権利。権利が変わったら «議事録を作成» のロック状態を即時反映する
    /// (cubic レビュー指摘 — 観測しないと別デバイスでの購入・返金が開き直しまで
    /// 反映されない)
    @ObservedObject var pro: ProCoordinator
    let settings: () -> LibraryTranscriptionSettings
    /// ライブラリの整理操作 (リネーム / ゴミ箱移動) が進行中か (issue #532)。
    /// «文字起こしを作成» «議事録を作成» «再試行» を無効化する — これらは
    /// **表示中の録画の URL をジョブに載せる** ため、リネームの進行中に押すと
    /// «旧名のファイル» を処理するジョブが走り、リネームとの競合 (旧名の
    /// サイドカーが生える・文字起こしが失敗する) を作る (cubic レビュー指摘)。
    /// 録画は消えていないので押せてしまう、が落とし穴
    let isLibraryMutating: Bool
    /// «名前を変更» を押せるか (issue #532)。文字起こしの実行中・待機中は
    /// 押せない — 処理中のファイルの名前を変えない («ゴミ箱に入れる» と同じ判定)。
    /// ゴミ箱移動とリネームの進行中も押せない (整理操作の直列化)
    let canRename: Bool
    /// «名前を変更» の押下。入力ダイアログは親 (LibraryView) が出す —
    /// 一覧の右クリックと同じダイアログを 1 箇所にまとめるため
    let onRename: () -> Void
    /// «ゴミ箱に入れる» を押せるか (issue #523)。文字起こしの実行中・待機中は
    /// 押せない — 処理中のファイルを消さない (一覧のコンテキストメニューと同じ判定)
    let canTrash: Bool
    /// «ゴミ箱に入れる» の押下。確認ダイアログは親 (LibraryView) が出す —
    /// 一覧の右クリックと同じ確認を 1 箇所にまとめるため
    let onTrash: () -> Void
    /// この録画の «再試行» の対象に表示する失敗。coordinator の lastFailure は
    /// «最新の 1 件» スロットで別の録画の失敗に押し出されるため (cubic 指摘)、
    /// この録画の失敗は表示側で覚える — 消えるのはこの録画の文字起こしの成功時
    /// か選択の切替時。観測の詳細は body の onChange と seedShownFailure()
    @State private var shownFailure: TranscriptionCoordinator.Failure?
    /// この録画の議事録 (.md) の、フォローアップ下書きの入力状態 (issue #464)。
    /// サイドカーの読み取りは body 評価のたびに走らせないため @State に置き、
    /// onAppear と録画の切替・差し替え (entry の変化) で更新する
    @State private var minutesDoc: FollowupDraftSupport.MinutesDoc = .notMinutes
    /// フォローアップ下書きシート (issue #464) の表示
    @State private var showsFollowupDraft = false
    /// 質問応答シート (issue #540 — 第四弾 Pro) の表示
    @State private var showsTranscriptQA = false
    /// «リマインダーへ追加» (issue #509) の EventKit ラッパ。権限の要求と
    /// 書き出しは押下時にこのラッパを通して行う — ボタンの有無は議事録の内容
    /// (正規化後のアクションの有無) だけで決まり、権限の状態を表示に反映しない
    /// («押したときだけ要求» の方針のため。拒否されたときの案内は結果表示が出る)
    @StateObject private var reminderExporter = ReminderExporter()
    /// «リマインダーへ追加» の結果表示 (追加件数・権限の案内)。nil は «表示なし»。
    /// 録画を切り替えたら消す (前の録画の結果が残ると別の議事録の結果と誤読するため)
    @State private var reminderNotice: ReminderNotice?
    /// «リマインダーへ追加» の実行中。権限ダイアログの表示中や書き込み中の再入を
    /// 潰す — 並行に 2 回走ると同じ項目を二重に追加する (cubic レビュー指摘)
    @State private var isExportingReminders = false
    /// 書き出しの世代。処理の途中で録画が切り替わったとき、押した時点の Task が
    /// 古い録画の結果を新しい録画の表示に書かないための照合に使う — Task は
    /// 押した時点の世代の値を捕まえるので、書き込みの直前に現在値と比べる
    /// (cubic レビュー指摘。切替時にインクリメントするのは entry.id の onChange)
    @State private var reminderEpoch = 0

    /// «リマインダーへ追加» の 1 表示分。message に案内文、offersSettingsLink が
    /// true のとき «設定を開く» の導線を添える (権限が拒否されている場合のみ)
    private struct ReminderNotice: Equatable {
        let message: String
        let offersSettingsLink: Bool
    }

    /// 表示するセグメント (検索中はヒット順)。行ビューに渡す最小限の形にする
    private struct Row: Identifiable {
        let segmentIndex: Int
        let start: TimeInterval
        let text: String
        var id: Int { segmentIndex }
    }

    private var rows: [Row] {
        if !query.isEmpty {
            return hits.map { Row(segmentIndex: $0.segmentIndex, start: $0.start, text: $0.text) }
        }
        return (entry.segments ?? []).enumerated().map {
            Row(segmentIndex: $0.offset, start: $0.element.start, text: $0.element.text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryPlayerView(player: playback.player)
                .frame(height: 240)
                .background(Color(nsColor: .windowBackgroundColor))
                // «名前を変更» («ゴミ箱に入れる» と並ぶ整理の導線 — issue #532) と
                // «ゴミ箱に入れる» (issue #523)。プレイヤーの操作系 (下部のバー) と
                // 重ならない右上に出す — 詳細ペインに専用のヘッダー行は無いため。
                // «壊す» 操作が左 («ゴミ箱») に寄る自然な並びにする — リネームは
                // «整える»、ゴミ箱は «減らす» で、右端を取り消しにくい操作に揃える
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            onRename()
                        } label: {
                            Label(String(localized: "名前を変更"), systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canRename)
                        .help(canRename
                            ? String(localized: "録画と同じ名前の文字起こし・議事録のファイルの名前を一緒に変更します")
                            : String(localized: "文字起こし・録画が進行中のため名前を変更できません"))
                        Button {
                            onTrash()
                        } label: {
                            Label(String(localized: "ゴミ箱に入れる"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canTrash)
                        .help(canTrash
                            ? String(localized: "録画と同じ名前の文字起こし・議事録のファイルをゴミ箱に移します")
                            : String(localized: "文字起こし・録画が進行中のため移せません"))
                    }
                    .padding(8)
                }
            Divider()
            if entry.segments == nil {
                noTranscriptPane
            } else {
                // «質問する» の導線 (issue #540 — 第四弾 Pro) をセグメント列の上に
                // 置く。質問応答は**要約 (.md) を必要としない**ため、書き起こしを
                // 持つ録画なら常にバーを出す (フォローアップより広い録画で使える)。
                // «リマインダーへ追加» «フォローアップを下書き» (issue #509 / #464) は
                // 議事録 (.md) の要約が必要なため、あるときだけ出す
                // (FollowupDraftSupport.loadMinutesDoc の契約)
                transcriptActionsBar
                Divider()
                segmentList
            }
        }
        .onAppear {
            playback.prepare(url: entry.recordingURL)
            seedShownFailure()
            refreshMinutesDoc()
        }
        .onChange(of: entry) { _, newEntry in
            // 録画の切替と、この録画のサイドカーの差し替え («議事録を作成» の完了で
            // entries が組み直される) の両方で議事録の状態を読み直す
            minutesDoc = FollowupDraftSupport.loadMinutesDoc(
                sidecarURL: newEntry.transcriptURL)
        }
        .onChange(of: entry.id) { _, newURL in
            // 録画が切り替わったらプレイヤーを差し替える (prepare は同じ URL では何もしない)。
            // 失敗表示も新しい録画のものに引き継ぎ直す (shownFailure の契約は «この録画の» 失敗)
            playback.prepare(url: newURL)
            seedShownFailure()
            // «リマインダーへ追加» の結果は «この録画の» 結果なので、切替時に消し、
            // 世代を進める (処理中の Task が古い結果を書かない照合に使う)
            reminderEpoch += 1
            reminderNotice = nil
        }
        // coordinator の失敗スロット (lastFailure) は «最新の 1 件» — 別の録画が
        // 失敗すると押し出されるため、この録画の «再試行» を出し続けるには
        // 表示に覚えておく必要がある (cubic 指摘)。この録画の失敗が届いたら
        // 表示に覚え、成功 (この録画の完了) で役目を終える
        .onChange(of: transcription.lastFailure) { _, failure in
            if let failure, failure.job.recordingURL == entry.recordingURL {
                shownFailure = failure
            }
        }
        .onChange(of: transcription.lastCompletion) { _, completion in
            if let completion, completion.job.recordingURL == entry.recordingURL {
                shownFailure = nil
            }
        }
    }

    /// 失敗表示の種。«最新の失敗» がこの録画のものなら表示に引き継ぎ、
    /// そうでなければ消す — 選択の切替やウィンドウを開き直した直後は、
    /// パネルと同じ «最新 1 件» の状態から始める
    private func seedShownFailure() {
        if let failure = transcription.lastFailure,
           failure.job.recordingURL == entry.recordingURL {
            shownFailure = failure
        } else {
            shownFailure = nil
        }
    }

    /// 文字起こしの無い録画の詳細ペイン (issue #321)。«後から文字起こし» を
    /// その場で投入する。処理中 (キュー待ちを含む) は進捗を出し、アクションは
    /// 押せなくする — coordinator は同じ録画の重複投入を黙って捨てるので、
    /// «押せるのに押しても何も起きない» より «押せない» を見せる (パネルと同じ流儀)
    private var noTranscriptPane: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(String(localized: "文字起こしがありません"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(String(localized: "この録画には文字起こしサイドカーがありません。作成すると検索の対象になります"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if transcription.isQueuedOrRunning(entry.recordingURL) {
                transcriptionProgress
            } else {
                actionButtons
                // この録画の失敗を出す («押したのに消えた» よけいに、失敗の理由と
                // 再試行を同じ場所に置く)。shownFailure は «この録画の最後の失敗» を
                // 覚えている — coordinator の lastFailure は «最新の 1 件» スロットで
                // 別の録画の失敗に押し出されるため、そのまま参照すると他の録画の
                // 失敗と入れ替わってしまう (cubic 指摘)
                if let failure = shownFailure {
                    failureNotice(failure)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// «文字起こしを作成» と «議事録を作成»。«押された時点の» パネル設定を使う
    /// (issue #147 と同じ «現在の設定» の規約) — ライブラリは RecordingSetup を
    /// 購読しないため、disabled / ツールチップの見た目は本文評価時のスナップショット
    /// (`let snapshot`) だが、**実行はアクションの中で設定を読み直す**
    /// (CodeRabbit 指摘 — ライブラリを開いたまま設定パネルで変えた設定を反映させる)。
    /// «議事録» は文字起こし + 要約で、Apple Intelligence が使えない環境と
    /// Pro 未購入 (issue #170 — 要約は第一弾 Pro 機能) では押せず、理由を
    /// ツールチップに出す (設定パネルの案内と同じ文言)。購入導線は設定パネルに
    /// しか無い («控えめ» 方針 — ここではロックの案内だけ)
    private var actionButtons: some View {
        let snapshot = settings()
        // Pro 権利は ObservedObject の ProCoordinator から読む — 変化 (購入・返金) で
        // このビューが再評価される (cubic レビュー指摘)。実行時のゲート
        // (TranscriptionCoordinator + エンジン) は常に最新値で判定する
        let proLocked = !pro.license.allows(.summary)
        return HStack(spacing: 12) {
            Button {
                enqueue(withSummary: false, snapshot: settings())
            } label: {
                Label(String(localized: "文字起こしを作成"), systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            // 整理操作 (リネーム / ゴミ箱移動) の進行中は無効化 — ジョブに載る
            // recordingURL が «移されつつあるファイル» になるため (isLibraryMutating
            // のコメント)。理由の案内は無効のときだけ出す (有効時のツールチップは
            // 従来どおり無し — ボタンの意味はラベルで読める)
            .disabled(isLibraryMutating)
            .help(isLibraryMutating
                ? String(localized: "名前の変更・ゴミ箱への移動が進行中のため押せません")
                : "")
            Button {
                enqueue(withSummary: true, snapshot: settings())
            } label: {
                Label(String(localized: "議事録を作成"), systemImage: "waveform.badge.waveform")
            }
            .buttonStyle(.bordered)
            .disabled(snapshot.summaryUnsupportedReason != nil || proLocked
                      || isLibraryMutating)
            .help(isLibraryMutating
                ? String(localized: "名前の変更・ゴミ箱への移動が進行中のため押せません")
                : snapshot.summaryUnsupportedReason.map { reason in
                    String(localized: "要約には Apple Intelligence が必要です: \(reason)")
                } ?? (proLocked
                    ? String(localized: "会議の要約は Pro の機能です (設定パネルから購入できます)")
                    : String(localized: "文字起こしの後に要約を生成して Markdown (.md) に載せます (テンプレートは設定パネルの選択を使います)")))
        }
    }

    /// 書き起こしの次の一手の導線。«質問する» (issue #540 — 第四弾 Pro) と
    /// «リマインダーへ追加» (issue #509 — 要約のアクションアイテムを EventKit
    /// Reminders へ書き出す) と «フォローアップを下書き» (issue #464 — 第二弾 Pro)。
    /// 質問は書き起こしがあれば使え、リマインダーと下書きは議事録 (.md) の要約から
    /// 使える。有効条件とツールチップは TranscriptQASupport /
    /// FollowupDraftSupport / ReminderExportSupport に一元化 (セルフテスト対象)。
    /// «議事録を作成» と同じ «控えめ» 方針 — Pro 未購入の案内はツールチップのみで、
    /// 購入導線は設定パネルにしか置かない
    private var transcriptActionsBar: some View {
        let unsupportedReason = MeetingSummarizer.unsupportedReason
        let proAllowsQA = pro.license.allows(.transcriptQA)
        let proAllows = pro.license.allows(.followupDraft)
        return HStack {
            Spacer()
            if let notice = reminderNotice {
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(notice.offersSettingsLink ? Color.orange : Color.secondary)
                    .lineLimit(2)
                if notice.offersSettingsLink {
                    // 権限が拒否されているときの導線 (CalendarTitles.openSettings と
                    // 同じ系統のリマインダー用ペイン)
                    Button(String(localized: "リマインダーの設定を開く")) {
                        reminderExporter.openSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Button {
                showsTranscriptQA = true
            } label: {
                Label(String(localized: "質問する"), systemImage: "questionmark.bubble")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            // このバーは書き起こしを持つ録画のときしか出ないため、
            // hasTranscript は常に true (無効理由は環境と Pro 権利だけ)
            .disabled(!TranscriptQASupport.isButtonEnabled(
                hasTranscript: true,
                appleIntelligenceUnavailableReason: unsupportedReason,
                proAllows: proAllowsQA))
            .help(TranscriptQASupport.buttonTooltip(
                hasTranscript: true,
                appleIntelligenceUnavailableReason: unsupportedReason,
                proAllows: proAllowsQA))
            if minutesDoc != .notMinutes {
                Button {
                    exportToReminders()
                } label: {
                    Label(String(localized: "リマインダーへ追加"), systemImage: "checklist")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                // 実行中は無効化する — «押せるのに押しても何も起きない» より
                // «押せない» を見せる (パネルの流儀。再入防止と同じ理由)
                .disabled(!ReminderExportSupport.isButtonEnabled(doc: minutesDoc) || isExportingReminders)
                .help(ReminderExportSupport.buttonTooltip(doc: minutesDoc))
                Button {
                    showsFollowupDraft = true
                } label: {
                    Label(String(localized: "フォローアップを下書き"), systemImage: "envelope")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(!FollowupDraftSupport.isButtonEnabled(
                    doc: minutesDoc,
                    appleIntelligenceUnavailableReason: unsupportedReason,
                    proAllows: proAllows))
                .help(FollowupDraftSupport.buttonTooltip(
                    doc: minutesDoc,
                    appleIntelligenceUnavailableReason: unsupportedReason,
                    proAllows: proAllows))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sheet(isPresented: $showsTranscriptQA) {
            // ボタンが有効なのは書き起こしを持つ録画のときだけなので、
            // シートの内容は常に書き起こしを持てる (無効のまま開かれる経路は無い)。
            // ライブラリの索引 (LibrarySegment) は**話者を保持しない**ため、
            // エンジンの TranscriptSegment への写像は speaker: nil になる —
            // «誰が言ったか» を問う質問の精度は落ちるが、本文ベースの質問応答は
            // 成立する。話者の保持はライブラリ索引の拡張で別 issue に切り出す
            TranscriptQASheet(
                transcript: (entry.segments ?? []).map {
                    TranscriptSegment(
                        start: $0.start, end: $0.end, text: $0.text, speaker: nil)
                },
                title: entry.recordingURL.deletingPathExtension().lastPathComponent,
                license: pro.license,
                // カスタム指示 (issue #472)。«実質空» は写像側で nil。権利の
                // 確認はシート側 ask() の pre-check が担う (非空の指示に権利が
                // ないときは実行を止めて案内を出す — 黙って指示なしで実行しない
                // ため。FollowupDraftSheet と同じ契約)
                instructions: settings().summaryInstructions)
        }
        .sheet(isPresented: $showsFollowupDraft) {
            // ボタンが有効なのは .summary のときだけなので、シートの内容は常に
            // 要約を持てる (無効のまま開かれる経路は無い)
            if case .summary(let summary) = minutesDoc {
                FollowupDraftSheet(
                    summary: summary,
                    title: entry.recordingURL.deletingPathExtension().lastPathComponent,
                    license: pro.license,
                    // カスタム指示 (issue #472)。«実質空» は写像側で nil。権利の
                    // 確認はシート側 generate() の pre-check が担う (非空の指示に
                    // 権利がないときは生成を止めて案内を出す — 黙って指示なしで
                    // 生成しないため)
                    instructions: settings().summaryInstructions)
            }
        }
    }

    /// «リマインダーへ追加» の実行 (issue #509)。権限は **この押下のときだけ**
    /// 要求する (ReminderExporter のクラスコメント)。未確定 → 要求 → 許可なら
    /// そのまま追加、拒否なら «設定を開く» 付きの案内に切替える。追加の実行は
    /// 既定のリマインダーリストへの書き込みで、端末内のみ (PRIVACY.md «リマインダー»)
    private func exportToReminders() {
        // 再入防止 — 権限ダイアログの表示中・書き込み中の連打で 2 回走らせない
        // (同じ項目を二重に追加するため。cubic レビュー指摘)
        guard !isExportingReminders else { return }
        let epoch = reminderEpoch
        let actions = ReminderExportSupport.actions(in: minutesDoc)
        let meetingName = entry.recordingURL.deletingPathExtension().lastPathComponent
        isExportingReminders = true
        Task { @MainActor in
            defer { isExportingReminders = false }
            await reminderExporter.requestAccess()
            if let failure = reminderExporter.lastRequestFailure {
                // «拒否» ではなく «要求自体が失敗» — 設定を開く案内は出さない
                // (もう一度押せば要求し直す。CodeRabbit 指摘)。表示は
                // «押した時点の録画» の画面にだけ載せる (世代照合)
                guard epoch == reminderEpoch else { return }
                reminderNotice = ReminderNotice(
                    message: failure, offersSettingsLink: false)
                return
            }
            guard reminderExporter.status.canWrite else {
                guard epoch == reminderEpoch else { return }
                reminderNotice = ReminderNotice(
                    message: String(localized: "リマインダーへのアクセスが許可されていません (許可すると追加できます)"),
                    offersSettingsLink: true)
                return
            }
            do {
                let items = ReminderExportSupport.items(
                    fromActions: actions, meetingName: meetingName)
                let count = try await reminderExporter.export(items)
                // «書き出した» 事実だけを計測に載せる (項目の文面・件数は送らない —
                // «値は列挙に閉じる» 規約。パラメータなしイベントのためカスタム
                // ディメンション登録も不要 — issue #456)
                UsageAnalytics.reminderExported()
                guard epoch == reminderEpoch else { return }
                reminderNotice = ReminderNotice(
                    message: String(localized: "\(count) 件のアクションをリマインダーに追加しました"),
                    offersSettingsLink: false)
            } catch {
                guard epoch == reminderEpoch else { return }
                reminderNotice = ReminderNotice(
                    message: (error as? ReminderExporter.ExportError)?.message
                        ?? String(localized: "リマインダーに追加できませんでした"),
                    offersSettingsLink: !reminderExporter.status.canWrite)
            }
        }
    }

    /// 議事録 (.md) の入力状態を読み直す (onAppear 用 — @State の既定値は
    /// .notMinutes のため、表示のたびに更新が必要)
    private func refreshMinutesDoc() {
        minutesDoc = FollowupDraftSupport.loadMinutesDoc(
            sidecarURL: entry.transcriptURL)
    }

    /// この録画の処理の進捗。キュー待ちと実行中で見せ方を分ける —
    /// runPhase は «現在実行中のジョブ» のものなので、自分の録画が実行中で
    /// ないなら «順番待ち» を出す (別の録画の進捗を自分のものと誤認させない)
    @ViewBuilder
    private var transcriptionProgress: some View {
        VStack(spacing: 6) {
            if transcription.running?.recordingURL == entry.recordingURL {
                Label(progressLabel, systemImage: "waveform")
                    .font(.caption)
                progressBar
            } else {
                Label(String(localized: "文字起こしの順番を待っています… (進捗は設定パネルにも出ます)"),
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
    }

    /// 実行中表示のラベル。設定パネルの transcriptionRunLabel と同じ語彙にする
    private var progressLabel: String {
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

    /// 実行中の進捗バー。設定パネルの transcriptionProgressBar と同じ —
    /// モデルの総サイズが取れる前 (progress 0) は不定長表示
    @ViewBuilder
    private var progressBar: some View {
        switch transcription.runPhase {
        case .preparingModel(let progress):
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

    /// この録画の文字起こしの失敗。パネルの transcriptionStatusView と同じ体裁で、
    /// «再試行» は **表示中のこの失敗** を対象にする (`retry(_:)`) —
    /// «その時点の最終失敗» (retryLastFailure) では、表示と押下の間に別の録画が
    /// 失敗したとき違うジョブを再実行しうる (CodeRabbit 指摘)
    private func failureNotice(_ failure: TranscriptionCoordinator.Failure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = failure.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button(String(localized: "再試行")) { transcription.retry(failure) }
                .buttonStyle(.link)
                .font(.caption)
                // 整理操作の進行中は無効化 — «再試行» もジョブにこの録画の URL を
                // 載せるため («文字起こしを作成» と同じ理由)
                .disabled(isLibraryMutating)
        }
        .padding(10)
        .frame(maxWidth: 420)
    }

    /// ジョブをキューへ投入する。重複投入は coordinator が捨てるが、
    /// このボタンは処理中には表示されないため通常通らない
    private func enqueue(withSummary: Bool, snapshot: LibraryTranscriptionSettings) {
        transcription.enqueue(TranscriptionCoordinator.Job(
            recordingURL: entry.recordingURL,
            format: snapshot.format,
            summaryTemplate: withSummary ? snapshot.summaryTemplate : nil,
            // カスタム指示 (issue #472)。«実質空» は写像側で nil。権利がなくても
            // そのまま運ぶ — 実行時ゲート (coordinator の pre-check) が案内を出す
            summaryInstructions: withSummary ? snapshot.summaryInstructions : nil,
            localeID: snapshot.localeID,
            // サイドカーが無いので録音長は不明 (nil) — 計測では長さ区分を送らない
            // (パネルの «後から文字起こし» と同じ扱い)
            recordingDuration: nil))
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダー行。検索中はヒット数、常に右端に «全文をコピー» と «書き出す»
            // (issue #329 / #493)。書き出しは検索の絞り込みに関わらず
            // **録画全体の文字起こし** を対象にする — «持ち出したいのは表示中の
            // 録画の全文» で、ヒット行だけの需要は (#329 PR の見込みどおり)
            // このヘッダーの «全文をコピー» と行の «このセグメントをコピー» で足りる
            HStack(spacing: 8) {
                if !query.isEmpty {
                    Text(String(localized: "ヒット \(rows.count) 件 / 全 \(entry.segments?.count ?? 0) セグメント"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                copyWholeButton
                exportMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                List(rows) { row in
                    LibrarySegmentRow(text: row.text, query: query, start: row.start) {
                        playback.seek(to: row.start)
                    }
                    // 行は «クリックでシーク» のボタンのため本文をテキスト選択できない
                    // (LibrarySegmentRow)。その分、コンテキストメニューで本文を
                    // 持ち出せるようにする (issue #493)
                    .contextMenu {
                        Button(String(localized: "このセグメントをコピー")) {
                            copySegment(row.text)
                        }
                    }
                    .id(row.id)
                }
                .listStyle(.plain)
                .onAppear {
                    // 検索で絞り込んだ直後は最初のヒットに目を飛ばす —
                    // 長い文字起こしで «どこにヒットしたか» を探させない
                    if let first = rows.first { proxy.scrollTo(first.id) }
                }
            }
        }
    }

    /// «全文をコピー»。txt 書き出しと同じ «[時刻] 本文» の形でクリップボードへ
    /// 入れる — «書き出しと同じものが手軽に取れる» ため (issue #493)
    private var copyWholeButton: some View {
        Button {
            guard let segments = entry.segments, !segments.isEmpty else { return }
            if LibraryTranscriptExport.copyToPasteboard(
                LibraryTranscriptExport.plainText(segments)) {
                UsageAnalytics.transcriptCopy(kind: .whole)
            }
        } label: {
            Label(String(localized: "全文をコピー"), systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // 空のセグメント列は (サイドカーは必ず 1 行以上を持つが) 防御として無効化
        .disabled(entry.segments?.isEmpty != false)
        .help(String(localized: "文字起こし全体を «[時刻] 本文» の形でクリップボードにコピーします"))
    }

    /// «書き出す»。形式 (txt / srt / vtt) はメニューで選び、保存パネルは選んだ
    /// 拡張子に固定する (issue #493)。書き出しは検索の絞り込みに関わらず
    /// 録画全体が対象 (#329 と同じ契約)
    private var exportMenu: some View {
        Menu {
            ForEach(LibraryTranscriptExport.supportedFormats, id: \.self) { format in
                Button(LibraryTranscriptExport.menuLabel(for: format)) {
                    LibraryTranscriptExport.exportTranscript(of: entry, as: format)
                }
            }
        } label: {
            Label(String(localized: "書き出す"), systemImage: "square.and.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(String(localized: "文字起こし全体をファイルに保存します (.txt / .srt / .vtt を選べます)"))
    }

    /// セグメント 1 件の本文をクリップボードへ。時刻は付けない — 貼り付け先では
    /// 本文だけが欲しいことが多く、«[時刻]» 付きが欲しいときは «全文をコピー» がある
    private func copySegment(_ text: String) {
        if LibraryTranscriptExport.copyToPasteboard(text) {
            UsageAnalytics.transcriptCopy(kind: .segment)
        }
    }
}

/// 文字起こしの 1 行。時刻ボタンと本文 (検索語ハイライト)。行クリックでシークする
private struct LibrarySegmentRow: View {
    let text: String
    let query: String
    let start: TimeInterval
    let onSeek: () -> Void

    var body: some View {
        Button(action: onSeek) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.clockFormatter.string(from: Date(timeIntervalSinceReferenceDate: start)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tint)
                    // クリック領域を時刻にも広げる (ボタン全体でシークする)
                    .frame(minWidth: 64, alignment: .leading)
                highlightedText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("該当時刻から再生")
    }

    /// 検索語を太字 + オレンジ色で示す。大文字小文字は検索と同じ正規化で見つける
    private var highlightedText: some View {
        Self.highlighted(text: text, query: query)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // start は «録画開始からの経過秒»。Date(timeIntervalSinceReferenceDate:) の
        // 基準 (2001-01-01T00:00:00Z) を UTC で見れば 00:00:00 + 経過秒になる —
        // ローカルタイムゾーンのままでは JST 環境で 0 秒が 09:00:00 と表示される
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// ヒットした区間を «(部分文字列, ハイライトするか)» の列に分割する。
    /// Text の連結はスタイルを個別に持てるため AttributedString の index 変換が要らない。
    /// ハイライトは太字 + オレンジ色 — Text には背景色修飾子が無く (some View を返す)、
    /// 連結を崩さずに背景を付けるには AttributedString への変換が要るため割り切った
    static func highlighted(text: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // ヒット位置は下のループで探すので、ここでは «1 箇所でも一致するか» だけを見る
        guard !trimmed.isEmpty, text.range(of: trimmed, options: .caseInsensitive) != nil else {
            return Text(text)
        }
        var parts: [Text] = []
        var searchStart = text.startIndex
        var cursor = text.startIndex
        while let found = text.range(of: trimmed, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
            if cursor < found.lowerBound {
                parts.append(Text(String(text[cursor..<found.lowerBound])))
            }
            parts.append(Text(String(text[found])).bold().foregroundColor(.orange))
            cursor = found.upperBound
            searchStart = found.upperBound
        }
        if cursor < text.endIndex {
            parts.append(Text(String(text[cursor...])))
        }
        return parts.reduce(Text(""), +)
    }
}

/// ContentUnavailableView は macOS 14+ だが、デプロイ対象 (macOS 14) で
/// タイトルと説明の 2 引数版が使える。将来 iOS 流の API に寄せやすくするため
/// 名前を固定した小さなラッパにしている
private struct ContentUnavailableCompat: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
