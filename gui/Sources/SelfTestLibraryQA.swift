import AppKit
import Foundation
import FirebaseCore
import KildeCore

/// ライブラリ横断の検索・質問応答 (issue #547 — 第五弾 Pro) の UI 無し検証。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (SelfTestTranscriptQA / SelfTestFollowup と同じ位置づけ)。確かめるのは:
/// - エンジンのゲート (kilde-cli-swift#145): 権利なしで `licenseRequired`、
///   課金対象外 (nil = CLI と同じ経路) では投げない (**空のライブラリ**を渡すため
///   モデルは呼ばない — TranscriptQAGateTests と同じ前提)
/// - `LibrarySearch`: 部分一致の照合 (大文字小文字の揃え・時刻接頭辞を含まない
///   本文照合・«実質空» の語は空)
/// - `LibraryQASupport`: ボタンの可否とツールチップ、«答えを得る» の有効条件、
///   検索語の正規化、録画列の写像 (書き起こしを持つ録画だけ)、コピー全文の組み立て
/// - 計測イベント (library_qa_*) が Firebase 未初期化で安全な no-op になること
///
/// 確かめられないのはここまで、という線引き (SelfTestTranscriptQA と同じ):
/// 実際のモデル生成 (Apple Intelligence が有効な実機で確認する) とシートの
/// 見た目 (手動確認)。
///
/// 使い方: `KILDE_GUI_SELFTEST_LIBRARY_QA=1 <GUI>` (SelfTest.runIfRequested から配線)。
/// `KILDE_GUI_SELFTEST_LIBRARY_QA_LIVE=1` を併せて指定すると、最後に実モデルでの
/// 質問応答も走らせて結果を標準出力に出す (Apple Intelligence が使える実機向け。
/// 非対応環境は SKIP して失敗に数えない)
@MainActor
enum SelfTestLibraryQA {

    private static var failures = 0
    private static var total = 0

    private static func check(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("selftest: library_qa PASS: \(label)")
        } else {
            failures += 1
            print("selftest: library_qa FAIL: \(label)")
        }
    }

    static func run() {
        // MainActor の実行を止めずに非同期で検証を回し、終わったら終了する
        // (SelfTestTranscriptQA と同じ — セマフォ待ちで固めない)
        Task { await runChecks() }
    }

    private static func runChecks() async {
        // 1) エンジンのゲート: 権利なし (.none) は licenseRequired。ゲートは
        //    answer の最初の分岐なので、Apple Intelligence の有無に依らず
        //    モデルを呼ばない (空のライブラリで «ゲート直後» まで到達させる)
        check(await gateFires(for: LicenseContext(entitlement: .none)),
              "engine gate fires for .none")

        // 2) 課金対象外 (nil = CLI と同じ経路) ではゲートが発火しない
        check(await !gateFires(for: nil), "engine gate passes for nil (CLI path)")

        // 3) ボタンの可否 — «書き起こし済みの録画»・環境・Pro 権限の優先順位
        //    («環境 → Pro» の順 — TranscriptQASupport と同じ)
        check(LibraryQASupport.isButtonEnabled(
                  hasTranscribedRecording: true,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button enabled for transcribed recordings + environment + pro")
        check(!LibraryQASupport.isButtonEnabled(
                  hasTranscribedRecording: false,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button disabled without transcribed recordings")
        check(!LibraryQASupport.isButtonEnabled(
                  hasTranscribedRecording: true,
                  appleIntelligenceUnavailableReason: nil, proAllows: false),
              "button disabled without pro")
        check(!LibraryQASupport.isButtonEnabled(
                  hasTranscribedRecording: true,
                  appleIntelligenceUnavailableReason: "Apple Intelligence が無効",
                  proAllows: true),
              "button disabled without Apple Intelligence")
        // ツールチップは «Pro あり» と «Pro なし» で別の文言になる («控えめ» 方針)
        check(
            LibraryQASupport.buttonTooltip(
                hasTranscribedRecording: true,
                appleIntelligenceUnavailableReason: nil, proAllows: true)
            != LibraryQASupport.buttonTooltip(
                hasTranscribedRecording: true,
                appleIntelligenceUnavailableReason: nil, proAllows: false),
            "tooltip differs between pro and no-pro")

        // 4) «答えを得る» の有効条件 — «実質空» の質問と実行中の再入防止
        check(LibraryQASupport.isAskEnabled(question: "予算の話は?", isAsking: false),
              "ask enabled for a question")
        check(!LibraryQASupport.isAskEnabled(question: "   \n ", isAsking: false),
              "ask disabled for a whitespace-only question")
        check(!LibraryQASupport.isAskEnabled(question: "予算の話は?", isAsking: true),
              "ask disabled while asking (re-entry guard)")

        // 5) 質問の正規化 — エンジンと同じ «前後の空白を取り除き上限で切り詰め»
        check(LibraryQASupport.normalizedQuestion("  予算の話は? \n") == "予算の話は?",
              "normalizedQuestion trims whitespace")
        check(LibraryQASupport.normalizedQuestion("   ") == "",
              "normalizedQuestion collapses whitespace-only to empty")

        // 6) 検索語の正規化 — «実質空» は nil、複数語は語列
        check(LibraryQASupport.searchTerms(from: "   ") == nil,
              "searchTerms nil for whitespace-only query")
        check(LibraryQASupport.searchTerms(from: "予算 締め切り") == ["予算", "締め切り"],
              "searchTerms splits the query")

        // 7) 録画列の写像 — **書き起こしを持つ録画だけ**。ライブラリの索引は
        //    話者を保持しないため speaker は nil
        let withoutTranscript = LibraryEntry(
            id: URL(fileURLWithPath: "/tmp/a.mp4"),
            recordingURL: URL(fileURLWithPath: "/tmp/a.mp4"),
            transcriptURL: nil, recordedAt: Date(), segments: nil)
        let withTranscript = LibraryEntry(
            id: URL(fileURLWithPath: "/tmp/b.mp4"),
            recordingURL: URL(fileURLWithPath: "/tmp/b.mp4"),
            transcriptURL: URL(fileURLWithPath: "/tmp/b.json"),
            recordedAt: Date(),
            segments: [
                LibrarySegment(start: 0, end: 2, text: "予算は100万円です"),
                LibrarySegment(start: 2, end: 4, text: "締め切りは来週です"),
            ])
        let mapped = LibraryQASupport.recordings(from: [withoutTranscript, withTranscript])
        check(mapped.count == 1, "recordings maps only transcribed entries")
        // 強制インデックスを避ける — 写像チェックが失敗したときに
        // セルフテスト自体がクラッシュすると失敗集計と残りの検証が出せない
        // (cubic レビュー指摘)
        let first = mapped.first
        check(first.map { $0.segments.count == 2 } ?? false, "recordings maps all segments")
        check(first.map { recording in
            recording.segments.allSatisfy { $0.speaker == nil }
        } ?? false, "recordings maps speaker as nil (index keeps no speakers)")
        // 空 cue (空白のみの本文) だけのサイドカーは «文字起こし済み» にしない —
        // ボタンが有効になるのに質問の文脈が空になるため (cubic レビュー指摘)
        let emptyCue = LibraryEntry(
            id: URL(fileURLWithPath: "/tmp/c.mp4"),
            recordingURL: URL(fileURLWithPath: "/tmp/c.mp4"),
            transcriptURL: URL(fileURLWithPath: "/tmp/c.json"),
            recordedAt: Date(),
            segments: [LibrarySegment(start: 0, end: 2, text: "   ")])
        check(!LibraryQASupport.hasNonEmptySegments(emptyCue),
              "empty-cue sidecar is not transcribed")
        check(LibraryQASupport.recordings(from: [emptyCue]).isEmpty,
              "recordings drops empty-cue entries")

        // 8) エンジンの検索 (LibrarySearch) — 部分一致の純粋照合が GUI 側からも
        //    使える (公開 API)。«実質空» の語は空、ヒット行には時刻接頭辞が付く
        let results = LibrarySearch.search(term: "予算", in: mapped)
        check(results.count == 1 && results[0].totalHits == 1,
              "LibrarySearch finds the term in the mapped recording")
        check(LibrarySearch.search(term: "   ", in: mapped).isEmpty,
              "LibrarySearch returns no results for a whitespace-only term")

        // 9) 計測イベントが Firebase 未初期化で安全な no-op になる。
        //    «未初期化» 自体も表明する — Firebase の初期化が回帰すると
        //    «Debug セルフテストが本番 Firebase に送る» 状態に気づけないため
        //    (cubic レビュー指摘。Debug は configure しない仕様 — CLAUDE.md §5-22)
        check(FirebaseApp.app() == nil,
              "Firebase is not initialized in the self-test process")
        UsageAnalytics.libraryQAStarted()
        UsageAnalytics.libraryQACompleted(processingTime: nil)
        UsageAnalytics.libraryQAFailed(
            KilError.failure(.licenseRequired, "selftest"), processingTime: nil)
        // 追質問の計測 (qa_chat_* — issue #556。両シート共通のイベント名) も
        // 同じ線引き
        UsageAnalytics.qaChatStarted()
        UsageAnalytics.qaChatCompleted(processingTime: nil)
        UsageAnalytics.qaChatFailed(
            KilError.failure(.licenseRequired, "selftest"), processingTime: nil)
        check(true, "library_qa_* and qa_chat_* events are safe no-ops without Firebase")

        // 9.5) 連続対話 (issue #556 — 第六弾 Pro) のゲート: 追質問で qaChat の
        //      権利が無いと licenseRequired、権利があれば通る (**空のライブラリ**
        //      でモデルを呼ばない構成)。初問 (履歴なし) と «実質空» の往復だけの
        //      履歴は qaChat を要求しない (第五弾のゲートのまま)
        check(await chatGateFires(
                  history: [QATurn(question: "予算の話は?", answer: "100万円です")],
                  for: LicenseContext(entitlement: .licenseKey(LicenseKeyClaims(
                      v: 1, id: "selftest",
                      features: [ProFeature.libraryQA.rawValue])))),
              "chat gate fires for a follow-up without qaChat entitlement")
        check(await !chatGateFires(
                  history: [QATurn(question: "予算の話は?", answer: "100万円です")],
                  for: LicenseContext(entitlement: .licenseKey(LicenseKeyClaims(
                      v: 1, id: "selftest",
                      features: [ProFeature.libraryQA.rawValue, ProFeature.qaChat.rawValue])))),
              "chat gate passes for a follow-up with qaChat entitlement")
        check(await !chatGateFires(
                  history: [],
                  for: LicenseContext(entitlement: .licenseKey(LicenseKeyClaims(
                      v: 1, id: "selftest",
                      features: [ProFeature.libraryQA.rawValue])))),
              "first question does not require qaChat")
        check(await !chatGateFires(
                  history: [QATurn(question: "   \n", answer: "回答")],
                  for: LicenseContext(entitlement: .licenseKey(LicenseKeyClaims(
                      v: 1, id: "selftest",
                      features: [ProFeature.libraryQA.rawValue])))),
              "effectively empty history does not require qaChat")

        await finish(status: "library_qa")
    }

    /// ゲートが licenseRequired を投げたか (SelfTestTranscriptQA.gateFires と同じ)。
    /// 空のライブラリを渡すためモデルは呼ばれない。非対応環境では
    /// Unavailable (ゲート通過扱い) を返す
    private static func gateFires(for license: LicenseContext?) async -> Bool {
        do {
            _ = try await LibraryQA.answer(
                question: "決定事項は?", recordings: [], license: license)
            return false
        } catch let error as KilError {
            return error.code == .licenseRequired
        } catch is LibraryQA.Unavailable {
            return false
        } catch {
            return false
        }
    }

    /// 連続対話 (履歴つき) の呼び出しで licenseRequired が投げられるか
    /// (gateFires の履歴つき版 — issue #556)。**空のライブラリ**を渡すため
    /// モデルは呼ばれない。第五弾のゲートと第六弾のゲートはどちらも
    /// 可用性チェックより前に置かれており、権利が足りないときは必ずここで弾かれ、
    /// 通るときは可用性・空検査へ進む
    private static func chatGateFires(
        history: [QATurn], for license: LicenseContext?
    ) async -> Bool {
        do {
            _ = try await LibraryQA.answer(
                question: "その件の詳細は?", recordings: [],
                history: history, license: license)
            return false
        } catch let error as KilError {
            return error.code == .licenseRequired
        } catch is LibraryQA.Unavailable {
            return false
        } catch {
            return false
        }
    }

    /// 結果を集計して終了する (SelfTestTranscriptQA と同じ形式)。
    /// LIVE モード (KILDE_GUI_SELFTEST_LIBRARY_QA_LIVE=1) は実モデルの
    /// 質問応答を最後に 1 回走らせる — Apple Intelligence 非対応の環境では
    /// SKIP して失敗に数えない
    private static func finish(status: String) async {
        if ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_LIBRARY_QA_LIVE"] == "1" {
            // runLive 自体が await を含むため finish も async (SelfTestTranscriptQA と
            // 同じ構成)。await の付け忘れはビルドで落ちるのでここで括る
            await runLive()
        }
        print("selftest: \(status) \(failures == 0 ? "PASS" : "FAIL"): \(total - failures)/\(total)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 実モデルでの質問応答 (任意実行)。合成録画 2 件のライブラリに
    /// «予算はいくら?» を投げ、回答と根拠を標準出力に出す。
    /// 権利判定は **ProCoordinator (enabled: false) のライセンス** を使う —
    /// `license: nil` (CLI 経路) を使うと MAS の未購入ビルドでもゲートを
    /// 迂回して実モデルを呼び、«権限付き GUI 経路» の検証にならないため
    /// (SelfTestTranscriptQA.runLiveAnswer と同じ cubic レビュー経緯)。
    /// MAS の未購入ビルドではゲートが弾くため FAIL ではなく SKIP にする。
    /// 失敗は check(false) で記録する (直接 failures を触ると
    /// PASS/FAIL の件数表示がずれるため)
    private static func runLive() async {
        let license = ProCoordinator(enabled: false).license
        guard license.allows(.libraryQA) else {
            print("selftest: library_qa LIVE SKIP: このビルドの権利では Pro 機能がロックされています (MAS ビルド)")
            return
        }
        guard MeetingSummarizer.unsupportedReason == nil else {
            print("selftest: library_qa LIVE SKIP: Apple Intelligence が使えない環境")
            return
        }
        let library = [
            LibraryRecording(
                title: "定例会議",
                segments: [
                    TranscriptSegment(start: 0, end: 4, text: "今季度の予算は100万円です", speaker: nil),
                    TranscriptSegment(start: 4, end: 8, text: "締め切りは月末です", speaker: nil),
                ]),
            LibraryRecording(
                title: "設計レビュー",
                segments: [
                    TranscriptSegment(start: 0, end: 4, text: "ライブラリ検索の仕様を確定させた", speaker: nil),
                ]),
        ]
        do {
            let answer = try await LibraryQA.answer(
                question: "予算はいくら?", recordings: library, license: license)
            print("selftest: library_qa live answer: \(answer.text)")
            print("selftest: library_qa live excerpts: \(answer.excerpts)")
        } catch let error as LibraryQA.Unavailable {
            // 実行時にも非対応を返しうる — «非対応環境は SKIP して
            // 失敗に数えない» の契約に従う (cubic レビュー指摘)
            print("selftest: library_qa LIVE SKIP: \(error)")
        } catch {
            check(false, "live generation fails: \(error)")
        }
    }
}
