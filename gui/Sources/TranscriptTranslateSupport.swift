import Foundation
import KildeCore

/// 書き起こしの翻訳 (issue #564 — 第七弾 Pro / エンジン kilde-cli-swift#149) の
/// GUI 側の下準備。ライブラリの録画の «翻訳» ボタンの表示・有効条件と、
/// 翻訳先の言語の選択状態 (最後に使った言語の記憶) を組み立てる。
/// **FoundationModels を呼ばない純粋なロジックだけを置く**
/// (セルフテスト KILDE_GUI_SELFTEST_TRANSLATE の対象 — モデル呼び出しは
/// TranscriptTranslateSheet の Task が担う)。TranscriptQASupport と同じ分け方
enum TranscriptTranslateSupport {

    /// «翻訳» の有効条件。翻訳は書き起こしを必要とするため、**書き起こしの有無**
    /// が入力の条件になる。理由の優先順位は «環境が使えない → Pro» —
    /// 環境がダメなら買っても使えないため先に案内する
    /// (TranscriptQASupport.isButtonEnabled と同じ順序)
    static func isButtonEnabled(
        hasTranscript: Bool,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> Bool {
        guard hasTranscript else { return false }
        return appleIntelligenceUnavailableReason == nil && proAllows
    }

    /// ボタン・無効理由のツールチップ («質問する» «フォローアップを下書き» と
    /// 同じ «控えめ» 方針 — 購入導線は設定パネルにしか置かない)
    static func buttonTooltip(
        hasTranscript: Bool,
        appleIntelligenceUnavailableReason: String?,
        proAllows: Bool
    ) -> String {
        if let reason = appleIntelligenceUnavailableReason {
            return String(localized: "翻訳には Apple Intelligence が必要です: \(reason)")
        }
        if !proAllows {
            return String(localized: "翻訳は Pro の機能です (設定パネルから購入できます)")
        }
        if !hasTranscript {
            return String(localized: "翻訳には文字起こしが必要です («文字起こしを作成» で作れます)")
        }
        return String(localized: "録った会議の文字起こしを、選んだ言語へ翻訳します (端末内で処理します)")
    }

    /// «翻訳できる書き起こしがある» の実判定。**配列の存在だけでは不十分** —
    /// «セグメントは並んでいるが本文がすべて空» («字幕の cue だけ作られた» 索引) は
    /// 翻訳の入力にならず、ボタンを有効にすると «押した後に必ず失敗» になる。
    /// «空白でない本文が 1 つでもある» ことを持って書き起こしの存在とする
    /// (cubic レビュー指摘 — issue #564)。引数は**本文の文字列列**にする —
    /// 呼び出し側 (ライブラリの索引) が持つのは `LibrarySegment` で、
    /// エンジンの `TranscriptSegment` への写像は «質問する» と同じく
    /// `speaker: nil` になる (話者は索引に無いため。時刻表示は start から
    /// 機械的に組み立つため保持される — 話者の保持は別 issue #566)
    static func hasTranslatableTranscript(_ texts: [String]) -> Bool {
        texts.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// «最後に使った言語» の UserDefaults キー。設定パネルには置かない —
    /// «1 回設定すればよい» 機能ではなく «翻訳のたびに選ぶ» ものだが、
    /// **直前の選択が既定になっている**だけで«毎回選び直す» 操作を避ける
    /// (issue #564 のスコープ)。保存先の規約は SandboxSupport の
    /// bookmark と同じ UserDefaults (.standard) — エンジンの config.json には
    /// 汚さない (GUI 専用の選択状態であり、CLI が解釈すべき設定ではない)
    static let lastLanguageKey = "transcriptTranslationLanguage"

    /// アプリの表示言語に対応する既定の翻訳先。初回 (記憶が無いとき) だけ使う。
    /// エンジンの `TranslationLanguage` は GUI の対応ロケールと揃えた閉じた
    /// 列挙のため、対応する言語コードへの写像だけで済む。
    /// **繁体字 (zh-Hant) は «対応しないロケール» として日本語に倒す** —
    /// アプリが対応している中国語は簡体字 (zh-Hans) のみで、繁体字の利用者に
    /// 簡体字を既定として選ばせるのは «対応言語への写像» ではないため
    /// (cubic レビュー指摘 — issue #564)。その他の未対応ロケール (fr など) も
    /// 日本語に倒す — アプリの開発言語が ja で、未対応ロケールではどの言語を
    /// 既定にしても同程度に妥当なため («対応していない» を別の既定で示す
    /// 必要も無い)
    static func defaultLanguage(for locale: Locale) -> TranslationLanguage {
        switch locale.language.languageCode?.identifier {
        case "en": return .english
        case "es": return .spanish
        case "ko": return .korean
        case "zh":
            return locale.language.script?.identifier == "Hant"
                ? .japanese : .simplifiedChinese
        default: return .japanese
        }
    }

    /// 初回の翻訳先 («アプリが実際に表示に使っている言語» に対応するケース)。
    /// **`Locale.current` は使わない** — こちらは«地域設定»も反映するため、
    /// 表示言語と地域が違う利用者 (言語 en・地域 JP など) で既定がずれる
    /// (cubic レビュー指摘 — issue #564)。`Bundle.main.preferredLocalizations`
    /// は «利用者の言語設定 ∩ アプリの対応ロケール» の順序リストで、
    /// 先頭が実際に表示に使われる言語。取り得ないとき (空リスト) は
    /// アプリの開発言語 ja に倒す
    static var initialLanguage: TranslationLanguage {
        let preferred = Bundle.main.preferredLocalizations.first ?? "ja"
        return defaultLanguage(for: Locale(identifier: preferred))
    }

    /// «最後に使った言語» を取得する。記憶が無い・値が現在の列挙に無い
    /// (削除されたケースなど) ときは `fallback` に倒す。
    /// UserDefaults を引数に取るのはセルフテスト用 (隔離スイートを渡せる)。
    /// `fallback` を引数にするのは検証を**決定的**にするため — «既定に倒す» が
    /// 環境の表示言語に依存すると、セルフテストが «どの実装でも通る» 形に
    /// なってしまう (cubic レビュー指摘 — issue #564)
    static func lastLanguage(
        in defaults: UserDefaults, fallback: TranslationLanguage
    ) -> TranslationLanguage {
        if let raw = defaults.string(forKey: lastLanguageKey),
           let language = TranslationLanguage(rawValue: raw) {
            return language
        }
        return fallback
    }

    /// «最後に使った言語» を記憶する («翻訳する» の送信時に呼ぶ —
    /// «選んだ言語» を確実に次回の既定にするため。成功失敗に関係なく記憶する:
    /// «使おうとした言語» が次回も選ばれている方が再試行の操作が短いため)
    static func persistLastLanguage(
        _ language: TranslationLanguage, in defaults: UserDefaults
    ) {
        defaults.set(language.rawValue, forKey: lastLanguageKey)
    }

    /// 実行時に使う窓口 (UserDefaults.standard)。fallback は «アプリの表示言語に
    /// 対応するケース» (`initialLanguage`)
    static var lastLanguage: TranslationLanguage {
        get { lastLanguage(in: .standard, fallback: initialLanguage) }
        set { persistLastLanguage(newValue, in: .standard) }
    }
}
