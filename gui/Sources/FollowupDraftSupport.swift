import Foundation
import KildeCore

/// フォローアップの下書き (issue #464 — 第二弾 Pro) の GUI 側の下準備。
/// ライブラリの録画から «フォローアップを下書き» ボタンの表示・有効条件と
/// 下書きのコピー全文を組み立てる。**FoundationModels を呼ばない純粋なロジック
/// だけを置く** (セルフテスト KILDE_GUI_SELFTEST_FOLLOWUP の対象 —
/// モデル呼び出しは FollowupDraftSheet の Task が担う)
enum FollowupDraftSupport {

    /// ライブラリの 1 録画の、下書きの入力 (議事録 .md) の状態
    enum MinutesDoc: Equatable {
        /// 議事録 (.md) が無い — ボタンを出さない。要約は .md にしか載らない
        /// (TranscriptWriter の契約) ため、他形式のサイドカーでは機能が成り立たない
        case notMinutes
        /// .md はあるが «## 要約» 節が無い (要約なしで .md を書き出した場合) —
        /// ボタンは出すが無効にする («録画後に要約も作る» で要約を作れることに案内)
        case noSummary
        /// 要約がある — 生成できる
        case summary(MeetingSummary)
    }

    /// サイドカーから要約を復元する。エンジンの往復解析
    /// (`TranscriptFormatter.parseSummary` — kilde-cli-swift#137) を使う。
    /// 要約節が無い・項目がすべて空は «要約が無い» 扱い
    static func loadMinutesDoc(sidecarURL: URL?) -> MinutesDoc {
        guard let url = sidecarURL,
              url.pathExtension.lowercased()
                == TranscriptOutputFormat.markdown.fileExtension
        else { return .notMinutes }
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let summary = TranscriptFormatter.parseSummary(fromMarkdown: raw)
        else { return .noSummary }
        return summary.isEmpty ? .noSummary : .summary(summary)
    }

    /// ボタンの有効条件。理由の優先順位は «議事録を作成« ボタン (LibraryWindow) と
    /// 同じ «環境が使えない → Pro» — 環境がダメなら買っても使えないため先に案内する
    static func isButtonEnabled(
        doc: MinutesDoc,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> Bool {
        guard case .summary = doc else { return false }
        return appleIntelligenceUnavailableReason == nil && proAllows
    }

    /// ボタン・無効理由のツールチップ (議事録を作成ボタンと同じ «控えめ» 方針 —
    /// 購入導線は設定パネルにしか置かない)
    static func buttonTooltip(
        doc: MinutesDoc,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> String {
        if let reason = appleIntelligenceUnavailableReason {
            return String(localized: "フォローアップの下書きには Apple Intelligence が必要です: \(reason)")
        }
        if !proAllows {
            return String(localized: "フォローアップの下書きは Pro の機能です (設定パネルから購入できます)")
        }
        switch doc {
        case .summary:
            return String(localized: "議事録の要約から、参加者へ送るメッセージの下書きを生成します")
        case .noSummary:
            return String(localized: "この議事録には要約がありません (録画後に要約を作ると使えます)")
        case .notMinutes:
            return String(localized: "フォローアップの下書きには要約つきの議事録 (.md) が必要です")
        }
    }

    /// 下書きをクリップボードへコピーする全文。メールは件名を 1 行目に置き空行を
    /// 1 つ挟んで本文を続ける (件名欄と本文欄への貼り分けはできないため、全文を
    /// 1 つのテキストにまとめる)。チャットは本文のみ
    static func clipboardText(for draft: FollowupDraft) -> String {
        guard let subject = draft.subject, !subject.isEmpty else { return draft.body }
        return subject + "\n\n" + draft.body
    }
}
