import AppKit
import SwiftUI
import AVKit
import Combine
import KildeCore

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
    /// Apple Intelligence が使えない理由。nil は «使える» — «議事録を作成» の
    /// 可否判定と、押せないときの説明 (ツールチップ) に使う
    let summaryUnsupportedReason: String?
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
    /// «議事録を作成» のときに押された時点のパネル設定を読む。クロージャが
    /// RecordingSetup だけを捕まえる (AppDelegate を捕まえない) ため、
    /// ライブラリウィンドウの寿命が AppDelegate と常に同じでも循環参照は作らない
    private let settings: () -> LibraryTranscriptionSettings
    private var window: NSWindow?

    init(store: LibraryStore,
         transcription: TranscriptionCoordinator,
         settings: @escaping () -> LibraryTranscriptionSettings) {
        self.store = store
        self.transcription = transcription
        self.settings = settings
    }

    /// ウィンドウを開く (既に開いていれば前面に出す)。directory は保存先 —
    /// 開くたびに走査し直すので、録画や文字起こしの追加が次回のオープンで反映される
    func present(fromDirectory directory: URL) {
        store.reload(directory: directory)
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
            rootView: LibraryView(store: store, transcription: transcription, settings: settings))
        self.window = window
        showAndActivate(window)
    }

    private func showAndActivate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
    let settings: () -> LibraryTranscriptionSettings
    @State private var query = ""
    @State private var results: [LibrarySearchHit] = []
    @State private var hitCounts: [URL: Int] = [:]
    @State private var selectedEntryID: URL?
    @StateObject private var playback = LibraryPlayerController()

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    }

    /// 録画ファイルがディレクトリの直下にあるか。path 文字列で比べるのは
    /// TranscriptionCoordinator.directoryBookmarkData と同じ — getpwuid 経路の URL が
    /// 末尾 «/» を持つため URL 同士の等価では false になり、symlink 解決 (サンドボックス
    /// のコンテナ内 Movies が実 ~/Movies への symlink になりうる) を先にする
    static func recordingBelongsToDirectory(_ recording: URL, _ directory: URL) -> Bool {
        recording.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
            == directory.resolvingSymlinksInPath().standardizedFileURL.path
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
        }
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
                              transcription: transcription, settings: settings)
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
    let settings: () -> LibraryTranscriptionSettings
    /// この録画の «再試行» の対象に表示する失敗。coordinator の lastFailure は
    /// «最新の 1 件» スロットで別の録画の失敗に押し出されるため (cubic 指摘)、
    /// この録画の失敗は表示側で覚える — 消えるのはこの録画の文字起こしの成功時
    /// か選択の切替時。観測の詳細は body の onChange と seedShownFailure()
    @State private var shownFailure: TranscriptionCoordinator.Failure?

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
            Divider()
            if entry.segments == nil {
                noTranscriptPane
            } else {
                segmentList
            }
        }
        .onAppear {
            playback.prepare(url: entry.recordingURL)
            seedShownFailure()
        }
        .onChange(of: entry.id) { _, newURL in
            // 録画が切り替わったらプレイヤーを差し替える (prepare は同じ URL では何もしない)。
            // 失敗表示も新しい録画のものに引き継ぎ直す (shownFailure の契約は «この録画の» 失敗)
            playback.prepare(url: newURL)
            seedShownFailure()
        }
        // coordinator の失敗スロット (lastFailure) は «最新の 1 件» — 別の録画が
        // 失敗すると押し出されるため、この録画の «再試行» を出し続けるには
        // 表示に覚えておく必要がある (cubic 指摘)。id を監視するのは Failure が
        // Equatable でないため。成功 (この録画の完了) で役目を終える
        .onChange(of: transcription.lastFailure?.id) { _, _ in
            if let failure = transcription.lastFailure,
               failure.job.recordingURL == entry.recordingURL {
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
    /// «議事録» は文字起こし + 要約で、Apple Intelligence が使えない環境では
    /// 押せず、理由をツールチップに出す (設定パネルの案内と同じ文言)
    private var actionButtons: some View {
        let snapshot = settings()
        return HStack(spacing: 12) {
            Button {
                enqueue(withSummary: false, snapshot: settings())
            } label: {
                Label(String(localized: "文字起こしを作成"), systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            Button {
                enqueue(withSummary: true, snapshot: settings())
            } label: {
                Label(String(localized: "議事録を作成"), systemImage: "waveform.badge.waveform")
            }
            .buttonStyle(.bordered)
            .disabled(snapshot.summaryUnsupportedReason != nil)
            .help(snapshot.summaryUnsupportedReason.map { reason in
                String(localized: "要約には Apple Intelligence が必要です: \(reason)")
            } ?? String(localized: "文字起こしの後に要約を生成して Markdown (.md) に載せます (テンプレートは設定パネルの選択を使います)"))
        }
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
            localeID: snapshot.localeID,
            // サイドカーが無いので録音長は不明 (nil) — 計測では長さ区分を送らない
            // (パネルの «後から文字起こし» と同じ扱い)
            recordingDuration: nil))
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !query.isEmpty {
                Text(String(localized: "ヒット \(rows.count) 件 / 全 \(entry.segments?.count ?? 0) セグメント"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            ScrollViewReader { proxy in
                List(rows) { row in
                    LibrarySegmentRow(text: row.text, query: query, start: row.start) {
                        playback.seek(to: row.start)
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
