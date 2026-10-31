import Foundation
import KildeCore

/// カスタム指示 (issue #472 — 第三弾 Pro) の UI 無し検証。
///
/// **実録画を伴わない** (SelfTestFollowup / SelfTestPro と同じ位置づけ)。確かめるのは:
/// - `RecordingSetup.mapComposerInstructions` の写像 (UserDefaults 非依存の純粋
///   関数 — «実質空» は nil、強調ポイントの行分割、nil / 非 nil の両側。実環境の
///   UserDefaults を触らずに写像の回帰を検証できるよう切り出した — cubic レビュー指摘)
/// - エンジンの 2 段目ゲート (kilde-cli-swift#139): 非空の指示は
///   `customInstructions` の権利なしで `licenseRequired`、«実質空» では投げない、
///   **課金対象外 (nil = CLI と同じ経路) でも投げない** (**空の要約**を渡すため
///   モデルは呼ばない)
///
/// 確かめられないのはここまで、という線引き (SelfTestPro と同じ): 実際に指示が
/// 生成結果へ反映されること (Apple Intelligence が有効な実機で確認する) と、
/// 設定パネルの見た目 (手動確認)。
///
/// 使い方: `KILDE_GUI_SELFTEST_COMPOSER_INSTRUCTIONS=1 <GUI>`
/// (SelfTest.runIfRequested から配線)
@MainActor
enum SelfTestComposerInstructions {

    private static var failures = 0
    private static var total = 0

    private static func check(_ condition: Bool, _ label: String) {
        total += 1
        if condition {
            print("selftest: composer-instructions PASS: \(label)")
        } else {
            failures += 1
            print("selftest: composer-instructions FAIL: \(label)")
        }
    }

    static func run() {
        Task { await runChecks() }
    }

    private static func runChecks() async {
        // 1) 写像: 全項目が空白のみなら nil («実質空 = 未指定» — ゲートを
        //    発火させない側)
        check(
            RecordingSetup.mapComposerInstructions(
                tone: " ", recipients: "\n", signature: "",
                extraPoints: " \n ", freeform: "") == nil,
            "whitespace-only input maps to nil")

        // 2) 写像: 値があれば非空。強調ポイントは改行で分割される
        let mapped = RecordingSetup.mapComposerInstructions(
            tone: "丁寧に", recipients: "社内チーム向け", signature: "田中",
            extraPoints: "次回日程\n予算\n\n", freeform: "箇条書きを減らす")
        check(mapped != nil, "non-empty input maps to instructions")
        check(
            mapped == ComposerInstructions(
                tone: "丁寧に", recipients: "社内チーム向け", signature: "田中",
                extraPoints: ["次回日程", "予算"], freeform: "箇条書きを減らす"),
            "extra points are split per line (blank lines dropped)")

        // 3) エンジンの 2 段目ゲート: 非空の指示に customInstructions の権利が
        //    無ければ licenseRequired (followupDraft だけの 0.28.0 相当のクレーム)。
        //    空の要約を渡すためモデルは呼ばれない
        check(await gateFires(
            summary: MeetingSummary(points: ["決めた"], decisions: [], actions: []),
            license: LicenseContext(entitlement: .licenseKey(LicenseKeyClaims(
                v: 1, id: "SELFTEST",
                features: [ProFeature.followupDraft.rawValue]))),
            instructions: ComposerInstructions(tone: "丁寧に")),
            "engine 2nd gate fires without customInstructions entitlement")

        // 4) «実質空» の指示は 2 段目ゲートを通る (followupDraft だけのクレームで
        //    0.28.0 までと同一の動作)
        check(await !gateFires(
            summary: MeetingSummary(points: [], decisions: [], actions: []),
            license: LicenseContext(entitlement: .licenseKey(LicenseKeyClaims(
                v: 1, id: "SELFTEST",
                features: [ProFeature.followupDraft.rawValue]))),
            instructions: ComposerInstructions(tone: "  ")),
            "whitespace-only instructions do not require customInstructions")

        // 5) MAS 相当の権利 (macAppStore) では非空の指示でもゲートを通る
        check(await !gateFires(
            summary: MeetingSummary(points: [], decisions: [], actions: []),
            license: LicenseContext(entitlement: .macAppStore),
            instructions: ComposerInstructions(tone: "丁寧に")),
            "macAppStore entitlement passes the 2nd gate")

        // 6) 課金対象外 (nil = CLI と同じ経路) でもゲートを通る — nil ライセンスで
        //    カスタム指示ゲートが誤発火する回帰を検出する (cubic レビュー指摘)
        check(await !gateFires(
            summary: MeetingSummary(points: [], decisions: [], actions: []),
            license: nil,
            instructions: ComposerInstructions(tone: "丁寧に")),
            "nil license (CLI path) passes the 2nd gate")

        print("selftest: composer-instructions \(total - failures)/\(total) passed")
        if failures > 0 {
            exit(1)
        }
        exit(0)
    }

    /// ゲートが `license` に対して licenseRequired を投げるか。**空の要約**を渡す
    /// と対応環境でもモデル呼び出しに入らない。期待する «ゲート通過» は
    /// `followupEmptySummary` と `Unavailable` のみ — それ以外のエラーは
    /// «通過» と誤認しないよう false (失敗) に数える (cubic レビュー指摘)
    private static func gateFires(
        summary: MeetingSummary,
        license: LicenseContext?,
        instructions: ComposerInstructions?
    ) async -> Bool {
        do {
            _ = try await FollowupComposer.compose(
                summary: summary, license: license, instructions: instructions)
            return false
        } catch let error as KilError {
            if error.code == .followupEmptySummary {
                return false  // ゲートを通って空検査まで進んだ — «通過»
            }
            return error.code == .licenseRequired
        } catch is FollowupComposer.Unavailable {
            return false  // 非対応環境 — 可用性チェックで先に弾かれた («通過»)
        } catch {
            return false  // 予期しないエラーは «通過» と誤認しない (失敗扱い)
        }
    }
}
