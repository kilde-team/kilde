import Foundation

/// 録画ライブラリ (issue #165) の UI 無し検証。
/// 一時ディレクトリに **合成した文字起こしサイドカー 100 件** を書き、
/// «索引構築 + 検索» の実測時間と正しさ (ヒット数・位置・大文字小文字・日本語) を確かめる。
/// issue の受け入れ条件 «100 件の文字起こしから 1 秒以内に検索» をコマンドラインから
/// 証明するためのセルフテスト。実録画を伴わないため、録画のスロット
/// (画面収録・マイクの権限、スピーカー) を占有しない — 並行する録画テストと同時に回せる
///
/// 使い方: `KILDE_GUI_SELFTEST_LIBRARY_SEARCH=1 <GUI>` (AppDelegate.runIfRequested から配線)
@MainActor
enum SelfTestLibrarySearch {

    private static var failures = 0

    /// 合成に使うセグメント数 (検証の見取り図):
    /// - セグメント 0: «Meeting notes for recording I» — «meeting notes» で全 100 件ヒット
    /// - セグメント 3: entry 42 のみ «ユニークキーワード42 …» — 1 件ヒット + 時刻一致の検証
    /// - セグメント 7: entry 0〜19 のみ «予算 discussion …» — 20 件ヒット + 日本語 2-gram
    private static let segmentCount = 10
    private static let entryCount = 100
    private static let secondsPerSegment: TimeInterval = 10

    static func run() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("selftest: library failed to create temp dir: \(error)")
            exit(1)
        }
        writeSyntheticSidecars(into: directory)

        // 索引構築 (走査 + パース + 2-gram 索引) の実測。LibraryStore.reload と同じ
        // «scan → LibraryIndex» の経路を通す
        let buildStart = Date()
        let entries = LibraryStore.scan(directory: directory)
        let index = LibraryIndex(entries: entries)
        let buildElapsed = -buildStart.timeIntervalSinceNow

        let searchStart = Date()
        let _ = index.search("meeting notes")
        let searchElapsed = -searchStart.timeIntervalSinceNow

        print("selftest: library entries=\(entries.count) build=\(String(format: "%.3f", buildElapsed))s search=\(String(format: "%.3f", searchElapsed))s")

        // 受け入れ条件: 100 件から 1 秒以内。構築と検索を別々に判定する
        check(buildElapsed < 1.0, "索引構築が 1 秒以内 (\(String(format: "%.3f", buildElapsed))s)")
        check(searchElapsed < 1.0, "検索が 1 秒以内 (\(String(format: "%.3f", searchElapsed))s)")
        check(entries.count == entryCount, "録画 100 件を走査できる (実際 \(entries.count) 件)")

        // 新しい順 (recordedAt 降順) であること。合成は timestamp が後の録画ほど新しい
        for pair in zip(entries, entries.dropFirst()) {
            if pair.0.recordedAt < pair.1.recordedAt {
                check(false, "一覧が新しい順 \(pair.0.recordedAt) < \(pair.1.recordedAt)")
                break
            }
        }
        // 既定名 kilde-yyyyMMdd-HHmmss からの日時解析を検証する
        // (解析と合成を同じ DateFormatter 設定で行い、文字列で照合する)。
        // entries[0] は «新しい順» の先頭 = 合成で最も新しい entryCount - 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // entries.first でガードする — 空配列の entries[0] は trap して
        // exit(failures) を通らず、FAIL を出さずにクラッシュする
        if let newest = entries.first {
            check(formatter.string(from: newest.recordedAt) == stamp(forEntry: entryCount - 1),
                  "録画日時が既定名から解析される (\(formatter.string(from: newest.recordedAt)))")
        } else {
            check(false, "録画日時が既定名から解析される (entries が空)")
        }

        // 形式別パース: 5 形式すべてでセグメント 10 件が読め、開始時刻も正しい。
        // 開始時刻の検証をすべての形式に広げる — «ヒットの時刻» 検証が entry 42 (md)
        // の 1 件だけだと、json/srt/vtt/txt パーサの «時刻を経過秒に戻す» 経路の
        // 回帰を見逃す。形式ごとに時刻の書き方が違うため全 entry を見る。
        // **return で抜けない** — 失敗があっても記録して最後の exit(failures) に流す
        // (run() を return すると exit せずイベントループに戻り、プロセスが生き続ける)
        var parseFailures = 0
        var startFailures = 0
        for entry in entries {
            guard let segments = entry.segments, segments.count == segmentCount else {
                parseFailures += 1
                print("selftest: library PARSE \(entry.id.lastPathComponent) segments=\(entry.segments?.count ?? -1)")
                continue
            }
            for (offset, segment) in segments.enumerated()
            where segment.start != TimeInterval(offset) * secondsPerSegment {
                startFailures += 1
                print("selftest: library START \(entry.id.lastPathComponent) seg=\(offset) start=\(segment.start)")
            }
        }
        check(parseFailures == 0, "全形式 (md/json/srt/vtt/txt) のパース (\(parseFailures) 件の失敗)")
        check(startFailures == 0, "全形式のセグメント開始時刻が経過秒 (\(startFailures) 件の不一致)")

        // «予算»: 合成 entry 0〜19 のセグメント 7 だけに書いた日本語。
        // LibrarySearchHit.entryIndex は entries 配列 (新しい順) 上の index なので、
        // 合成の古い順番号は entriesIndex(ofEntry:) で写像して比較する
        let budget = index.search("予算")
        check(budget.count == 20, "«予算» が 20 件ヒット (実際 \(budget.count) 件)")
        check(budget.allSatisfy { (0..<20).contains(entry(of: $0.entryIndex)) },
              "«予算» のヒットが合成 entry 0〜19 (実際 合成 \(Set(budget.map { entry(of: $0.entryIndex) }).sorted()))")
        check(budget.allSatisfy { $0.segmentIndex == 7 },
              "«予算» のヒットがセグメント 7")

        // «ユニークキーワード42»: 合成 entry 42 のセグメント 3 だけ。開始時刻 (3 × 10 秒) も
        // あわせて検証する — «ヒット箇所から該当時刻へ飛ぶ» の元になる値
        let unique = index.search("ユニークキーワード42")
        check(unique.count == 1, "«ユニークキーワード42» が 1 件ヒット (実際 \(unique.count) 件)")
        if let hit = unique.first {
            check(hit.entryIndex == entriesIndex(ofEntry: 42),
                  "«ユニークキーワード42» が合成 entry 42 (実際 合成 \(entry(of: hit.entryIndex)))")
            check(hit.segmentIndex == 3, "«ユニークキーワード42» がセグメント 3 (実際 \(hit.segmentIndex))")
            check(hit.start == 3 * secondsPerSegment,
                  "«ユニークキーワード42» の開始時刻が 30 秒 (実際 \(hit.start))")
        }

        // 大文字小文字の同一視 (lowercased 正規化)
        let notes = index.search("meeting notes")
        check(notes.count == entryCount, "«meeting notes» が全 100 件ヒット (実際 \(notes.count) 件)")
        check(index.search("MEETING NOTES").count == entryCount,
              "«MEETING NOTES» も同数ヒット (大文字小文字を同一視)")

        // 1 文字クエリ (2-gram を作れない → 線形走査フォールバック)
        check(index.search("予").count == 20, "1 文字クエリ «予» が 20 件ヒット")

        // 取りこぼしの無さ (空クエリ・無関係語は 0 件)
        check(index.search("   ").isEmpty, "空白のみは 0 件")
        check(index.search("存在しないキーワード").isEmpty, "無関係語は 0 件")

        print("selftest: library failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 合成データ

    /// 100 件のサイドカーを書く。録画本体 (.mov) は空でも良いが
    /// «録画として認識される» 経路も通すため 0 バイトで作る (データはリポジトリに
    /// 置かず一時ディレクトリ — 検証データ非コミットの契約)
    private static func writeSyntheticSidecars(into directory: URL) {
        for entryIndex in 0..<entryCount {
            let stem = "kilde-\(stamp(forEntry: entryIndex))"
            // 5 形式を配分: md 80 / json 8 / srt 4 / vtt 4 / txt 4。
            // «最近の録画» 同様に録画本体も作る (中身は空でよい)
            let format: String
            switch entryIndex {
            case 0..<80: format = "md"
            case 80..<88: format = "json"
            case 88..<92: format = "srt"
            case 92..<96: format = "vtt"
            default: format = "txt"
            }
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("\(stem).mov").path, contents: Data())
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("\(stem).\(format)").path,
                contents: sidecar(format: format, entryIndex: entryIndex).data(using: .utf8))
        }
    }

    /// 録画名の時刻部。合成 entry 0 が最も古い (scan の新しい順ソートでは末尾に来る)。
    /// 100 秒間隔で重複しない
    private static func stamp(forEntry entryIndex: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // 解析 (LibraryStore.recordedAt) と同じローカルタイムゾーンで合成する —
        // タイムゾーンをまたぐ照合を持ち込まない
        let reference = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01T00:00:00Z
        let date = reference.addingTimeInterval(TimeInterval(entryIndex) * 100)
        return formatter.string(from: date)
    }

    /// 合成の entryIndex (古い順) → entries 配列の index (新しい順) の写像。
    /// LibrarySearchHit.entryIndex は entries 配列上の index を指すため、
    /// 期待値は合成の番号で書き、この写像で比較する
    private static func entriesIndex(ofEntry entryIndex: Int) -> Int { entryCount - 1 - entryIndex }

    /// entries 配列の index (新しい順) → 合成の entryIndex (古い順) の逆写像
    private static func entry(of entriesIndex: Int) -> Int { entryCount - 1 - entriesIndex }

    /// entryIndex の録画のセグメント列を形式別に書き出す。TranscriptFormatter の
    /// 出力と同じ形 (サイドカー仕様) にする — 実データとの食い違いを残さないため
    private static func sidecar(format: String, entryIndex: Int) -> String {
        switch format {
        case "md": return markdownSidecar(entryIndex: entryIndex)
        case "json": return jsonSidecar(entryIndex: entryIndex)
        case "srt", "vtt": return timedSidecar(format: format, entryIndex: entryIndex)
        default: return plainSidecar(entryIndex: entryIndex)
        }
    }

    private static func text(entryIndex: Int, segmentIndex: Int) -> String {
        switch segmentIndex {
        case 0:
            return "Meeting notes for recording \(entryIndex)"
        case 3 where entryIndex == 42:
            return "ユニークキーワード42 in this segment"
        case 7 where entryIndex < 20:
            return "予算 discussion for recording \(entryIndex)"
        default:
            return "レコーディング\(entryIndex) のセグメント\(segmentIndex) 検索用のフィラーです"
        }
    }

    /// HH:MM:SS (md / txt の見出し・プレフィックス用)。subsecond を付けると
    /// srt / vtt の cue 形式 (`HH:MM:SS[,|.]mmm`) になる — TranscriptFormatter は
    /// cue を常に小数 3 桁で書くため、合成も同じ形にする
    private static func clock(seconds: TimeInterval, decimal: String = ".", subsecond: Bool = false) -> String {
        let total = Int(seconds)
        let ms = Int(round((seconds - TimeInterval(total)) * 1000))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            + (subsecond ? String(format: "%@%03d", decimal, ms) : "")
    }

    private static func markdownSidecar(entryIndex: Int) -> String {
        var lines = [
            "# 文字起こし: kilde-\(stamp(forEntry: entryIndex))",
            "- 録画日時: 2027-01-01",
            "- セグメント数: \(segmentCount)",
            "",
            "## 要約",
            "合成テスト用の要約です",
            "",
        ]
        for segmentIndex in 0..<segmentCount {
            let start = TimeInterval(segmentIndex) * secondsPerSegment
            lines.append("## \(clock(seconds: start))")
            lines.append(text(entryIndex: entryIndex, segmentIndex: segmentIndex))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func jsonSidecar(entryIndex: Int) -> String {
        let segments = (0..<segmentCount).map { segmentIndex -> String in
            let start = TimeInterval(segmentIndex) * secondsPerSegment
            let end = start + secondsPerSegment - 1
            let escaped = text(entryIndex: entryIndex, segmentIndex: segmentIndex)
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"start\": \(String(format: "%.3f", start)), \"end\": \(String(format: "%.3f", end)), \"text\": \"\(escaped)\"}"
        }
        return "[\n" + segments.joined(separator: ",\n") + "\n]\n"
    }

    private static func timedSidecar(format: String, entryIndex: Int) -> String {
        // srt はカンマ小数、vtt はピリオド小数 (TranscriptFormatter と同じ)
        let decimal = format == "srt" ? "," : "."
        var lines: [String] = []
        if format == "vtt" { lines.append("WEBVTT\n") }
        for segmentIndex in 0..<segmentCount {
            let start = TimeInterval(segmentIndex) * secondsPerSegment
            let end = start + secondsPerSegment - 1
            if format == "srt" { lines.append("\(segmentIndex + 1)") }
            lines.append("\(clock(seconds: start, decimal: decimal, subsecond: true)) --> \(clock(seconds: end, decimal: decimal, subsecond: true))")
            lines.append(text(entryIndex: entryIndex, segmentIndex: segmentIndex))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func plainSidecar(entryIndex: Int) -> String {
        (0..<segmentCount).map { segmentIndex -> String in
            let start = TimeInterval(segmentIndex) * secondsPerSegment
            return "[\(clock(seconds: start))] \(text(entryIndex: entryIndex, segmentIndex: segmentIndex))"
        }.joined(separator: "\n") + "\n"
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: library OK: \(label)")
        } else {
            failures += 1
            print("selftest: library FAIL: \(label)")
        }
    }
}
