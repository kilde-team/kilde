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
    /// 話者ラベル (issue #566)。サイドカーに話者の書かれた録画 (トラック別文字起こしの
    /// «自分» / «相手» — エンジン SpeakerLabel、TranscriptFormatter が書く形式) でのみ
    /// 非 nil。話者の無い従来録画は従来どおり nil (後方互換)。初期値 nil を付けた
    /// **明示的な init** にするのは、既存の呼び出し (`LibrarySegment(start:end:text:)`)
    /// を変えずに済ませるため — メンバー毎 init に Optional を足すと全呼び出し箇所の
    /// 修正が要るが、話者の有無はパース結果で決まるので呼び出し側に波及させない
    let speaker: String?

    init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
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

    /// TranscriptionCoordinator が KildeCore.TranscriptSegment を書く。speaker も
    /// 受ける (issue #566) — TranscriptSegment の Codable 契約では speaker は
    /// **非 nil のときだけキーが出る**ため、Optional で受ければ «キーが無い»
    /// 従来の json は nil になる (後方互換。未定義キーは Decodable が無視する)
    private struct JSONSegment: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let speaker: String?
    }

    private static func parseJSON(_ raw: String) -> [LibrarySegment]? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([JSONSegment].self, from: data) else { return nil }
        return decoded.map { LibrarySegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
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
            // 話者は cue 本文の **1 行目**に «話者: » の形でしか付かない
            // (TranscriptFormatter.cueText が `"\(speaker): " + text` を書く契約)。
            // 1 行目から切り出して残りを本文にする — 話者を本文に残すと
            // «質問する» / «翻訳» の写像で speaker を別に渡せず、エンジンの
            // プロンプト行 «[時刻] 話者: 本文» でラベルが 2 重になる (issue #566)
            let head = bodyLines.first.map(Self.splitSpeakerPrefix)
            let body = ([head?.body ?? ""] + bodyLines.dropFirst())
                .joined(separator: " ")
            segments.append(LibrarySegment(
                start: segment.start, end: segment.end,
                text: body, speaker: head?.speaker))
        }
        pending = nil
        bodyLines = []
    }

    /// «話者: 本文» の接頭辞を切り出す (issue #566)。TranscriptFormatter が話者を
    /// `"\(speaker): "` の **1 回だけ**本文の先頭に付ける契約のため、
    /// **最初の `": "`** で分割する。話者の無い行は `(nil, 行全体)` を返す。
    /// 既知の限界: 本文自体が «語: » で始まる従来サイドカー (話者なし) は、
    /// この形式では «話者» と区別できないため話者付きに読める —
    /// 書き出し側の契約 (話者は先頭に 1 回だけ) をパース側がそのまま写した結果。
    /// エンジンのラベル («自分» / «相手») は `: ` を含まないため実害はない
    static func splitSpeakerPrefix(_ line: String) -> (speaker: String?, body: String) {
        guard let colon = line.range(of: ": ") else { return (nil, line) }
        let speaker = String(line[line.startIndex..<colon.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return (nil, line) }
        return (speaker, String(line[colon.upperBound...]))
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
    /// 話者は時刻の直後の本文から «話者: » の接頭辞を切り出して復元する (issue #566)。
    /// 話者の無い行は従来どおり nil
    private static func parsePlain(lines: [String]) -> [LibrarySegment]? {
        var parsed: [(start: TimeInterval, text: String, speaker: String?)] = []
        for line in lines {
            // .whitespacesAndNewlines: CRLF ファイルで行末の \r が本文に残るのを防ぐ (parseTimed と同じ理由)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { continue }
            guard let start = parseClock(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) else { continue }
            let whole = trimmed[trimmed.index(after: close)...].drop(while: { $0.isWhitespace })
            let (speaker, body) = Self.splitSpeakerPrefix(String(whole))
            parsed.append((start, body, speaker))
        }
        guard !parsed.isEmpty else { return nil }
        return parsed.enumerated().map { offset, item in
            // end は「次セグメントの開始」を入れる (txt に終了時刻は無い)。最後は start のまま
            let end = offset + 1 < parsed.count ? parsed[offset + 1].start : item.start
            return LibrarySegment(start: item.start, end: end, text: item.text, speaker: item.speaker)
        }
    }

    // MARK: - md (## HH:MM:SS 見出し + 本文)

    /// TranscriptFormatter.markdown の `## HH:MM:SS` (話者付きなら `## HH:MM:SS 話者` —
    /// エンジンが `clock + " " + speaker` を書くため、括弧は付かない)
    /// をセグメント見出しとして読む。`## 要約` (issue #163) は時刻が取れないため無視する
    private static func parseMarkdown(lines: [String]) -> [LibrarySegment]? {
        var starts: [TimeInterval] = []
        var texts: [String] = []
        var speakers: [String?] = []
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
                // 最初のトークンだけを時刻とし、**残り全体**を話者にする (issue #566) —
                // 話者ラベル自体に空白が入っても切り捨てないため。
                // maxSplits: 1 で «時刻以降» を 1 つの部分文字列として受け取る
                let rest = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let tokens = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard let token = tokens.first, let start = parseClock(token) else { continue }
                let speaker = tokens.count > 1
                    ? tokens[1].trimmingCharacters(in: .whitespaces)
                    : ""
                starts.append(start)
                texts.append("")
                speakers.append(speaker.isEmpty ? nil : speaker)
            } else if !starts.isEmpty, !trimmed.isEmpty {
                // 見出し前の前置き (「# 文字起こし: …」「- 録画日時: …」) は starts が空なので無視される
                currentBody.append(trimmed)
            }
        }
        if !currentBody.isEmpty { texts[texts.count - 1] = currentBody.joined(separator: " ") }
        guard !starts.isEmpty else { return nil }
        return zip(starts, texts).enumerated().map { offset, pair in
            let end = offset + 1 < starts.count ? starts[offset + 1] : pair.0
            return LibrarySegment(start: pair.0, end: end, text: pair.1, speaker: speakers[offset])
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
        let scan = Task.detached { () -> ([LibraryEntry], LibraryIndex)? in
            // 走査が失敗した (nil) ときは «一覧も索引も Spotlight も更新しない» —
            // nil を空と誤認すると «読めなかったフォルダの索引を全削除» する
            // (CodeRabbit レビュー指摘)。一時的な失敗は次回の reload で再試行される
            guard let scanned = Self.scan(directory: directory) else { return nil }
            let index = LibraryIndex(entries: scanned)
            return (scanned, index)
        }
        Task { [weak self] in
            // **先に await してから世代を見る** (cubic レビュー指摘)。«await より前に
            // 世代を見る» と、«await 中に新しい reload が走った» ケースを拾えず、
            // 古い走査結果が新しい一覧を上書きしてしまう (reload は世代を «呼ばれた瞬間»
            // に進めるため、古い Task の guard はその後に通ってしまう)
            let result = await scan.value
            guard let self, currentGeneration == self.generation else { return }
            guard let (scanned, index) = result else {
                // 走査の失敗。一覧は «走査を始める前に空にした» まま (誤って
                // 旧ディレクトリの一覧を残さない — reload のコメント参照)。
                // isScanning を下ろして «読み込み中» の表示だけは終わらせる
                self.isScanning = false
                return
            }
            self.entries = scanned
            self.index = index
            self.isScanning = false
            // 走査結果を Spotlight 索引へ反映する (issue #502)。ここが «走査結果の
            // 正» が確定する唯一の場所なので配線もここ — «ライブラリを開いた» 経路の
            // 登録・更新・削除の差分はすべてこの 1 行で満たす。内部で設定トグルを
            // 見ており、オフなら何もしない。fire-and-forget (一覧の表示を Spotlight
            // の反映で遅らせない — 索引への書き込みは補助的な入口の話)
            Task { await SpotlightExporter.shared.sync(entries: scanned) }
        }
    }

    // nonisolated: LibraryStore は @MainActor だが、走査 (scan) は非分離で動くため。
    // Set<String> は Sendable なので定数の共有は安全。
    // 取り込み (issue #416) で増えた音声形式を含む — 正本は LibraryImport.importableExtensions
    // (エンジンが録る形式 + 取り込み対象)。«最近の録画« (RecordingSetup) もこの集合を見る
    nonisolated static let recordingExtensions: Set<String> = LibraryImport.importableExtensions

    /// 保存先フォルダを走査して LibraryEntry 列を作る (新しい順)。
    /// 戻り値の **nil は «ディレクトリが読めなかった»** — «空のフォルダ» ([]) と
    /// 区別するのは Spotlight への同期 (issue #502) のため: 読めないフォルダを
    /// 空と誤認すると «索引の全件削除» をしてしまう (一時的な権限の喪失など)。
    /// 一覧表示側は nil も [] と同じ «空の一覧» として扱ってよい (従来の挙動)。
    /// 一覧の対象は «kilde- 接頭辞 + LibraryImport.importableExtensions の拡張子»
    /// (エンジンが録る mov/mp4/m4a に、取り込み (issue #416) の音声形式を足した
    /// 集合)。サイドカーの対応付けは RecordingSetup.transcriptSidecar と同じ規則 —
    /// «最近の録画» に出るものは必ずライブラリにも出る
    nonisolated static func scan(directory: URL) -> [LibraryEntry]? {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let all = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
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
            // URL は走査結果 (contentsOfDirectory) の表記をそのまま載せる (issue #416)。
            // 取り込み (LibraryImport.performImport) もコピー先をこの表記で組むため、
            // 取り込み直後の選択・処理中表示が entry.id と一致する。**symlink 解決で
            // 表記を書き換えない** — security-scoped bookmark の表記と食うため
            // (LibraryImport.isSameFile のコメント)
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
        // カレンダー連携 (issue #393) の題名接尾辞 `kilde-<時刻>-<題名>` にも対応する —
        // タイムスタンプ部 (15 文字) だけを取り出す。取り出した部分が日付として
        // 解析できなければ (別名録画 `-o` 等) 従来どおり更新日時で代用する
        let stamp = String(stem.dropFirst("kilde-".count).prefix("yyyyMMdd-HHmmss".count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: stamp) ?? fallback
    }
}
