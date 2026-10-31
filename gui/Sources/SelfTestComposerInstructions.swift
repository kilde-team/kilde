import Foundation
import KildeCore

/// カスタム指示 (issue #472 — 第三弾 Pro) の UI 無し検証。
///
/// **実録画を伴わない** (SelfTestFollowup / SelfTestPro と同じ位置づけ)。確かめるのは:
/// - `RecordingSetup` の入力 → `ComposerInstructions` の写像 («実質空» は nil、
///   強調ポイントの行分割、エンジン側の正規化との整合)
/// - エンジンの 2 段目ゲート (kilde-cli-swift#139): 非空の指示は
///   `customInstructions` の権利なしで `licenseRequired`、nil では投げない
///   (**空の要約**を渡すためモデルは呼ばない)
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
        // 1) 写像: 全項目が空白のみなら nil (ゲートを発火させない «未指定»)
        //    — セルフテストは実環境の UserDefaults を触らない (SelfTest の契約) ため、
        //    値は ComposerInstructions を直接組み立てて確かめる
        check(ComposerInstructions(tone: " ", recipients: "\n", extraPoints: [""])
            .isEmpty, "whitespace-only instructions map to empty")

        // 2) 写像: 値があれば非空 ( RecordingSetup.composerInstructions が nil を
        //    返さない側の代表値)
        check(!ComposerInstructions(tone: "丁寧に").isEmpty,
              "non-empty tone maps to instructions")

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

        print("selftest: composer-instructions \(total - failures)/\(total) passed")
        if failures > 0 {
            exit(1)
        }
        exit(0)
    }

    /// ゲートが `license` に対して licenseRequired を投げるか。**空の要約**を渡す
    /// と対応環境でもモデル呼び出しに入らない (followupEmptySummary / Unavailable
    /// で終わる — SelfTestFollowup.gateFires と同じ前提。違いは instructions を
    /// 渡せること)
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
            return error.code == .licenseRequired
        } catch {
            // Unavailable (非対応環境) / followupEmptySummary は «ゲート通過»
            return false
        }
    }
}
