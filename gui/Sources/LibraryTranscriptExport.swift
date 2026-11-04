import AppKit
import UniformTypeIdentifiers
import KildeCore

/// ライブラリの文字起こしを持ち出す (issue #329 / #493)。
///
/// 書き出しは **ライブラリでパース済みのセグメントから生成する** — サイドカーの形式に
/// 依らず «録画全体の文字起こし» を持ち出せる (#329)。0.31.0 までは txt 固定だったが、
/// 動画プラットフォームへ字幕を上げる需要に応えて **srt / vtt を追加する** (issue #493)。
/// 生成はエンジン `TranscriptFormatter` に一本化 — «録画後に文字起こし» が
/// サイドカーを書いたときと同じ出力であり、GUI で整形を抱え込まない。
///
/// md / json は書き出し対象にしない — サイドカーが既にその形式で持っており、
/// 要約込みの議事録は録画フォルダの .md で得られる (issue #329 からの受け入れ判断を踏襲)。
/// «全文コピー» もこの enum の経路で txt と同じ整形を使う (issue #493)
@MainActor
enum LibraryTranscriptExport {

    /// 書き出せる形式 (メニューの並び順)。`TranscriptOutputFormat` の rawValue が
    /// そのまま拡張子になるため、ファイル名・計測パラメータもこの列挙に閉じる
    static let supportedFormats: [TranscriptOutputFormat] = [.txt, .srt, .vtt]

    /// ライブラリ表示中のセグメント列を指定形式へ整形する。
    /// LibrarySegment には話者ラベルが無い (LibraryTranscriptParser が捨てる) ので
    /// speaker nil の TranscriptSegment に写してエンジンの整形器に渡す —
    /// «話者の有無で出力が変わる» ことが無いように GUI 側で写像を 1 箇所に集める。
    /// `throws` はエンジン render の契約 (json のエンコード失敗)。supportedFormats の
    /// 範囲では起きないが、書き出しの失敗を黙って捨てないため throws のまま運ぶ
    static func formatted(_ segments: [LibrarySegment],
                          as format: TranscriptOutputFormat) throws -> String {
        try TranscriptFormatter.render(
            segments.map { segment in
                TranscriptSegment(start: segment.start, end: segment.end, text: segment.text)
            },
            as: format)
    }

    /// «[HH:MM:SS] 本文» の 1 行 = 1 セグメント (txt サイドカーと同じ形)。
    /// **全文コピー** (issue #493) の実体。formatted(as: .txt) と同じ出力だが
    /// throw しない — コピー経路 (パネルを持たない呼び出し) のための非 throwing 入口
    static func plainText(_ segments: [LibrarySegment]) -> String {
        TranscriptFormatter.plainText(segments.map { segment in
            TranscriptSegment(start: segment.start, end: segment.end, text: segment.text)
        })
    }

    /// 保存パネルの既定のファイル名 (`<録画のベース名>.<形式の拡張子>`)。
    /// サイドカーの既定名 (TranscriptWriter.sidecarURL) と同じベース名にする
    static func defaultFileName(for entry: LibraryEntry,
                                format: TranscriptOutputFormat) -> String {
        entry.recordingURL.deletingPathExtension().lastPathComponent
            + "." + format.fileExtension
    }

    /// 保存パネルの許可型。**パネルで拡張子を固定する** (#329 の «ユーザーが
    /// 打ち変えられない» 契約の踏襲)。
    /// txt は plainText。vtt はシステムに `org.w3.webvtt` があるが、srt には
    /// UTType の定数が無いため拡張子から動的型を作る — preferredFilenameExtension が
    /// 元の拡張子に戻るので、«ファイル形式» の表示と拡張子の強制の両方が効く
    static func contentType(for format: TranscriptOutputFormat) -> UTType {
        switch format {
        case .txt:
            return .plainText
        case .srt, .vtt:
            return UTType(filenameExtension: format.fileExtension,
                          conformingTo: .text) ?? .plainText
        default:
            // supportedFormats 外 (md / json) は書き出し入口に来ない。
            // 網羅性のための受け皿 (plainText に寄せて壊れないようにする)
            return .plainText
        }
    }

    /// 保存パネルを出し、確定したらテキストを書く。書けたら true。
    /// キャンセルは失敗に数えない (パネルを閉じただけでダイアログを出さない)。
    /// 計測 (`transcript_export`) は **書き込みが成功したときだけ** 送る —
    /// «押した» と «持ち出せた» を混ぜない (#429 の window_service と同じ
    /// «実現したこと» を数える方針)
    @discardableResult
    static func exportTranscript(of entry: LibraryEntry,
                                 as format: TranscriptOutputFormat) -> Bool {
        guard let segments = entry.segments, !segments.isEmpty else { return false }
        let panel = NSSavePanel()
        // 許可型で拡張子を固定する — ユーザーが打ち変えられない (#329 と同じ契約)
        panel.allowedContentTypes = [contentType(for: format)]
        panel.nameFieldStringValue = defaultFileName(for: entry, format: format)
        panel.title = String(localized: "文字起こしをファイルに保存")
        panel.message = String(localized:
            "表示中の文字起こし全体を保存します。検索中でも録画全体が対象です")
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            try write(text: try formatted(segments, as: format), to: destination)
            if let kind = analyticsFormat(format) {
                UsageAnalytics.transcriptExport(format: kind)
            }
            return true
        } catch {
            presentWriteFailure(error)
            return false
        }
    }

    /// テキストをクリップボードへコピーする (issue #493)。setString の失敗は
    /// 極めて稀 (ペーストボードの型登録失敗) だが、戻り値で呼び出し側に委ねる —
    /// 計測 (`transcript_copy`) はコピーが成立したときだけ送る
    static func copyToPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    /// 指定 URL へ原子的に書く («壊れたファイルを残さない» の規約 — 一時ファイル +
    /// rename)。既存ファイルの置き換えは保存パネルの «置き換える» 確認で承認済み。
    /// **保存パネルが返した URL に security-scoped API は不要** — ユーザーの選択で
    /// powerbox が既にアクセスを許可しており、App Sandbox でもそのまま書ける
    /// (cubic 指摘 — 呼ぶ必要が無いだけでなく、呼ぶと不要な extension を取る)。
    /// 保存パネル以外の入手経路 (bookmark 復元など) を書くことになったら
    /// start/stop を戻す
    static func write(text: String, to destination: URL) throws {
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// 書き出しメニューの項目ラベル。**設定パネルの «出力形式» と同じ語彙** を使う
    /// (SettingsPaneView.formatLabel と同じリテラル — String Catalog で同じ鍵に
    /// 寄るため翻訳を二重管理しない。リテラルを変えるときは両側を同時に変える)
    static func menuLabel(for format: TranscriptOutputFormat) -> String {
        switch format {
        case .markdown: return String(localized: "Markdown (.md)")
        case .srt: return String(localized: "SubRip 字幕 (.srt)")
        case .vtt: return String(localized: "WebVTT 字幕 (.vtt)")
        case .txt: return String(localized: "プレーンテキスト (.txt)")
        case .json: return String(localized: "JSON (.json)")
        }
    }

    /// 書き込みの失敗をダイアログで出す (issue #329 の受け入れ条件 «黙って失敗しない»。
    /// 生成 (formatted) の失敗も同じ経路に乗せる — 利用者からは «書けなかった» の
    /// ひとまとまりでよい)。権限の無い保存先・ディスクフル・切断した外付けボリュームなど
    private static func presentWriteFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "文字起こしを保存できませんでした")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// TranscriptOutputFormat → 計測パラメータの写像。supportedFormats のみが
    /// 入口に来るので nil にはならないが、網羅しない switch を書かないため
    /// Optional で受ける (UsageAnalytics 側の列挙は «値はこの列挙に閉じる» 規約)
    private static func analyticsFormat(
        _ format: TranscriptOutputFormat) -> UsageAnalytics.TranscriptExportFormat? {
        switch format {
        case .txt: return .txt
        case .srt: return .srt
        case .vtt: return .vtt
        default: return nil
        }
    }
}
