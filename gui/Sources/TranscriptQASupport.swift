import Foundation
import KildeCore

/// 書き起こしの質問応答 (issue #540 — 第四弾 Pro) の GUI 側の下準備。
/// ライブラリの録画の «質問する» ボタンの表示・有効条件と、質問欄の入力状態を
/// 組み立てる。**FoundationModels を呼ばない純粋なロジックだけを置く**
/// (セルフテスト KILDE_GUI_SELFTEST_QA の対象 — モデル呼び出しは
/// TranscriptQASheet の Task が担う)。FollowupDraftSupport と同じ分け方
enum TranscriptQASupport {

    /// 質問入力欄の文字数上限。エンジンの `TranscriptQA.maxQuestionLength` と同じ
    /// **500** を GUI 側でも持つ — エンジンの定数は internal で公開 API に無いため
    /// 値を写してある。ずれても壊れない設計: GUI の値が大きい (または小さい)
    /// ときはエンジン側の `normalizeQuestion` が最終的に切り詰めるため、
    /// «GUI では入力できたのに答えられない» を UI の上限で先に防ぐことが目的
    static let maxQuestionLength = 500

    /// «質問する» の有効条件。質問応答は要約 (.md) を必要としないため、
    /// **書き起こしの有無**が入力の条件になる (フォローアップ issue #464 の
    /// `MinutesDoc` と違う点)。理由の優先順位は «環境が使えない → Pro» —
    /// 環境がダメなら買っても使えないため先に案内する
    /// (FollowupDraftSupport.isButtonEnabled と同じ順序)
    static func isButtonEnabled(
        hasTranscript: Bool,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> Bool {
        guard hasTranscript else { return false }
        return appleIntelligenceUnavailableReason == nil && proAllows
    }

    /// ボタン・無効理由のツールチップ («リマインダーへ追加» «フォローアップを
    /// 下書き» と同じ «控えめ» 方針 — 購入導線は設定パネルにしか置かない)
    static func buttonTooltip(
        hasTranscript: Bool,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> String {
        if let reason = appleIntelligenceUnavailableReason {
            return String(localized: "質問応答には Apple Intelligence が必要です: \(reason)")
        }
        if !proAllows {
            return String(localized: "質問応答は Pro の機能です (設定パネルから購入できます)")
        }
        if !hasTranscript {
            return String(localized: "質問応答には文字起こしが必要です («文字起こしを作成» で作れます)")
        }
        return String(localized: "録った会議の文字起こしについて質問して、答えを得ます (端末内で処理します)")
    }

    /// シートの «答えを得る» ボタンの有効条件。質問が «実質空» (空白のみ) のときは
    /// 押せない — エンジンのゲート (`.qaEmptyQuestion`) に届く前に UI で防ぐ
    /// (ボタンを押せるのに必ず失敗する、より «押せない» を見せる流儀)
    static func isAskEnabled(question: String, isAsking: Bool) -> Bool {
        guard !isAsking else { return false }
        return !normalizedQuestion(question).isEmpty
    }

    /// 質問文の正規化 («空白のみ = 実質空»)。前後の空白を取り除き、
    /// 上限 (`maxQuestionLength`) を超える部分を切り詰める。
    /// エンジンの `TranscriptQA.normalizeQuestion` と同じ規約 — GUI で先に
    /// 正規化しておくことで、エンジンとの往復で «GUI では非空なのに空扱い» を
    /// 起こさない
    static func normalizedQuestion(_ raw: String) -> String {
        String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxQuestionLength))
    }

    /// 回答に添える «根拠» の見出し行。エンジンの `TranscriptAnswer.excerpts` は
    /// **抽出経路 (長い書き起こし) だけ**非空 — 短い書き起こしは全体を 1 回で
    /// 見ているため根拠の抜き出しが存在しない (エンジンの契約)。空のときは
    /// 根拠セクションを出さない判断はビュー側で行う
    static func hasExcerpts(_ answer: TranscriptAnswer) -> Bool {
        !answer.excerpts.isEmpty
    }

    /// 回答をクリップボードへコピーする全文。回答本文の後に、根拠 (excerpts) が
    /// あるときだけ «根拠» の行を続ける (質問応答の答えは «どこに書いてあったか»
    /// と一緒に使われるため。貼り先での再編集は利用者側の自由 — 全文を 1 つの
    /// テキストにまとめるのは FollowupDraftSupport.clipboardText と同じ方針)。
    /// 根拠が無い (全体を直接見た短い回答) ときは本文のみ
    static func clipboardText(for answer: TranscriptAnswer) -> String {
        guard hasExcerpts(answer) else { return answer.text }
        return answer.text + "\n\n—\n" + "根拠 (文字起こしの行):\n"
            + answer.excerpts.joined(separator: "\n")
    }
}
