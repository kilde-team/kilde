#if !APPSTORE
import Foundation
import KildeCore

/// 直接配布 (DMG) ビルド用の ProCoordinator スタブ (issue #169 / #170)。
/// Pro (要約) の購入・権利確認は App Store 配布ビルド専用
/// (実体は `ProCoordinatorAppStore.swift`)。MAS 版と同じ API だけを用意し、
/// ContentView / AppDelegate / TranscriptionCoordinator の呼び出し側を条件分岐
/// なしで共有する (TipCoordinator と同じ構成)。
///
/// 直接配布版は Pro の直接販売 (issue #172) が当面見送りのため **Pro 機能を無料
/// 開放のまま** にする — エンジンの `LicenseContext.Entitlement.directDistribution`
/// (kilde-cli-swift#135。方針の正本は MONETIZATION.md §8 «線引き»)。
/// このスタブは常にロック解除済みを返し、購入導線 (価格の取得) も出ない
@MainActor
final class ProCoordinator: ObservableObject {
    /// 直接配布版は常にロック解除済み (UI のロック表示は出ない)
    @Published private(set) var isUnlocked = true
    /// 購入導線の表示内容。スタブは常に nil (購入 UI に出る価格が無い = 導線なし)
    @Published private(set) var purchaseItem: ProPurchaseItem?
    @Published private(set) var isPurchasing = false
    @Published private(set) var purchaseFailed = false
    @Published private(set) var restoreFailed = false
    @Published private(set) var isRestoring = false

    init(enabled: Bool) {}

    /// エンジンへ渡す権利。直接配布版は無料開放 (directDistribution)
    var license: LicenseContext { LicenseContext(entitlement: .directDistribution) }

    /// no-op。呼び出し側 (ContentView の onAppear 等) は条件分岐なしで共有する
    func refreshEntitlements() async {}

    /// no-op。UI から呼ばれることはない (ロック表示が出ない)。保険として保持する
    func loadProduct() async {}

    /// no-op。同上
    func purchase() async {}

    /// no-op。同上
    func restore() async {}
}

/// 購入導線に表示する Pro の商品 1 件分。MAS 版では StoreKit の Product から
/// 組み立てる。StoreKit の Product をビューに直接晒さないための共有値型
/// (TipItem と同じ方針)。スタブビルドでは作られない
struct ProPurchaseItem: Equatable {
    /// StoreKit の displayPrice («¥2,800» — 端末のストアフロント通貨)
    let price: String
}
#endif
