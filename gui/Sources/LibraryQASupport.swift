import Foundation
import KildeCore

/// ライブラリ横断の検索・質問応答 (issue #547 — 第五弾 Pro) の GUI 側の下準備。
/// ライブラリウィンドウの «ライブラリに質問» ボタンの表示・有効条件と、質問欄の
/// 入力状態を組み立てる。**FoundationModels を呼ばない純粋なロジックだけを置く**
/// (セルフテスト KILDE_GUI_SELFTEST_LIBRARY_QA の対象 — モデル呼び出しは
/// LibraryQASheet の Task が担う)。TranscriptQASupport (第四弾) と同じ分け方
enum LibraryQASupport {

    /// 質問入力欄の文字数上限。エンジンの `TranscriptQA.maxQuestionLength` と同じ
    /// **500** — LibraryQA.answer も TranscriptQA.normalizeQuestion で正規化する
    /// ため、GUI の上限はこれに揃える (TranscriptQASupport.maxQuestionLength と
    /// 同じ «値を写す» 方針。ずれてもエンジン側で最終的に切り詰まる)
    static let maxQuestionLength = TranscriptQASupport.maxQuestionLength

    /// «ライブラリに質問» の有効条件。横断 QA は**書き起こしを持つ録画が
    /// 1 件でもあること**が入力の条件 (単一録画版と違い «この録画» の有無ではなく
    /// ライブラリ全体を見る)。理由の優先順位は «環境が使えない → Pro» —
    /// TranscriptQASupport.isButtonEnabled と同じ順序
    static func isButtonEnabled(
        hasTranscribedRecording: Bool,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> Bool {
        guard hasTranscribedRecording else { return false }
        return appleIntelligenceUnavailableReason == nil && proAllows
    }

    /// ボタンの無効理由のツールチップ («控えめ» 方針 — 購入導線は設定パネルに
    /// しか置かない。TranscriptQASupport.buttonTooltip と同じ流儀)
    static func buttonTooltip(
        hasTranscribedRecording: Bool,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> String {
        if let reason = appleIntelligenceUnavailableReason {
            return String(localized: "ライブラリへの質問には Apple Intelligence が必要です: \(reason)")
        }
        if !proAllows {
            return String(localized: "ライブラリへの質問は Pro の機能です (設定パネルから購入できます)")
        }
        if !hasTranscribedRecording {
            return String(localized: "ライブラリへの質問には文字起こし済みの録画が必要です («文字起こしを作成» で作れます)")
        }
        return String(localized: "ライブラリ内の複数の録画を横断して質問し、根拠つきで答えを得ます (端末内で処理します)")
    }

    /// シートの «答えを得る» ボタンの有効条件。«実質空» と再入防止の判定は
    /// TranscriptQASupport.isAskEnabled と同じ規約 — エンジンのゲート
    /// (`.libraryQAEmptyQuestion`) に届く前に UI で防ぐ
    static func isAskEnabled(question: String, isAsking: Bool) -> Bool {
        TranscriptQASupport.isAskEnabled(question: question, isAsking: isAsking)
    }

    /// 質問文の正規化。エンジンの `TranscriptQA.normalizeQuestion` と同じ規約を
    /// TranscriptQASupport が写しているのでそれを流用する — «GUI では非空なのに
    /// 空扱い» を起こさない
    static func normalizedQuestion(_ raw: String) -> String {
        TranscriptQASupport.normalizedQuestion(raw)
    }

    /// ライブラリの録画一覧 (LibraryEntry) をエンジンの `LibraryRecording` へ
    /// 写像する。**書き起こしを持つ録画だけ**を渡す — 空の録画はエンジンの選定で
    /// 除外されるが、GUI 側でも落としておくと «ライブラリ全体» の意味が
    /// 明確になる (検索・根拠の対象はあくまで文字起こし済みの録画)。
    /// ライブラリの索引 (LibrarySegment) は**話者を保持しない**ため speaker は
    /// nil (TranscriptQASheet と同じ制約 — 話者の保持は索引の拡張で別 issue)
    static func recordings(from entries: [LibraryEntry]) -> [LibraryRecording] {
        entries.compactMap { entry in
            guard let segments = entry.segments, !segments.isEmpty else { return nil }
            return LibraryRecording(
                title: entry.recordingURL.deletingPathExtension().lastPathComponent,
                recordedAt: entry.recordedAt,
                segments: segments.map {
                    TranscriptSegment(
                        start: $0.start, end: $0.end, text: $0.text, speaker: nil)
                })
        }
    }

    /// 検索欄の語をエンジンの `searchTerms` に渡す形へ正規化する (純粋関数)。
    /// «実質空» (空白のみ) は nil — «絞り込みなし» のときに空語を渡して
    /// エンジン側に無意味な照合をさせないため。複数語 (空白区切り) はそのまま
    /// 語列にする (エンジンの選定は語ごとの部分一致で採点する)
    static func searchTerms(from query: String) -> [String]? {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0) }
        return terms.isEmpty ? nil : terms
    }

    /// 回答に添える «根拠» の見出し行。エンジンの `LibraryAnswer.excerpts` は
    /// «会議名: 行» 形式で、**«見つからない» を返したときだけ空** (ライブラリ版は
    /// 短い録画でも抽出を省かない契約 — エンジンの issue #145)。空のときは
    /// 根拠セクションを出さない判断はビュー側で行う
    static func hasExcerpts(_ answer: LibraryAnswer) -> Bool {
        !answer.excerpts.isEmpty
    }

    /// 回答をクリップボードへコピーする全文。TranscriptQASupport.clipboardText と
    /// 同じ方針 (本文 + «根拠» 区切り。見出しはカタログの訳語を使う)。
    /// 根拠は «会議名: 行» の文字列をそのまま並べる
    static func clipboardText(for answer: LibraryAnswer) -> String {
        guard hasExcerpts(answer) else { return answer.text }
        return answer.text + "\n\n—\n"
            + String(localized: "根拠 (会議と行)") + ":\n"
            + answer.excerpts.joined(separator: "\n")
    }
}
