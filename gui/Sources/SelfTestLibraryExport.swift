import Foundation
import KildeCore

/// 録画ライブラリの «テキストに書き出す» (issue #329) の UI 無し検証。
/// 一時ディレクトリに **5 形式 (md / json / srt / vtt / txt) のサイドカー** を
/// エンジンの TranscriptWriter で書き (実経路 — «録画後に文字起こし» と同じ)、「
/// 走査 → 書き出しテキストの生成 → ファイルへの書き込み」を確かめる。
/// 保存パネルは出さない (UI を伴う経路は手動確認) — パネルまでの純粋変換と、
/// パネルで確定した後の書き込みの経路を検証する。
/// 実録画を伴わないため、録画のスロット (画面収録・マイクの権限、スピーカー) を占有しない
///
/// 使い方: `KILDE_GUI_SELFTEST_LIBRARY_EXPORT=1 <GUI>` (AppDelegate.runIfRequested から配線)
@MainActor
enum SelfTestLibraryExport {

    private static var failures = 0

    /// 合成する文字起こし。書き出しの期待値は txt 形式 («[HH:MM:SS] 本文» の行)。
    /// 秒に端数を含めない — TranscriptFormatter の txt は時刻を切り捨てで書くため、
    /// 端数があると «書き出しテキストの時刻» と «元のセグメントの時刻» が一致しない。
    /// srt / vtt の cue は常に小数 3 桁だが parseClock が経過秒へ戻すので影響しない
    private static let segments: [TranscriptSegment] = [
        TranscriptSegment(start: 10, end: 19, text: "会議の冒頭のあいさつ"),
        TranscriptSegment(start: 20, end: 30, text: "締めのことば"),
    ]
    /// «[HH:MM:SS] 本文» の 1 行 = 1 セグメント + 末尾の改行 (TranscriptFormatter.plainText の契約)
    private static let expectedExport = "[00:00:10] 会議の冒頭のあいさつ\n[00:00:20] 締めのことば\n"

    /// 合成する 5 形式。md は «議事録» (要約付き) も兼ねる — 要約が書き出しテキストに
    /// 混ざらないことを見るため
    private static let formats: [TranscriptOutputFormat] = [.markdown, .json, .srt, .vtt, .txt]

    static func run() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-export failed to create temp dir: \(error)")
            exit(1)
        }

        writeSyntheticRecordings(into: directory)
        let entries = LibraryStore.scan(directory: directory)
        check(entries.count == formats.count,
              "録画 \(formats.count) 件を走査できる (実際 \(entries.count) 件)")

        for entry in entries {
            let format = entry.transcriptURL?.pathExtension ?? "?"
            guard let segments = entry.segments, segments.count == Self.segments.count else {
                check(false, "\(format) のパース (\(entry.segments?.count ?? -1) セグメント)")
                continue
            }
            // 受け入れ条件: どの形式のサイドカーからも同じ txt 形式で書き出せる
            check(LibraryTranscriptExport.plainText(segments) == expectedExport,
                  "\(format) から txt 形式を生成できる")
            // 受け入れ条件: 既定のファイル名は録画のベース名 + .txt
            let stem = entry.recordingURL.deletingPathExtension().lastPathComponent
            check(LibraryTranscriptExport.defaultFileName(for: entry) == "\(stem).txt",
                  "\(format) の既定のファイル名 (\(LibraryTranscriptExport.defaultFileName(for: entry)))")
        }

        // パネルで保存先が確定した後の書き込み。原子的に書け、内容が生成テキストと一致する。
        // 一時ディレクトリは security scope の対象でないため、start の false 戻り (非スコープ)
        // の経路もここで通る
        do {
            let destination = directory.appendingPathComponent("exported.txt")
            try LibraryTranscriptExport.write(text: expectedExport, to: destination)
            check(try String(contentsOf: destination, encoding: .utf8) == expectedExport,
                  "書き込んだファイルが生成テキストと一致する")
        } catch {
            check(false, "ファイルへの書き込み (\(error))")
        }

        print("selftest: library-export failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 5 形式の録画 (本体 0 バイト) とサイドカーを書く。サイドカーは
    /// TranscriptWriter.write — «録画後に文字起こし» の完了が書くのと同じ経路にする。
    /// md だけ要約 («議事録» — TranscriptionCoordinator が .md に強制する形) を添える
    private static func writeSyntheticRecordings(into directory: URL) {
        let summary = MeetingSummary(
            points: ["合成テスト用の要点"],
            decisions: [],
            actions: [])
        for (offset, format) in formats.enumerated() {
            let stamp = String(format: "20270101-0000%02d", offset)
            let recording = directory.appendingPathComponent("kilde-\(stamp).mov")
            FileManager.default.createFile(atPath: recording.path, contents: Data())
            do {
                _ = try TranscriptWriter.write(
                    segments, as: format, besideRecording: recording,
                    summary: format == .markdown ? summary : nil)
            } catch {
                print("selftest: library-export failed to write sidecar \(format): \(error)")
                exit(1)
            }
        }
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: library-export OK: \(label)")
        } else {
            failures += 1
            print("selftest: library-export FAIL: \(label)")
        }
    }
}
