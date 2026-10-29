import AppKit
import Foundation
import FirebaseCore
import KildeCore

/// フォローアップの下書き (issue #464 — 第二弾 Pro) の UI 無し検証。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (SelfTestPro / SelfTestTelemetry と同じ位置づけ)。確かめるのは:
/// - エンジンのゲート (kilde-cli-swift#137): 権利なしで `licenseRequired`、
///   課金対象外 (nil = CLI と同じ経路) では投げない (**空の要約**を渡すため
///   モデルは呼ばない — MeetingSummarizerGateTests と同じ前提)
/// - `FollowupDraftSupport`: サイドカーの形式・要約の有無によるボタンの可否と
///   ツールチップ、コピー全文の組み立て (エンジンの往復解析を含む)
/// - 計測イベント (followup_*) が Firebase 未初期化で安全な no-op になること
///
/// 確かめられないのはここまで、という線引き (SelfTestPro と同じ): 実際のモデル
/// 生成 (Apple Intelligence が有効な実機の Release ビルドで確認する) と
/// シートの見た目 (手動確認)。
///
/// 使い方: `KILDE_GUI_SELFTEST_FOLLOWUP=1 <GUI>` (SelfTest.runIfRequested から配線)。
/// `KILDE_GUI_SELFTEST_FOLLOWUP_LIVE=1` を併せて指定すると、最後に実モデルでの
/// 下書き生成 (両スタイル) も走らせて結果を標準出力に出す (Apple Intelligence が
/// 使える実機向け。非対応環境は SKIP して失敗に数えない)
@MainActor
enum SelfTestFollowup {

    private static var failures = 0
    private static var total = 0

    private static func check(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("selftest: followup PASS: \(label)")
        } else {
            failures += 1
            print("selftest: followup FAIL: \(label)")
        }
    }

    static func run() {
        // MainActor の実行を止めずに非同期で検証を回し、終わったら終了する
        // (SelfTestPro と同じ — セマフォ待ちで固めない)
        Task { await runChecks() }
    }

    private static func runChecks() async {
        // 1) エンジンのゲート: 権利なし (.none) は licenseRequired。ゲートは
        //    compose の最初の分岐なので、Apple Intelligence の有無に依らず
        //    モデルを呼ばない (FollowupComposerGateTests と同じ前提)
        check(await gateFires(for: LicenseContext(entitlement: .none)),
              "engine gate fires for .none")

        // 2) 課金対象外 (nil = CLI と同じ経路) ではゲートが発火しない
        check(await !gateFires(for: nil), "engine gate passes for nil (CLI path)")

        // 3) サイドカーの形式と要約の有無による入力状態 (一時ディレクトリで合成)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-followup-\(UUID().uuidString)")
        // createDirectory は throw しない経路で呼ぶ — セルフテストは失敗を
        // check の集計で報告するため、ここでは try? で十分 (作れなければ
        // 以降のファイル系チェックがすべて失敗する)。後始末の removeItem は
        // exit の直前に明示的に呼ぶ — defer は exit で走らないため
        // (SelfTestLibraryExport と同じ)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let summary = MeetingSummary(
            points: ["リリース日を決めた"], decisions: ["月曜 10 時にリリース"],
            actions: ["田中がリリースノートを書く"])
        let segments = [TranscriptSegment(start: 0, end: 2, text: "書き起こしのセグメント")]
        let minutesURL = directory.appendingPathComponent("minutes.md")
        do {
            try TranscriptFormatter.render(
                segments, as: .markdown, title: "件名", summary: summary)
                .write(to: minutesURL, atomically: true, encoding: .utf8)
        } catch {
            check(false, "render minutes .md for the checks (threw: \(error))")
        }
        let plainMDURL = directory.appendingPathComponent("plain.md")
        try? TranscriptFormatter.render(segments, as: .markdown, title: "件名")
            .write(to: plainMDURL, atomically: true, encoding: .utf8)
        let srtURL = directory.appendingPathComponent("transcript.srt")
        try? TranscriptFormatter.render(segments, as: .srt)
            .write(to: srtURL, atomically: true, encoding: .utf8)

        check(FollowupDraftSupport.loadMinutesDoc(sidecarURL: minutesURL)
              == .summary(summary),
              "minutes .md with a summary loads the summary (engine round-trip)")
        check(FollowupDraftSupport.loadMinutesDoc(sidecarURL: plainMDURL) == .noSummary,
              "minutes .md without a summary is noSummary")
        check(FollowupDraftSupport.loadMinutesDoc(sidecarURL: srtURL) == .notMinutes,
              "non-md sidecar is notMinutes")
        check(FollowupDraftSupport.loadMinutesDoc(sidecarURL: nil) == .notMinutes,
              "missing sidecar is notMinutes")

        // 4) ボタンの可否 — 環境 (Apple Intelligence) と Pro 権限の優先順位を含む
        check(FollowupDraftSupport.isButtonEnabled(
                  doc: .summary(summary),
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button enabled for summary + environment + pro")
        check(!FollowupDraftSupport.isButtonEnabled(
                  doc: .summary(summary),
                  appleIntelligenceUnavailableReason: nil, proAllows: false),
              "button disabled without pro")
        check(!FollowupDraftSupport.isButtonEnabled(
                  doc: .summary(summary),
                  appleIntelligenceUnavailableReason: "Apple Intelligence が無効",
                  proAllows: true),
              "button disabled without Apple Intelligence")
        check(!FollowupDraftSupport.isButtonEnabled(
                  doc: .noSummary,
                  appleIntelligenceUnavailableReason: nil, proAllows: true),
              "button disabled without a summary")
        // ツールチップは «Pro あり» と «Pro なし» で別の文言になる (Pro 案内は
        // Pro なしのときだけ出る)。環境が使えない環境ではどちらも環境案内になる
        // ため、環境 OK の体裁 (unavailableReason = nil) で純粋関数として比べる
        check(
            FollowupDraftSupport.buttonTooltip(
                doc: .summary(summary),
                appleIntelligenceUnavailableReason: nil, proAllows: false)
                != FollowupDraftSupport.buttonTooltip(
                    doc: .summary(summary),
                    appleIntelligenceUnavailableReason: nil, proAllows: true),
            "tooltip explains the pro lock")

        // 5) コピー全文 — 件名は 1 行目 + 空行 + 本文。件名なし (チャット・空件名) は本文のみ
        check(FollowupDraftSupport.clipboardText(
                  for: FollowupDraft(subject: "件名", body: "本文1\n本文2"))
              == "件名\n\n本文1\n本文2",
              "clipboard text joins subject and body")
        check(FollowupDraftSupport.clipboardText(
                  for: FollowupDraft(subject: nil, body: "本文"))
              == "本文",
              "clipboard text is body-only without a subject")

        // 6) 計測イベント (followup_*) は Firebase 未初期化 (セルフテスト) で
        //    呼んでも安全な no-op になること (SelfTestPro の pro_/summary_ と同じ線引き)
        UsageAnalytics.followupStarted()
        UsageAnalytics.followupCompleted(processingTime: nil)
        UsageAnalytics.followupFailed(
            KilError.failure(.licenseRequired, "selftest"), processingTime: nil)
        check(FirebaseApp.app() == nil,
              "followup analytics calls keep Firebase uninitialized")

        // 7) 実モデルの呼び出し (KILDE_GUI_SELFTEST_FOLLOWUP_LIVE=1 のときのみ)。
        //    Apple Intelligence が使える実機で下書きが実際に生成できることを
        //    確かめる。非対応環境は SKIP (失敗に数えない — 上の 1〜6 と同じ
        //    «環境に依存しない検証を失敗にしない» 線引き)
        if ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_FOLLOWUP_LIVE"] == "1" {
            await runLiveGeneration()
        }

        print("selftest: followup PASS=\(total - failures) FAIL=\(failures)")
        // defer は exit で走らないため、一時ディレクトリはここで掃除する
        try? FileManager.default.removeItem(at: directory)
        exit(failures == 0 ? 0 : 1)
    }

    /// 実モデルで下書きを 1 件生成する (両スタイル)。生成結果は標準出力にも
    /// 出す — «件名 + 本文» の中身は目視での品質確認に委ねる。
    ///
    /// ライセンスは **nil (課金対象外 = CLI 経路) を使わない** — Release の MAS
    /// ビルドでこのセルフテストを走らせたとき購入なしに下書きが生成できる経路に
    /// ならないよう、ビルドが組み立てる実際の権利 (直接配布ビルド =
    /// directDistribution の無料開放 / MAS ビルド = StoreKit 無効の .none) で
    /// 判定する (cubic レビュー指摘)。MAS の未購入ビルドではゲートが弾くため
    /// SKIP になる — 有給経路の実生成は直接配布ビルドで確認する
    private static func runLiveGeneration() async {
        let license = ProCoordinator(enabled: false).license
        guard license.allows(.followupDraft) else {
            print("selftest: followup LIVE SKIP: このビルドの権利では Pro 機能がロックされています (MAS ビルド)")
            return
        }
        let summary = MeetingSummary(
            points: ["リリース日を11月2日に決めた", "キャンペーンの予算は20万円"],
            decisions: ["月曜 10 時にリリース"],
            actions: ["田中がリリースノートを書く", "佐藤が告知を投稿"])
        for style in FollowupDraftStyle.allCases {
            do {
                let draft = try await FollowupComposer.compose(
                    summary: summary, title: "週次定例", style: style, license: license)
                check(!draft.body.isEmpty, "live generation produced a \(style.rawValue) draft")
                print("selftest: followup LIVE (\(style.rawValue)) subject: \(draft.subject ?? "(なし)")")
                print(draft.body)
            } catch is FollowupComposer.Unavailable {
                print("selftest: followup LIVE SKIP (\(style.rawValue)): Apple Intelligence が使えない環境です")
            } catch {
                check(false, "live generation (\(style.rawValue)) succeeded (error: \(error))")
            }
        }
    }

    /// ゲートが `license` に対して licenseRequired を投げるか。
    /// **空の要約**を渡す — ゲートは compose の最初の分岐なので権利なし (.none) は
    /// ここで必ず弾かれ、nil は可用性・空検査のどちらかに行き着く (モデルは呼ばない)
    private static func gateFires(for license: LicenseContext?) async -> Bool {
        do {
            _ = try await FollowupComposer.compose(
                summary: MeetingSummary(points: [], decisions: [], actions: []),
                license: license)
            return false
        } catch let error as KilError {
            return error.code == .licenseRequired
        } catch {
            return false
        }
    }
}
