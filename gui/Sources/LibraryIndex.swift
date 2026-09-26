import Foundation
import KildeCore

/// 録画ライブラリのデータ層 (issue #165)。
/// 録画フォルダの走査 → «録画 + 文字起こしサイドカー» の一覧を作り、
/// 日本語対応の全文検索 (2-gram 転置索引) を提供する。
/// 索引はプロセス内で完成し、**外部 (ネットワーク・ファイル) には何も送らない**
/// (issue の最重要要件)。
///
/// UI は LibraryWindow.swift、UI 無しの検証は SelfTestLibrarySearch.swift。
/// パーサと索引を UI から独立させているのは、セルフテストが NSWindow を
/// 開かずに «索引構築 + 検索» の実測時間を出せるようにするため。

/// 文字起こしの 1 セグメント。時刻は **録画開始からの経過秒** (TranscriptSegment と同じ基準)。
/// TranscriptWriter が録画タイムラインと同じ時刻でサイドカーを書くため、AVPlayer の
/// seek 先としてそのまま使える
struct LibrarySegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// ライブラリの 1 録画分。サイドカーが無い (または読めない) 録画は segments が nil —
/// 一覧には載るが検索対象外
struct LibraryEntry: Identifiable, Equatable, Sendable {
    let id: URL
    let recordingURL: URL
    let transcriptURL: URL?
    let recordedAt: Date
    let segments: [LibrarySegment]?

    /// 長さの近似。サイドカーの最後の end を使う — 正確な録画長は AVAsset の非同期
    /// ロードが必要で、一覧表示には重すぎるため。md / txt は秒精度の形式のため
    /// (パーサが次セグメントの開始を end とする) 最後のセグメントでは start と等しくなる
    var duration: TimeInterval? { segments?.last?.end }

    /// 一覧・検索ヒットの見出しに使う冒頭 1 セグメント
    var preview: String? { segments?.first?.text }
}

/// 1 セグメントの検索ヒット
struct LibrarySearchHit: Identifiable, Equatable {
    let entryIndex: Int
    let entryID: URL
    let segmentIndex: Int
    let start: TimeInterval
    let text: String

    var id: Int { entryIndex &* 1_000_000 &+ segmentIndex }
}

/// サイドカー (issue #146 の TranscriptWriter の 5 形式) をセグメント列にパースする。
/// TranscriptFormatter が «録画開始からの経過時刻 (HH:MM:SS)» で書くため、
/// ここでは HH:MM:SS[,|.mmm] を経過秒に戻すだけにする
enum LibraryTranscriptParser {

    /// 対応外・読み取り失敗・セグメント 0 件は nil («文字起こしなし» 扱い)
    static func parse(_ url: URL) -> [LibrarySegment]? {
        let ext = url.pathExtension.lowercased()
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else { return nil }
        // 空行も 1 要素として保持する — cue の区切り (srt / vtt) と md の見出し区切りで使う
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let segments: [LibrarySegment]?
        switch ext {
        case "json":
            segments = parseJSON(raw)
        case "srt", "vtt":
            segments = parseTimed(lines: lines)
        case "txt":
            segments = parsePlain(lines: lines)
        case "md":
            segments = parseMarkdown(lines: lines)
        default:
            segments = nil
        }
        guard let segments, !segments.isEmpty else { return nil }
        return segments
    }

    // MARK: - json (TranscriptSegment 配列)

    /// TranscriptionCoordinator が KildeCore.TranscriptSegment を書く。speaker 以外の
    /// start / end / text だけを取り出す (未定義キーは Decodable が無視する)
    private struct JSONSegment: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private static func parseJSON(_ raw: String) -> [LibrarySegment]? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([JSONSegment].self, from: data) else { return nil }
        return decoded.map { LibrarySegment(start: $0.start, end: $0.end, text: $0.text) }
    }

    // MARK: - srt / vtt (タイムスタンプ行 → 本文)

    /// `HH:MM:SS[,|.SSS] --> HH:MM:SS[,|.SSS]` 行を cue の始まりとして読む。
    /// srt の通し番号や vtt の WEBVTT ヘッダー・cue 設定は「--> 行を起点にする」ことで自然に無視される
    private static func parseTimed(lines: [String]) -> [LibrarySegment]? {
        var segments: [LibrarySegment] = []
        var pending: LibrarySegment?
        var bodyLines: [String] = []
        for line in lines {
            // .whitespacesAndNewlines: 外部由来の CRLF ファイルで行末の \r が本文に残るのを防ぐ
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let times = parseTimedLine(trimmed) {
                if pending != nil { flush(&segments, &pending, &bodyLines) }
                pending = times
            } else if pending != nil {
                if trimmed.isEmpty {
                    if pending != nil { flush(&segments, &pending, &bodyLines) }
                } else {
                    bodyLines.append(trimmed)
                }
            }
        }
        if pending != nil { flush(&segments, &pending, &bodyLines) }
        return segments.isEmpty ? nil : segments
    }

    private static func flush(_ segments: inout [LibrarySegment], _ pending: inout LibrarySegment?,
                              _ bodyLines: inout [String]) {
        // LibrarySegment のプロパティは let のため、本文を載せた値を新しく作る
        if let segment = pending {
            segments.append(LibrarySegment(
                start: segment.start, end: segment.end,
                text: bodyLines.joined(separator: " ")))
        }
        pending = nil
        bodyLines = []
    }

    /// `start --> end` の 1 行を分解する。右辺は vtt で cue 設定 (align:start 等) が
    /// 続くことがあるため、空白区切りの最初のトークンだけを時刻として読む
    private static func parseTimedLine(_ line: String) -> LibrarySegment? {
        guard let arrow = line.range(of: "-->") else { return nil }
        guard let start = parseClock(line[line.startIndex..<arrow.lowerBound]) else { return nil }
        let rightSide = line[arrow.upperBound...]
        let endToken = rightSide.split(whereSeparator: { $0.isWhitespace }).first ?? ""
        guard let end = parseClock(endToken) else { return nil }
        return LibrarySegment(start: start, end: end, text: "")
    }

    // MARK: - txt ([HH:MM:SS] 本文)

    /// `[HH:MM:SS] 話者: 本文` (TranscriptFormatter.plain) の 1 行 = 1 セグメント。
    /// 話者は現在 nil 固定なので捨てる
    private static func parsePlain(lines: [String]) -> [LibrarySegment]? {
        var starts: [TimeInterval] = []
        var texts: [String] = []
        for line in lines {
            // .whitespacesAndNewlines: CRLF ファイルで行末の \r が本文に残るのを防ぐ (parseTimed と同じ理由)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { continue }
            guard let start = parseClock(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) else { continue }
            let body = trimmed[trimmed.index(after: close)...].drop(while: { $0.isWhitespace })
            starts.append(start)
            texts.append(String(body))
        }
        guard !starts.isEmpty else { return nil }
        return zip(starts, texts).enumerated().map { offset, pair in
            // end は「次セグメントの開始」を入れる (txt に終了時刻は無い)。最後は start のまま
            let end = offset + 1 < starts.count ? starts[offset + 1] : pair.0
            return LibrarySegment(start: pair.0, end: end, text: pair.1)
        }
    }

    // MARK: - md (## HH:MM:SS 見出し + 本文)

    /// TranscriptFormatter.markdown の `## HH:MM:SS` (話者付きなら `## HH:MM:SS [話者]`)
    /// をセグメント見出しとして読む。`## 要約` (issue #163) は時刻が取れないため無視する
    private static func parseMarkdown(lines: [String]) -> [LibrarySegment]? {
        var starts: [TimeInterval] = []
        var texts: [String] = []
        var currentBody: [String] = []
        for line in lines {
            // .whitespacesAndNewlines: CRLF ファイルで行末の \r が本文に残るのを防ぐ (parseTimed と同じ理由)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## ") {
                // 前のセグメントがあれば本文を確定する («## 要約» が先頭にある
                // 通常の形式では、この分岐はまだ starts が空で走らない)
                if !starts.isEmpty {
                    texts[texts.count - 1] = currentBody.joined(separator: " ")
                    currentBody = []
                }
                let rest = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let token = rest.split(whereSeparator: { $0.isWhitespace }).first ?? ""
                guard let start = parseClock(token) else { continue }
                starts.append(start)
                texts.append("")
            } else if !starts.isEmpty, !trimmed.isEmpty {
                // 見出し前の前置き (「# 文字起こし: …」「- 録画日時: …」) は starts が空なので無視される
                currentBody.append(trimmed)
            }
        }
        if !currentBody.isEmpty { texts[texts.count - 1] = currentBody.joined(separator: " ") }
        guard !starts.isEmpty else { return nil }
        return zip(starts, texts).enumerated().map { offset, pair in
            let end = offset + 1 < starts.count ? starts[offset + 1] : pair.0
            return LibrarySegment(start: pair.0, end: end, text: pair.1)
        }
    }

    // MARK: - 時刻

    /// `HH:MM:SS` / `HH:MM:SS,mmm` / `HH:MM:SS.mmm` を経過秒にする。
    /// TranscriptFormatter が en_US_POSIX 固定で書くため、ローカライズは絡まない。
    /// 最初に trim する — parseTimedLine の start 側は «--> 直前の空白» を含む部分文字列
    /// で、Double は末尾空白を許さない (小数部の `?? 0` フォールバックがある srt は
    /// 耐えるが、小数の無い HH:MM:SS だけの cue は 3 番目の要素で落ちる)
    static func parseClock<S: StringProtocol>(_ text: S) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split { ":,.".contains($0) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        let milliseconds: Double = parts.count == 4 ? (Double(parts[3]) ?? 0) / 1000 : 0
        return hours * 3600 + minutes * 60 + seconds + milliseconds
    }
}

/// 全文検索の転置索引 (issue #165)。
///
/// 日本語は分かち書きしないため単語ベースの索引にできない。そこで **文字 2-gram**
/// をキーにした転置索引にする — クエリの 2-gram がすべて載るセグメントだけを
/// 候補に絞り、最後に部分文字列一致 (contains) で検証する。候補の絞り込みは
/// «どれかの 2-gram が索引に無い → 絶対に含まれない» を使うので取りこぼしが無い。
/// 1 文字のクエリは 2-gram を作れないため、素朴な線形走査に落とす (件数が少なく
/// 100 件規模では問題にならない)。
///
/// 正規化は lowercased のみ — 全角半角・カタカナひらがなの同一視はしない
/// (PR に制限として明記する)。
struct LibraryIndex {

    private struct IndexedSegment {
        let entryIndex: Int
        let segmentIndex: Int
        let start: TimeInterval
        let text: String
        let normalized: String
    }

    private let segments: [IndexedSegment]
    private let gramIndex: [String: Set<Int>]
    private let entries: [LibraryEntry]

    init(entries: [LibraryEntry]) {
        self.entries = entries
        var segments: [IndexedSegment] = []
        var grams: [String: Set<Int>] = [:]
        for (entryIndex, entry) in entries.enumerated() {
            guard let list = entry.segments else { continue }
            for (segmentIndex, segment) in list.enumerated() {
                let flat = segments.count
                let normalized = segment.text.lowercased()
                segments.append(IndexedSegment(
                    entryIndex: entryIndex, segmentIndex: segmentIndex,
                    start: segment.start, text: segment.text, normalized: normalized))
                for gram in Self.bigrams(normalized) {
                    grams[gram, default: []].insert(flat)
                }
            }
        }
        self.segments = segments
        self.gramIndex = grams
    }

    /// 文字単位 (Character) の 2-gram。String.Index の隣接ではなく Character で切るのは、
    /// 合成文字 (濁点結合・絵文字) を 1 文字として扱うため。
    /// Collection.windows(ofCount:) は swift-algorithms 由来で標準ライブラリに無いため手実装
    static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        return (0...(characters.count - 2)).map { String(characters[$0...($0 + 1)]) }
    }

    /// 空白前後の trim と大文字小文字の同一視をした上で検索する。
    /// ヒットは録画 (索引構築順 = 新しい順) → セグメント順
    func search(_ query: String) -> [LibrarySearchHit] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }

        let candidates: Set<Int>?
        if normalized.count >= 2 {
            var intersection: Set<Int>?
            for gram in Self.bigrams(normalized) {
                guard let set = gramIndex[gram] else { return [] }
                intersection = intersection.map { $0.intersection(set) } ?? set
            }
            candidates = intersection
        } else {
            candidates = nil
        }

        var hits: [LibrarySearchHit] = []
        for (flat, segment) in segments.enumerated() {
            if let candidates, !candidates.contains(flat) { continue }
            guard segment.normalized.contains(normalized) else { continue }
            guard entries.indices.contains(segment.entryIndex) else { continue }
            let entry = entries[segment.entryIndex]
            hits.append(LibrarySearchHit(
                entryIndex: segment.entryIndex, entryID: entry.id,
                segmentIndex: segment.segmentIndex, start: segment.start, text: segment.text))
        }
        return hits
    }
}

/// 録画フォルダの走査と LibraryEntry の生成 (UI 無しで使えるよう static に切り出した)。
@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var index: LibraryIndex?
    @Published private(set) var isScanning = false
    @Published private(set) var directory: URL?

    /// 走査の世代。保存先を変えて走査し直したとき、前のディレクトリ (遅いボリューム・
    /// 件数が多い) の結果が後から返って新しい結果を上書きするのを防ぐ。
    /// RecordingSetup.reloadRecentRecordings と同じ考え
    private var generation = 0

    /// 現在のディレクトリを走査して一覧と索引を組み立て直す。
    /// 走査・パース・索引構築はすべてバックグラウンド — UI を止めない
    func reload(directory: URL) {
        self.directory = directory
        generation += 1
        let currentGeneration = generation
        isScanning = true
        // 走査を始める前に空にする — 旧ディレクトリの一覧を残すと、保存先を変えた直後に
        // 存在しない (アクセスできない) 録画をクリックできてしまう
        entries = []
        index = nil
        let scan = Task.detached { () -> ([LibraryEntry], LibraryIndex) in
            let scanned = Self.scan(directory: directory)
            let index = LibraryIndex(entries: scanned)
            return (scanned, index)
        }
        Task { [weak self] in
            let (scanned, index) = await scan.value
            guard let self, currentGeneration == self.generation else { return }
            self.entries = scanned
            self.index = index
            self.isScanning = false
        }
    }

    // nonisolated: LibraryStore は @MainActor だが、走査 (scan) は非分離で動くため。
    // Set<String> は Sendable なので定数の共有は安全
    nonisolated static let recordingExtensions: Set<String> = ["mov", "mp4", "m4a"]

    /// 録画フォルダを走査して LibraryEntry 列を作る (新しい順)。
    /// 録画の判定 (kilde- 接頭辞 + mov/mp4/m4a) とサイドカーの対応付けは
    /// RecordingSetup.reloadRecentRecordings / transcriptSidecar と同じ規則に寄せる —
    /// «最近の録画» に出るものは必ずライブラリにも出る
    nonisolated static func scan(directory: URL) -> [LibraryEntry] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let all = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        let regular = all.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        // サイドカーの拡張子は TranscriptOutputFormat が持つ値 (RecordingSetup と同じ)
        let transcriptExtensions = Set(TranscriptOutputFormat.allCases.map { $0.fileExtension })
        let sidecarCandidates = regular.filter {
            transcriptExtensions.contains($0.pathExtension.lowercased())
        }
        let recordings = regular.filter { url in
            url.lastPathComponent.hasPrefix("kilde-")
                && recordingExtensions.contains(url.pathExtension.lowercased())
        }
        var results: [LibraryEntry] = []
        for recording in recordings {
            let transcript = RecordingSetup.transcriptSidecar(for: recording, among: sidecarCandidates)
            let segments = transcript.flatMap { LibraryTranscriptParser.parse($0) }
            let modified = (try? recording.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            results.append(LibraryEntry(
                id: recording, recordingURL: recording,
                transcriptURL: transcript,
                recordedAt: recordedAt(of: recording, fallback: modified),
                segments: segments))
        }
        return results.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// 録画日時。既定名 `kilde-yyyyMMdd-HHmmss` (CLI の defaultOutputName と同じ) から
    /// 解析し、別名録画 (-o) は更新日時で代用する。ロケールは en_US_POSIX 固定 —
    /// タイムスタンプはローカライズされていない数値列なので環境の言語に依存させない
    nonisolated static func recordedAt(of url: URL, fallback: Date) -> Date {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("kilde-") else { return fallback }
        let stamp = String(stem.dropFirst("kilde-".count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: stamp) ?? fallback
    }
}
