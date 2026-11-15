import AppKit
import Foundation
import FirebaseCore
import KildeCore

/// 書き起こしの翻訳 (issue #564 — 第七弾 Pro) の UI 無し検証。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (SelfTestTranscriptQA / SelfTestFollowup と同じ位置づけ)。確かめるのは:
/// - エンジンのゲート (kilde-cli-swift#149): 権利なしで `licenseRequired`、
///   課金対象外 (nil = CLI と同じ経路) では投げない (**空の書き起こし**を渡すため
///   モデルは呼ばない — TranscriptQAGateTests と同じ前提)
/// - `TranscriptTranslateSupport`: ボタンの可否とツールチップ、翻訳先の言語の
///   既定 (表示言語への写像) と «最後に使った言語» の記憶・復元
/// - 計測イベント (translation_*) が Firebase 未初期化で安全な no-op になること
///
/// 確かめられないのはここまで、という線引き (SelfTestTranscriptQA と同じ):
/// 実際のモデル翻訳 (Apple Intelligence が有効な実機の Release ビルドで確認する) と
/// シートの見た目 (手動確認)。
///
/// 使い方: `KILDE_GUI_SELFTEST_TRANSLATE=1 <GUI>` (SelfTest.runIfRequested から配線)。
/// `KILDE_GUI_SELFTEST_TRANSLATE_LIVE=1` を併せて指定すると、最後に実モデルでの
/// 翻訳も走らせて結果を標準出力に出す (Apple Intelligence が使える実機向け。
/// 非対応環境は SKIP して失敗に数えない)
@MainActor
enum SelfTestTranslate {

    private static var failures = 0
    private static var total = 0

    private static func check(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("selftest: translate PASS: \(label)")
        } else {
            failures += 1
            print("selftest: translate FAIL: \(label)")
        }
    }

    static func run() {
        // MainActor の実行を止めずに非同期で検証を回し、終わったら終了する
        // (SelfTestTranscriptQA と同じ — セマフォ待ちで固めない)
        Task { await runChecks() }
    }

    private static func runChecks() async {
        // 1) エンジンのゲート: 権利なし (.none) は licenseRequired。ゲートは
        //    translate の最初の分岐なので、Apple Intelligence の有無に依らず
        //    モデルを呼ばない (空の書き起こしで «ゲート直後» まで到達させる)
        check(await gateFires(for: LicenseContext(entitlement: .none)),
              "engine gate fires for .none")

        // 2) 課金対象外 (nil = CLI と同じ経路) ではゲートが発火しない
        check(await !gateFires(for: nil), "engine gate passes for nil (CLI path)")

        // 3) ボタンの可否 — 書き起こしの有無・環境 (Apple Intelligence)・
        //    Pro 権限の優先順位 («環境 → Pro» の順。TranscriptQASupport と同じ)
        check(TranscriptTranslateSupport.isButtonEnabled(
                  hasTranscript: true,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button enabled for transcript + environment + pro")
        check(!TranscriptTranslateSupport.isButtonEnabled(
                  hasTranscript: false,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button disabled without a transcript")
        check(!TranscriptTranslateSupport.isButtonEnabled(
                  hasTranscript: true,
                  appleIntelligenceUnavailableReason: nil, proAllows: false),
              "button disabled without pro")
        check(!TranscriptTranslateSupport.isButtonEnabled(
                  hasTranscript: true,
                  appleIntelligenceUnavailableReason: "Apple Intelligence が無効",
                  proAllows: true),
              "button disabled without Apple Intelligence")
        // ツールチップは «Pro あり» と «Pro なし» で別の文言になる («控えめ» 方針)
        check(
            TranscriptTranslateSupport.buttonTooltip(
                hasTranscript: true,
                appleIntelligenceUnavailableReason: nil, proAllows: false)
                != TranscriptTranslateSupport.buttonTooltip(
                    hasTranscript: true,
                    appleIntelligenceUnavailableReason: nil, proAllows: true),
            "tooltip explains the pro lock")

        // 4) 翻訳先の言語 — エンジンの TranslationLanguage (5 種) と揃っている。
        //    表示名は空でなく互いに異なる (Picker の選択肢が識別できることの契約)
        check(TranslationLanguage.allCases.count == 5,
              "translation language catalog has 5 entries")
        check(
            Set(TranslationLanguage.allCases.map(\.displayName)).count
                == TranslationLanguage.allCases.count,
            "translation language display names are distinct")

        // 5) «最後に使った言語» の記憶。**隔離スイート**の UserDefaults を使う —
        //    .standard に書くと実利用の選択状態を壊す (セルフテストが
        //    «最後に使った言語» を書き換えてはいけない)
        let suiteName = "selftest.transcript-translate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // «表示言語への写像» (`defaultLanguage(for:)` は純粋関数なので
        // ロケールを固定して決定的に検証する)。未対応ロケール (fr) と繁体字
        // (zh-Hant) は日本語に倒す («対応ロケールへの写像» ではないため)
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "ja")) == .japanese,
              "default language for ja is japanese")
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "en")) == .english,
              "default language for en is english")
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "es")) == .spanish,
              "default language for es is spanish")
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "ko")) == .korean,
              "default language for ko is korean")
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "zh-Hans")) == .simplifiedChinese,
              "default language for zh-Hans is simplified Chinese")
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "zh-Hant")) == .japanese,
              "default language for zh-Hant (unsupported) falls back to japanese")
        check(TranscriptTranslateSupport.defaultLanguage(
                  for: Locale(identifier: "fr")) == .japanese,
              "default language for an unsupported locale falls back to japanese")
        // «記憶が無いとき» は fallback (引数) に倒る — fallback を引数に取ることで
        // «どの実装でも通る» にならず、期待値を固定して検証する
        check(TranscriptTranslateSupport.lastLanguage(
                  in: defaults, fallback: .spanish) == .spanish,
              "unset language falls back to the given fallback")
        // 記憶した言語がそのまま復元される («翻訳する» の送信時の記憶)
        TranscriptTranslateSupport.persistLastLanguage(.korean, in: defaults)
        check(TranscriptTranslateSupport.lastLanguage(
                  in: defaults, fallback: .spanish) == .korean,
              "persisted language is restored")
        // 壊れた値 (削除されたケースの rawValue など) は fallback に倒る
        defaults.set("fr-CA", forKey: TranscriptTranslateSupport.lastLanguageKey)
        check(TranscriptTranslateSupport.lastLanguage(
                  in: defaults, fallback: .english) == .english,
              "stale raw value falls back to the given fallback")
        defaults.removePersistentDomain(forName: suiteName)

        // 6) 計測イベント (translation_*) は Firebase 未初期化 (セルフテスト) で
        //    呼んでも安全な no-op になること (qa_* と同じ線引き)。
        //    «未初期化» をイベント送信の**前に**表明する (SelfTestTranscriptQA と
        //    同じ順序 — 初期化が回帰したとき、セルフテストのイベントが本番
        //    Firebase に飛ぶ前に失敗を見つけるため)。初期化済みのときは
        //    «回帰の検出» で止まり、**このブロックのイベント送信は行わない** —
        //    セルフテストの no-op 検証が本番 Firebase にデータを混入させては
        //    いけないため (cubic レビュー指摘)
        if FirebaseApp.app() != nil {
            check(false, "translate analytics calls keep Firebase uninitialized")
        } else {
            check(true, "translate analytics calls keep Firebase uninitialized")
            UsageAnalytics.translationStarted()
            UsageAnalytics.translationCompleted(processingTime: nil)
            UsageAnalytics.translationFailed(
                KilError.failure(.translateEmptyTranscript, "selftest"), processingTime: nil)
            check(true, "translation_* events are safe no-ops without Firebase")
        }

        // 7) 実モデルの呼び出し (KILDE_GUI_SELFTEST_TRANSLATE_LIVE=1 のときのみ)。
        //    Apple Intelligence が使える実機で翻訳が実際に生成できることを確かめる。
        //    非対応環境は SKIP (失敗に数えない — «環境に依存しない検証を失敗に
        //    しない» 線引き)。«行構造が保たれる» (分割片の接頭辞の重複がない) 前提は
        //    エンジン側の単体テストが担保する (transcriptInputText は internal —
        //    GUI からは検証できないため kilde-cli-swift#149 のテストに委ねる)
        if ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_TRANSLATE_LIVE"] == "1" {
            await runLiveTranslation()
        }

        print("selftest: translate PASS=\(total - failures) FAIL=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 実モデルで翻訳を 1 件実行する。翻訳は標準出力にも出す —
    /// «原文 + 翻訳» の中身は目視での品質確認に委ねる。
    ///
    /// ライセンスは **nil (課金対象外 = CLI 経路) を使わない** — Release の MAS
    /// ビルドでこのセルフテストを走らせたとき購入なしに翻訳が実行できる経路に
    /// ならないよう、ビルドが組み立てる実際の権利 (直接配布ビルド =
    /// directDistribution の無料開放 / MAS ビルド = StoreKit 無効の .none) で
    /// 判定する (SelfTestTranscriptQA.runLiveAnswer と同じ cubic レビュー指摘への
    /// 対応)。MAS の未購入ビルドではゲートが弾くため SKIP になる
    private static func runLiveTranslation() async {
        let license = ProCoordinator(enabled: false).license
        guard license.allows(.translation) else {
            print("selftest: translate LIVE SKIP: このビルドの権利では Pro 機能がロックされています (MAS ビルド)")
            return
        }
        let transcript = [
            TranscriptSegment(start: 0, end: 6, text: "リリースは11月2日で確定しました"),
            TranscriptSegment(start: 6, end: 14, text: "告知文は佐藤さんが金曜までに用意します"),
            TranscriptSegment(start: 14, end: 22, text: "予算の話は次回の持ち越しにしましょう"),
        ]
        do {
            let translated = try await TranscriptTranslator.translate(
                transcript: transcript,
                targetLanguage: .english,
                title: "週次定例",
                license: license)
            check(!translated.isEmpty, "live translation produced a non-empty reply")
            print("selftest: translate LIVE (ja → en) result:")
            print(translated)
            // «行構造» の検証: 時刻表示は翻訳されず残る (エンジンの指示の契約)。
            // «モデルが保ったか» は行頭の [00:xx] の有無で確かめる —
            // 保たれなかったときは FAIL にする (UI 側の «原文との対応» が
            // 成り立たなくなるための契約)
            check(translated.contains("[00:00]"),
                  "live translation keeps the time marker of the first line")
        } catch is TranscriptTranslator.Unavailable {
            print("selftest: translate LIVE SKIP: Apple Intelligence が使えない環境です")
        } catch let error as KilError where error.code == .licenseRequired {
            print("selftest: translate LIVE SKIP: このビルドの権利では Pro 機能がロックされています")
        } catch {
            check(false, "live translation succeeded (error: \(error))")
        }
    }

    /// ゲートが `license` に対して licenseRequired を投げるか。
    /// **空の書き起こし**を渡す — ゲートは translate の最初の分岐なので権利なし
    /// (.none) はここで必ず弾かれ、nil は可用性・空検査のどちらかに行き着く
    /// (モデルは呼ばない)
    private static func gateFires(for license: LicenseContext?) async -> Bool {
        do {
            _ = try await TranscriptTranslator.translate(
                transcript: [], targetLanguage: .english, license: license)
            return false
        } catch let error as KilError {
            return error.code == .licenseRequired
        } catch {
            return false
        }
    }
}
