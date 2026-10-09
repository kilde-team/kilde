import AppKit
import UniformTypeIdentifiers
import KildeCore

/// ライブラリの文字起こしをテキストファイル (.txt) へ書き出す (issue #329)。
///
/// サイドカーの形式は文字起こし時の設定 (json / srt / vtt / txt / md の 5 形式) で
/// 変わるため、書き出しは **ライブラリでパース済みのセグメントから常に txt 形式を
/// 生成する** — «とりあえずテキストが欲しい» ときに形式を選ばせない。出力は
/// KildeCore `TranscriptFormatter.plainText` («録画後に文字起こし» で txt サイドカーを
/// 書いたときと同じ `[HH:MM:SS] 本文` の 1 行 = 1 セグメント)。
/// 要約 (議事録 .md の «## 要約») はセグメント列に載らないため含まない —
/// 要約込みのデータは録画フォルダの .md で得られる (issue のスコープ外)
@MainActor
enum LibraryTranscriptExport {

    /// ライブラリ表示中のセグメント列を txt 形式へ整形する。
    /// LibrarySegment には話者ラベルが無い (LibraryTranscriptParser が捨てる) ので
    /// speaker nil の TranscriptSegment に写してエンジンの整形器に渡す
    static func plainText(_ segments: [LibrarySegment]) -> String {
        TranscriptFormatter.plainText(segments.map { segment in
            TranscriptSegment(start: segment.start, end: segment.end, text: segment.text)
        })
    }

    /// 保存パネルの既定のファイル名 (`<録画のベース名>.txt`)。
    /// サイドカーの既定名 (TranscriptWriter.sidecarURL) と同じベース名にする
    static func defaultFileName(for entry: LibraryEntry) -> String {
        entry.recordingURL.deletingPathExtension().lastPathComponent + ".txt"
    }

    /// 保存パネルを出し、確定したらテキストを書く。書けたら true。
    /// キャンセルは失敗に数えない (パネルを閉じただけでダイアログを出さない)
    @discardableResult
    static func exportTranscript(of entry: LibraryEntry) -> Bool {
        guard let segments = entry.segments, !segments.isEmpty else { return false }
        let panel = NSSavePanel()
        // allowedContentTypes で拡張子を .txt に固定する — ユーザーが打ち変えられない
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultFileName(for: entry)
        panel.title = String(localized: "文字起こしをテキストファイルに保存")
        panel.message = String(localized: "表示中の文字起こし全体をテキストファイル (.txt) に保存します。検索中でも録画全体が対象です")
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            try write(text: plainText(segments), to: destination)
            return true
        } catch {
            presentWriteFailure(error)
            return false
        }
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

    /// 書き出しの失敗をダイアログで出す (issue の受け入れ条件 «黙って失敗しない»)。
    /// 権限の無い保存先・ディスクフル・切断した外付けボリュームなどが該当する
    private static func presentWriteFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "テキストファイルを保存できませんでした")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
