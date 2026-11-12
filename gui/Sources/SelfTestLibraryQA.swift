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
        check(mapped[0].segments.count == 2, "recordings maps all segments")
        check(mapped[0].segments.allSatisfy { $0.speaker == nil },
              "recordings maps speaker as nil (index keeps no speakers)")

        // 8) エンジンの検索 (LibrarySearch) — 部分一致の純粋照合が GUI 側からも
        //    使える (公開 API)。«実質空» の語は空、ヒット行には時刻接頭辞が付く
        let results = LibrarySearch.search(term: "予算", in: mapped)
        check(results.count == 1 && results[0].totalHits == 1,
              "LibrarySearch finds the term in the mapped recording")
        check(LibrarySearch.search(term: "   ", in: mapped).isEmpty,
              "LibrarySearch returns no results for a whitespace-only term")

        // 9) 計測イベントが Firebase 未初期化で安全な no-op になる
        //    (qa_* と同じ — 自セルフテストでは configure しない)
        UsageAnalytics.libraryQAStarted()
        UsageAnalytics.libraryQACompleted(processingTime: nil)
        UsageAnalytics.libraryQAFailed(
            KilError.failure(.licenseRequired, "selftest"), processingTime: nil)
        check(true, "library_qa_* events are safe no-ops without Firebase")

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
    /// «予算はいくら?» を投げ、回答と根拠を標準出力に出す
    private static func runLive() async {
        guard MeetingSummarizer.unsupportedReason == nil else {
            print("selftest: library_qa SKIP live (Apple Intelligence が使えない環境)")
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
                question: "予算はいくら?", recordings: library, license: nil)
            print("selftest: library_qa live answer: \(answer.text)")
            print("selftest: library_qa live excerpts: \(answer.excerpts)")
        } catch {
            print("selftest: library_qa live FAIL: \(error)")
            failures += 1
        }
    }
}
