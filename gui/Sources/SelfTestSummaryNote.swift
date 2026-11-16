import Foundation
import KildeCore

/// 要約の失敗を伝える note の文言規則のセルフテスト
/// (KILDE_GUI_SELFTEST_SUMMARY_NOTE=1、issue #577)。
///
///     KILDE_GUI_SELFTEST_SUMMARY_NOTE=1 KildeGUI.app/Contents/MacOS/KildeGUI
///
/// **実録画・実文字起こし・Apple Intelligence を伴わない**
/// (KILDE_GUI_SELFTEST_TRANSCRIBE_RETRY=1 と同じ「規則を合成エラーで縛る」方式。
/// 録画のスロットを占有しない)。issue #577 («要約が失敗しても文字起こしは残るべき» —
/// kilde#575) で、要約だけの失敗をジョブの失敗にせず summaryNote («要約は生成
/// できませんでした (…)» 案内) で伝えるようになった。生成自体の失敗はモデル依存で
/// 決定的に引き起こせないため、ここでは「どんなエラーがどんな 1 行 note になるか」
/// の規則 (`TranscriptionCoordinator.summaryFailureNote(of:)`) を縛る:
/// - MeetingSummarizer.Unavailable は事前案内と同じ理由をそのまま
///   (既存の «無効な環境での案内» と文言が揃う)
/// - KilError は ja の既定文言 (description)
/// - それ以外 (Foundation Models の生エラー) は description
/// - 複数行は最初の 1 行、120 字超は «…» で打ち切り
///   (通知とライブラリの 1 行 note を壊さないため)
///
/// 全ケースが通れば終了コード 0、1 件でも外れれば 1 (SelfTestMeeting と同じ合否)。
extension SelfTest {
    @MainActor
    static func reportSummaryNoteRules() -> Never {
        struct NoteCase {
            let name: String
            let error: Error
            let expected: String
        }
        // 事前案内と同じ文言 (MeetingSummarizer.unsupportedReason の代表値)
        let unavailableReason = "Apple Intelligence が無効か、このデバイスは非対応です"
        let cases: [NoteCase] = [
            NoteCase(
                name: "Unavailable は事前案内と同じ理由をそのまま載せる",
                error: MeetingSummarizer.Unavailable(reason: unavailableReason),
                expected: unavailableReason),
            NoteCase(
                name: "KilError は ja の既定文言を載せる",
                error: KilError.failure(
                    KilError.Code.summaryEmptyTranscript, "要約する書き起こしが空です"),
                expected: "要約する書き起こしが空です"),
            NoteCase(
                name: "Foundation Models の生エラーは description を載せる",
                error: SummaryModelStubError.contextWindowSizeExceeded,
                expected: "contextWindowSizeExceeded (テスト用の生エラー)"),
            NoteCase(
                name: "複数行の生エラーは最初の 1 行に整える",
                error: SummaryModelStubError.multiline,
                expected: "1 行目の原因"),
            NoteCase(
                name: "CRLF の生エラーも最初の 1 行に整える (行末に \\r を残さない)",
                error: SummaryModelStubError.crlf,
                expected: "1 行目の原因"),
            NoteCase(
                name: "120 字を超える理由は «…» で打ち切る",
                error: SummaryModelStubError.long(String(repeating: "あ", count: 130)),
                expected: String(repeating: "あ", count: 120) + "…"),
        ]
        var failures = 0
        for noteCase in cases {
            let actual = TranscriptionCoordinator.summaryFailureNote(of: noteCase.error)
            let mark = actual == noteCase.expected ? "ok" : "FAIL"
            print("selftest: summary-note[\(mark)] \(noteCase.name)"
                + (actual == noteCase.expected ? "" : " → actual: \(actual)"))
            if actual != noteCase.expected { failures += 1 }
        }
        // «中止は note にならない» もここで確認する — 中止は catch の手前で投げ直され、
        // summaryNote は作られない (TranscriptionCoordinator 側の契約)。この関数に
        // CancellationError を渡すと生エラー扱いになるが、その経路には届かない
        print("selftest: summary-note failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}

/// Foundation Models の生エラーを想定したテスト用エラー。
/// モデル呼び出しは伴わない (description の形だけを再現する)
private enum SummaryModelStubError: Error, CustomStringConvertible {
    /// contextWindowSizeExceeded 相当 (要約のコンテキスト超過の代表)
    case contextWindowSizeExceeded
    /// 複数行の description (LF)
    case multiline
    /// 複数行の description (CRLF — Windows 由来のエラー文を想定)
    case crlf
    /// 長文の description
    case long(String)

    var description: String {
        switch self {
        case .contextWindowSizeExceeded:
            return "contextWindowSizeExceeded (テスト用の生エラー)"
        case .multiline:
            return "1 行目の原因\n2 行目の詳細\n3 行目の詳細"
        case .crlf:
            return "1 行目の原因\r\n2 行目の詳細\r\n3 行目の詳細"
        case .long(let text):
            return text
        }
    }
}
