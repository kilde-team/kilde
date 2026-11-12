import AppKit
import Foundation
import FirebaseCore
import KildeCore

/// 書き起こしの質問応答 (issue #540 — 第四弾 Pro) の UI 無し検証。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (SelfTestFollowup / SelfTestPro と同じ位置づけ)。確かめるのは:
/// - エンジンのゲート (kilde-cli-swift#141): 権利なしで `licenseRequired`、
///   課金対象外 (nil = CLI と同じ経路) では投げない (**空の書き起こし**を渡すため
///   モデルは呼ばない — FollowupComposerGateTests と同じ前提)
/// - `TranscriptQASupport`: ボタンの可否とツールチップ、«答えを得る» の
///   有効条件 (質問の «実質空» と実行中の再入防止)、質問の正規化、
///   コピー全文の組み立て
/// - 計測イベント (qa_*) が Firebase 未初期化で安全な no-op になること
///
/// 確かめられないのはここまで、という線引き (SelfTestFollowup と同じ): 実際の
/// モデル生成 (Apple Intelligence が有効な実機の Release ビルドで確認する) と
/// シートの見た目 (手動確認)。
///
/// 使い方: `KILDE_GUI_SELFTEST_QA=1 <GUI>` (SelfTest.runIfRequested から配線)。
/// `KILDE_GUI_SELFTEST_QA_LIVE=1` を併せて指定すると、最後に実モデルでの
/// 質問応答も走らせて結果を標準出力に出す (Apple Intelligence が使える実機向け。
/// 非対応環境は SKIP して失敗に数えない)
@MainActor
enum SelfTestTranscriptQA {

    private static var failures = 0
    private static var total = 0

    private static func check(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("selftest: qa PASS: \(label)")
        } else {
            failures += 1
            print("selftest: qa FAIL: \(label)")
        }
    }

    static func run() {
        // MainActor の実行を止めずに非同期で検証を回し、終わったら終了する
        // (SelfTestFollowup と同じ — セマフォ待ちで固めない)
        Task { await runChecks() }
    }

    private static func runChecks() async {
        // 1) エンジンのゲート: 権利なし (.none) は licenseRequired。ゲートは
        //    answer の最初の分岐なので、Apple Intelligence の有無に依らず
        //    モデルを呼ばない (空の書き起こしで «ゲート直後» まで到達させる)
        check(await gateFires(for: LicenseContext(entitlement: .none)),
              "engine gate fires for .none")

        // 2) 課金対象外 (nil = CLI と同じ経路) ではゲートが発火しない
        check(await !gateFires(for: nil), "engine gate passes for nil (CLI path)")

        // 3) ボタンの可否 — 書き起こしの有無・環境 (Apple Intelligence)・
        //    Pro 権限の優先順位 (FollowupDraftSupport と同じ «環境 → Pro» の順)
        check(TranscriptQASupport.isButtonEnabled(
                  hasTranscript: true,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button enabled for transcript + environment + pro")
        check(!TranscriptQASupport.isButtonEnabled(
                  hasTranscript: false,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button disabled without a transcript")
        check(!TranscriptQASupport.isButtonEnabled(
                  hasTranscript: true,
                  appleIntelligenceUnavailableReason: nil, proAllows: false),
              "button disabled without pro")
        check(!TranscriptQASupport.isButtonEnabled(
                  hasTranscript: true,
                  appleIntelligenceUnavailableReason: "Apple Intelligence が無効",
                  proAllows: true),
              "button disabled without Apple Intelligence")
        // ツールチップは «Pro あり» と «Pro なし» で別の文言になる («控えめ» 方針 —
        // Pro 案内は Pro なしのときだけ出る)
        check(
            TranscriptQASupport.buttonTooltip(
                hasTranscript: true,
                appleIntelligenceUnavailableReason: nil, proAllows: false)
                != TranscriptQASupport.buttonTooltip(
                    hasTranscript: true,
                    appleIntelligenceUnavailableReason: nil, proAllows: true),
            "tooltip explains the pro lock")

        // 4) «答えを得る» の有効条件 — «実質空» の質問は押せず、実行中も再入しない
        check(TranscriptQASupport.isAskEnabled(question: "決定事項は?", isAsking: false),
              "ask enabled for a non-empty question")
        check(!TranscriptQASupport.isAskEnabled(question: "   \n ", isAsking: false),
              "ask disabled for a whitespace-only question")
        check(!TranscriptQASupport.isAskEnabled(question: "", isAsking: false),
              "ask disabled for an empty question")
        check(!TranscriptQASupport.isAskEnabled(question: "決定事項は?", isAsking: true),
              "ask disabled while asking (re-entry guard)")

        // 5) 質問の正規化 — «空白のみ» は空、上限超過は切り詰め (エンジンの
        //    TranscriptQA.normalizeQuestion と同じ規約)
        check(TranscriptQASupport.normalizedQuestion("  決定事項は? \n") == "決定事項は?",
              "normalized question trims whitespace")
        check(TranscriptQASupport.normalizedQuestion(" \t ") == "",
              "normalized question collapses whitespace-only to empty")
        let overLimit = String(repeating: "あ", count: TranscriptQASupport.maxQuestionLength + 50)
        check(TranscriptQASupport.normalizedQuestion(overLimit).count
              == TranscriptQASupport.maxQuestionLength,
              "normalized question truncates over the limit")

        // 6) コピー全文 — 根拠 (excerpts) があるときだけ «根拠» の行を続ける。
        //    根拠はエンジンの抽出経路 (長い書き起こし) だけ返る契約
        let plain = TranscriptAnswer(text: "月曜 10 時にリリース", excerpts: [])
        check(TranscriptQASupport.clipboardText(for: plain) == "月曜 10 時にリリース",
              "clipboard text is the answer alone without excerpts")
        let grounded = TranscriptAnswer(
            text: "月曜 10 時にリリース",
            excerpts: ["[10:05] リリースは月曜 10 時でいきます"])
        check(TranscriptQASupport.clipboardText(for: grounded)
              == "月曜 10 時にリリース\n\n—\n根拠 (文字起こしの行):\n[10:05] リリースは月曜 10 時でいきます",
              "clipboard text appends the excerpt section when grounded")

        // 7) 計測イベント (qa_*) は Firebase 未初期化 (セルフテスト) で
        //    呼んでも安全な no-op になること (followup_* と同じ線引き)
        UsageAnalytics.qaStarted()
        UsageAnalytics.qaCompleted(processingTime: nil)
        UsageAnalytics.qaFailed(
            KilError.failure(.qaEmptyQuestion, "selftest"), processingTime: nil)
        check(FirebaseApp.app() == nil,
              "qa analytics calls keep Firebase uninitialized")

        // 8) 実モデルの呼び出し (KILDE_GUI_SELFTEST_QA_LIVE=1 のときのみ)。
        //    Apple Intelligence が使える実機で回答が実際に生成できることを
        //    確かめる。非対応環境は SKIP (失敗に数えない — 上の 1〜7 と同じ
        //    «環境に依存しない検証を失敗にしない» 線引き)
        if ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_QA_LIVE"] == "1" {
            await runLiveAnswer()

            // 長い書き起こし (チャンク分割で抽出経路に分岐する長さ) でも回答が
            // 得られることを確かめる。権利判定は runLiveAnswer と同じ —
            // MAS 未購入ビルドではゲートが弾くため FAIL ではなく SKIP にする
            // (このブロックは権利チェックを持たず、Unavailable 以外のエラーは
            // check(false) に落ちるため、判定を先に済ませる)
            let longLicense = ProCoordinator(enabled: false).license
            guard longLicense.allows(.transcriptQA) else {
                print("selftest: qa LIVE (long) SKIP: このビルドの権利では Pro 機能がロックされています (MAS ビルド)")
                print("selftest: qa PASS=\(total - failures) FAIL=\(failures)")
                exit(failures == 0 ? 0 : 1)
            }
            // «抜粋が返る» こと自体はモデル依存 (抽出が
            // 空を返すと «見つからない» が正しい挙動) のため表明にせず、
            // **抜粋が返ったときその行は書き起こしの描画行に存在する**
            // (エンジンの原文照合 — kilde-cli-swift#143) ことだけを縛る。
            // 答えは末尾の 1 件にしか無い構成で、抽出が実際に「探す」ことを誘う
            var longTranscript: [TranscriptSegment] = []
            for i in 0..<320 {
                longTranscript.append(TranscriptSegment(
                    start: Double(i) * 10, end: Double(i) * 10 + 9,
                    text: "区間\(i) の雑談です。ここには答えに無関係な話題が並びます。天気や食事の話をしています。"))
            }
            let decision = TranscriptSegment(
                start: 3210, end: 3220,
                text: "決定: 社内ポータルのリニューアルは来年 3 月をめどに進める")
            longTranscript.append(decision)
            do {
                let qa = try await TranscriptQA.answer(
                    question: "ポータルのリニューアルの時期はいつに決まりましたか?",
                    transcript: longTranscript,
                    title: "抽出経路の検証",
                    license: longLicense)
                check(!qa.text.isEmpty, "long transcript QA produced a non-empty reply")
                let renderedLines = Set(longTranscript.map { segment in
                    "[\(Int(segment.start) / 60):\(String(format: "%02d", Int(segment.start) % 60))] \(segment.text)"
                })
                check(qa.excerpts.allSatisfy { renderedLines.contains($0) },
                      "returned excerpts are verbatim transcript lines")
                print("selftest: qa LIVE (long) answer: \(qa.text)")
                print("selftest: qa LIVE (long) excerpts: \(qa.excerpts.isEmpty ? "(なし)" : qa.excerpts.joined(separator: " / "))")
            } catch is TranscriptQA.Unavailable {
                print("selftest: qa LIVE (long) SKIP: Apple Intelligence が使えない環境です")
            } catch {
                check(false, "long transcript QA succeeded (error: \(error))")
            }
        }

        print("selftest: qa PASS=\(total - failures) FAIL=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 実モデルで質問応答を 1 件実行する。回答は標準出力にも出す —
    /// «質問 + 回答 + 根拠» の中身は目視での品質確認に委ねる。
    ///
    /// ライセンスは **nil (課金対象外 = CLI 経路) を使わない** — Release の MAS
    /// ビルドでこのセルフテストを走らせたとき購入なしに質問応答が実行できる経路に
    /// ならないよう、ビルドが組み立てる実際の権利 (直接配布ビルド =
    /// directDistribution の無料開放 / MAS ビルド = StoreKit 無効の .none) で
    /// 判定する (SelfTestFollowup.runLiveGeneration と同じ cubic レビュー指摘への
    /// 対応)。MAS の未購入ビルドではゲートが弾くため SKIP になる —
    /// 権利のある経路の実生成は直接配布ビルドで確認する
    private static func runLiveAnswer() async {
        let license = ProCoordinator(enabled: false).license
        guard license.allows(.transcriptQA) else {
            print("selftest: qa LIVE SKIP: このビルドの権利では Pro 機能がロックされています (MAS ビルド)")
            return
        }
        let transcript = [
            TranscriptSegment(start: 0, end: 6, text: "リリースは11月2日で確定しました"),
            TranscriptSegment(start: 6, end: 14, text: "告知文は佐藤さんが金曜までに用意します"),
            TranscriptSegment(start: 14, end: 22, text: "予算の話は次回の持ち越しにしましょう"),
        ]
        do {
            let answer = try await TranscriptQA.answer(
                question: "リリース日はいつに決まりましたか?",
                transcript: transcript,
                title: "週次定例",
                license: license)
            check(!answer.text.isEmpty, "live answer produced a non-empty reply")
            print("selftest: qa LIVE answer:")
            print(answer.text)
            if TranscriptQASupport.hasExcerpts(answer) {
                print("selftest: qa LIVE excerpts: \(answer.excerpts.joined(separator: " / "))")
            } else {
                print("selftest: qa LIVE excerpts: (なし — 1 チャンクの直接回答)")
            }
        } catch is TranscriptQA.Unavailable {
            print("selftest: qa LIVE SKIP: Apple Intelligence が使えない環境です")
        } catch {
            check(false, "live answer succeeded (error: \(error))")
        }
    }

    /// ゲートが `license` に対して licenseRequired を投げるか。
    /// **空の書き起こし**を渡す — ゲートは answer の最初の分岐なので権利なし
    /// (.none) はここで必ず弾かれ、nil は可用性・空検査のどちらかに行き着く
    /// (モデルは呼ばない)
    private static func gateFires(for license: LicenseContext?) async -> Bool {
        do {
            _ = try await TranscriptQA.answer(
                question: "決定事項は?", transcript: [], license: license)
            return false
        } catch let error as KilError {
            return error.code == .licenseRequired
        } catch {
            return false
        }
    }
}
