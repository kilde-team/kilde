import Foundation
import FirebaseCore
import KildeCore

/// Pro (要約) のライセンスゲート (issue #169 / #170 — エンジンの接続は
/// kilde-cli-swift#135) の UI 無し検証。
///
/// **実録画を伴わない**ため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない (SelfTestTelemetry と同じ位置づけ)。
///
/// 共有の状態には触れない — ProCoordinator / TranscriptionCoordinator は
/// このテスト内で新しく作ったインスタンスだけを検証する (AppDelegate の実物は
/// StoreKit のリスナーを持つため、セルフテストでは作られない = enabled: false と
/// 同じ挙動をここで直接確かめる)。
///
/// 自動で確かめられるのはここまで、という線引き:
/// - **確かめられる**: エンジンのゲートが権利なしで `licenseRequired` を投げること /
///   課金対象外 (nil = CLI と同じ経路) では投げないこと / セルフテスト無効の
///   ProCoordinator が組み立てる初期権利 (ビルド ターゲットごとの期待値) /
///   TranscriptionCoordinator の licenseProvider 既定が «権利なし» (フェイルセーフ)
///   であること
/// - **確かめられない**: MAS ビルドでの実際の購入・復元 (StoreKit の実トランザクション —
///   実機の sandbox / 実 ASC で確認する。ASC に商品 «kilde.pro» が無いと価格も出ない)
///
/// 使い方: `KILDE_GUI_SELFTEST_PRO=1 <GUI>` (SelfTest.runIfRequested から配線)。
/// チェックは MainActor を**塞がずに** await で流す — セマフォ待ちで MainActor を
/// 固めると、ゲートの先 (FoundationModels の可用性確認) が MainActor に戻ろうとした
/// 瞬間に自己デッドロックする (実装中に踏んだ)
@MainActor
enum SelfTestPro {

    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: pro PASS: \(label)")
        } else {
            failures += 1
            print("selftest: pro FAIL: \(label)")
        }
    }

    static func run() {
        // MainActor の実行を止めずに非同期で検証を回し、終わったら終了する
        Task { await runChecks() }
    }

    private static func runChecks() async {
        // 1) エンジンのゲート: 権利なし (.none) は licenseRequired を投げる。
        //    ゲートは summarize の最初の分岐なので、Apple Intelligence の有無に
        //    依らずモデルを呼ばない (kilde-cli-swift の MeetingSummarizerGateTests と
        //    同じ前提 — ここでは GUI バイナリから同じ挙動を確かめる)
        check(await gateFires(for: LicenseContext(entitlement: .none)),
              "engine gate fires for .none")

        // 2) 課金対象外 (nil = CLI と同じ経路) ではゲートが発火しない
        check(await !gateFires(for: nil), "engine gate passes for nil (CLI path)")

        // 3) セルフテスト無効の ProCoordinator が組み立てる初期権利。
        //    直接配布ビルドはスタブ (常にロック解除・directDistribution)、
        //    MAS ビルドは StoreKit に触れないため .none のまま
        //    (refreshEntitlements は enabled: false では no-op — 初期値のまま)
#if APPSTORE
        let pro = ProCoordinator(enabled: false)
        check(!pro.isUnlocked, "MAS build starts locked without StoreKit")
        check(pro.license == LicenseContext(entitlement: .none),
              "MAS build assembles .none without entitlements")
#else
        let pro = ProCoordinator(enabled: false)
        check(pro.isUnlocked, "direct build starts unlocked (free policy)")
        check(pro.license == LicenseContext(entitlement: .directDistribution),
              "direct build assembles directDistribution")
#endif

        // 4) licenseProvider の既定は «権利なし» (フェイルセーフ — 未配線なら
        //    課金対象機能は閉じる。AppDelegate が起動時に必ず配線する)
        check(TranscriptionCoordinator().currentLicense
                  == LicenseContext(entitlement: .none),
              "licenseProvider defaults to .none (fail-safe)")

        // 5) Pro / 要約の計測イベント (issue #456) は Firebase 未初期化 (セルフ
        //    テスト) で呼んでも安全な no-op になること。UsageAnalytics.isEnabled は
        //    FirebaseApp.app() を見るため送信は起こらない — ここで確かめるのは
        //    «呼び出しが落ちない»«Firebase を初期化しない» の 2 点 (実際の送信は
        //    実機の Release ビルドで確認する — SelfTestTelemetry と同じ線引き)
        UsageAnalytics.proUpsellView()
        UsageAnalytics.proPurchaseStarted()
        UsageAnalytics.proPurchaseCancelled()
        UsageAnalytics.proPurchasePending()
        UsageAnalytics.proPurchaseFailed(reason: .productUnavailable)
        UsageAnalytics.proUnlocked()
        UsageAnalytics.proRestoreFailed(reason: .notPurchased)
        UsageAnalytics.summaryStarted(recordingDuration: nil)
        UsageAnalytics.summaryCompleted(recordingDuration: nil, processingTime: nil)
        UsageAnalytics.summaryFailed(
            KilError.failure(.licenseRequired, "selftest"),
            recordingDuration: nil, processingTime: nil)
        UsageAnalytics.summarySkipped(.proRequired, recordingDuration: nil)
        // «未初期化のまま» であることしか機械検証できない (送信の抑止は
        // UsageAnalytics.isEnabled が FirebaseApp.app() を見る構造による —
        // SelfTestTelemetry と同じ線引き)
        check(FirebaseApp.app() == nil,
              "pro/summary analytics calls keep Firebase uninitialized")

        print("selftest: pro PASS=\(6 - failures) FAIL=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// ゲートが `license` に対して licenseRequired を投げるか。
    /// **空の書き起こし**を渡す — ゲートは summarize の最初の分岐なので権利なし
    /// (.none) はここで必ず弾かれ、nil は可用性・空検査のどちらかに行き着く。
    /// 空でない書き起こしを渡すと、nil のケースで**オンデバイスモデルの実呼び出しに
    /// 入ってしまう** (端末の状態次第で完了しない — 実装中に踏んだ)
    private static func gateFires(for license: LicenseContext?) async -> Bool {
        do {
            _ = try await MeetingSummarizer.summarize(
                transcript: [], license: license)
            return false
        } catch let error as KilError {
            return error.code == .licenseRequired
        } catch {
            return false
        }
    }
}
