import AppKit
import SwiftUI
import AVKit
import Combine

/// ライブラリウィンドウが閉じたことを再生に知らせる。
/// ウィンドウを閉じても LibraryView と player は生き続ける (isReleasedWhenClosed=false) ため、
/// 閉じたら必ず pause する必要がある
extension Notification.Name {
    static let kildeLibraryWindowDidClose = Notification.Name("kildeLibraryWindowDidClose")
}

/// 録画ライブラリのウィンドウ (issue #165)。
/// このアプリは LSUIElement (.accessory) で動くため、普通のウィンドウを
/// orderFront しても Dock に出ず前面に来ない。ウィンドウを出している間だけ
/// .regular に切り替え、閉じたら .accessory に戻す — 切替はこのクラスに集約する
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {

    private let store: LibraryStore
    private var window: NSWindow?

    init(store: LibraryStore) {
        self.store = store
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
            rootView: LibraryView(store: store))
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
/// 絞り込み、セグメント行クリックで該当時刻へ飛ぶ
struct LibraryView: View {
    @ObservedObject var store: LibraryStore
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
                        LibraryEntryRow(entry: entry, hitCount: searching ? hitCounts[entry.id] : nil)
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
                              hits: hits(for: entry), playback: playback)
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

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
                if entry.segments == nil {
                    Text(String(localized: "文字起こしなし"))
                        .foregroundStyle(.tertiary)
                }
                if let hitCount {
                    Text(String(localized: "\(hitCount) 件ヒット"))
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 選択中の録画の詳細。上にプレイヤー、下に文字起こしのセグメント列。
/// セグメント行クリックで該当時刻へシークして再生する (issue #165 の受け入れ条件)。
/// 検索語があるときはヒットしたセグメントだけを表示し、ヒット箇所をハイライトする
private struct LibraryDetailView: View {
    let entry: LibraryEntry
    let query: String
    let hits: [LibrarySearchHit]
    @ObservedObject var playback: LibraryPlayerController

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
                ContentUnavailableCompat(
                    title: String(localized: "文字起こしがありません"),
                    detail: String(localized: "この録画には文字起こしサイドカーがありません。録画パネルから文字起こしを実行すると表示されます"))
                Spacer()
            } else {
                segmentList
            }
        }
        .onAppear { playback.prepare(url: entry.recordingURL) }
        .onChange(of: entry.id) { _, newURL in
            // 録画が切り替わったらプレイヤーを差し替える (prepare は同じ URL では何もしない)
            playback.prepare(url: newURL)
        }
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
        guard !trimmed.isEmpty, let first = text.range(of: trimmed, options: .caseInsensitive) else {
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
