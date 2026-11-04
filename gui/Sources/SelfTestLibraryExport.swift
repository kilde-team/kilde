import AppKit
import Foundation
import KildeCore
import UniformTypeIdentifiers

/// 録画ライブラリの文字起こしの持ち出し (issue #329 / #493) の UI 無し検証。
/// 一時ディレクトリに **5 形式 (md / json / srt / vtt / txt) のサイドカー** を
/// エンジンの TranscriptWriter で書き (実経路 — «録画後に文字起こし» と同じ)、
/// «走査 → 各形式の書き出しテキストの生成 → ファイルへの書き込み → クリップボード»
/// を確かめる。保存パネルは出さない (UI を伴う経路は手動確認) — パネルまでの
/// 純粋変換と、パネルで確定した後の書き込みの経路を検証する。
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
    /// srt (issue #493)。SubRip の cue (番号 / `-->` はカンマ区切りのミリ秒 / 本文) を
    /// エンジンの整形器の契約どおり期待する — GUI 側の写像 (話者 nil) が入っても
    /// 出力が変わらないことを機械的に縛る。**末尾の改行は cue の連結後の契約**
    /// (srt は各 cue を空行でつなぎ最後に 1 つの改行) のためリテラルの外で付ける。
    /// こちらは **終了時刻を持つサイドカー (srt / vtt / json) 用**
    private static let expectedSRT = """
        1
        00:00:10,000 --> 00:00:19,000
        会議の冒頭のあいさつ

        2
        00:00:20,000 --> 00:00:30,000
        締めのことば
        """ + "\n"
    /// vtt (issue #493)。先頭に WEBVTT、時刻の小数点はドット。末尾の改行は srt と同じ。
    /// こちらは **終了時刻を持つサイドカー (srt / vtt / json) 用**
    private static let expectedVTT = """
        WEBVTT

        1
        00:00:10.000 --> 00:00:19.000
        会議の冒頭のあいさつ

        2
        00:00:20.000 --> 00:00:30.000
        締めのことば
        """ + "\n"
    /// 秒精度のサイドカー (txt / md) 用の srt。このパーサは **終了時刻を持たない** ため
    /// «end = 次セグメントの開始» になり、**最終セグメント (end == start) は
    /// 字幕の契約 (end > start) を満たさない** ため `minimumCueDuration` (2 秒) の
    /// 下限で補われる (LibraryEntry.duration のコメントがパーサ契約の正本)。
    /// «表示されない cue» を出さないための最小限の補正で、他の cue は
    /// サイドカー由来の値のまま
    private static let expectedSRTFromSecondPrecision = """
        1
        00:00:10,000 --> 00:00:20,000
        会議の冒頭のあいさつ

        2
        00:00:20,000 --> 00:00:22,000
        締めのことば
        """ + "\n"
    /// 秒精度のサイドカー (txt / md) 用の vtt (expectedSRTFromSecondPrecision と同理由)
    private static let expectedVTTFromSecondPrecision = """
        WEBVTT

        1
        00:00:10.000 --> 00:00:20.000
        会議の冒頭のあいさつ

        2
        00:00:20.000 --> 00:00:22.000
        締めのことば
        """ + "\n"

    /// 合成する 5 形式。md は «議事録» (要約付き) も兼ねる — 要約が書き出しテキストに
    /// 混ざらないことを見るため
    private static let formats: [TranscriptOutputFormat] = [.markdown, .json, .srt, .vtt, .txt]

    static func run() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-export-\(UUID().uuidString)")
        // defer で消さない — run() は必ず exit() で終わるため defer は一度も走らず、
        // 一時ディレクトリが残る (cubic 指摘)。exit の前に明示的に消す
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-export failed to create temp dir: \(error)")
            try? FileManager.default.removeItem(at: directory)
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
            // 終了時刻をサイドカーが持つか (持たない txt / md は «end = 次の開始» の
            // パーサ契約に従う — expectedSRTFromSecondPrecision のコメントが正本)
            let carriesEndTimes = (entry.transcriptURL?.pathExtension).map {
                ["srt", "vtt", "json"].contains($0)
            } ?? false
            let expectedSRT = carriesEndTimes ? Self.expectedSRT : Self.expectedSRTFromSecondPrecision
            let expectedVTT = carriesEndTimes ? Self.expectedVTT : Self.expectedVTTFromSecondPrecision
            // 受け入れ条件: どの形式のサイドカーからも同じ txt 形式で書き出せる
            check(LibraryTranscriptExport.plainText(segments) == expectedExport,
                  "\(format) から txt 形式を生成できる")
            // 受け入れ条件 (issue #493): srt / vtt はエンジンの整形器の契約どおり。
            // どのサイドカー形式から始めても同じ出力になる («パース済みセグメントから
            // 生成する» 契約の確認)
            check((try? LibraryTranscriptExport.formatted(segments, as: .srt)) == expectedSRT,
                  "\(format) から srt 形式を生成できる")
            check((try? LibraryTranscriptExport.formatted(segments, as: .vtt)) == expectedVTT,
                  "\(format) から vtt 形式を生成できる")
            // 受け入れ条件 (issue #493): 既定のファイル名は録画のベース名 + 形式の拡張子
            let stem = entry.recordingURL.deletingPathExtension().lastPathComponent
            let fileName = LibraryTranscriptExport.defaultFileName(for: entry, format: .srt)
            check(fileName == "\(stem).srt",
                  "\(format) の既定のファイル名 (\(fileName))")
        }

        // 受け入れ条件 (issue #493): 保存パネルの許可型が形式の拡張子に対応する。
        // srt は UTType の定数が無い (動的型) ため、preferredFilenameExtension が
        // 元の拡張子に戻ることまで確かめる («パネルで拡張子を固定する» 契約)
        for format in LibraryTranscriptExport.supportedFormats {
            let type = LibraryTranscriptExport.contentType(for: format)
            check(type.preferredFilenameExtension == format.fileExtension,
                  "\(format.fileExtension) の許可型が拡張子に対応する (\(type.identifier))")
        }

        // パネルで保存先が確定した後の書き込み。原子的に書け、内容が生成テキストと一致する。
        // 保存パネルの URL は powerbox が既にアクセスを許しているため、
        // 一時ディレクトリ (スコープ外) も同じ write の経路で書ける
        do {
            let destination = directory.appendingPathComponent("exported.txt")
            try LibraryTranscriptExport.write(text: expectedExport, to: destination)
            check(try String(contentsOf: destination, encoding: .utf8) == expectedExport,
                  "書き込んだファイルが生成テキストと一致する")
            // srt も同じ書き込み経路を通る (形式ごとの分岐は生成だけ)
            let subtitleDestination = directory.appendingPathComponent("exported.srt")
            try LibraryTranscriptExport.write(text: expectedSRT, to: subtitleDestination)
            check(try String(contentsOf: subtitleDestination, encoding: .utf8) == expectedSRT,
                  "srt の書き込みが生成テキストと一致する")
        } catch {
            check(false, "ファイルへの書き込み (\(error))")
        }

        // 受け入れ条件 (issue #493): «全文をコピー» の経路。クリップボードは
        // セルフテスト実行者のものを上書きする (1 回だけ — 検証のための許容)。
        // 計測は呼び出し側 (LibraryWindow) が送るため、ここではペーストボードの
        // 登録が通ることだけを見る
        if LibraryTranscriptExport.copyToPasteboard(expectedExport) {
            check(NSPasteboard.general.string(forType: .string) == expectedExport,
                  "クリップボードへのコピーが生成テキストと一致する")
        } else {
            check(false, "クリップボードへのコピー (setString が失敗)")
        }

        try? FileManager.default.removeItem(at: directory)
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
                try? FileManager.default.removeItem(at: directory)
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
