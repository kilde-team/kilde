#if !APPSTORE
import Foundation

/// 直接配布 (DMG) ビルド用の TipCoordinator スタブ (issue #171)。
/// チップの購入 (消耗型 IAP) は App Store 配布ビルド専用
/// (実体は TipCoordinatorAppStore.swift)。MAS 版と同じ API だけを用意し、
/// ContentView / AppDelegate の呼び出し側を条件分岐なしで共有する。
/// DMG 版では商品を取得しないため «アプリを応援» セクションごと非表示になる。
/// 直接配布版の導線は GitHub Sponsors へのリンクの予定だが、Sponsors への
/// 参加申請 (口座設定) が済んでいないため未実装 — issue #171 の残りのスコープ
@MainActor
final class TipCoordinator: ObservableObject {
    /// チップの表示内容。スタブは常に空 (セクション非表示)
    @Published private(set) var items: [TipItem] = []
    @Published private(set) var isPurchasing = false
    @Published private(set) var lastPurchasedID: String?
    @Published private(set) var purchaseFailed = false

    init(enabled: Bool) {}

    /// no-op。呼び出し側 (ContentView の onAppear 等) は条件分岐なしで共有する
    func loadProducts() async {}

    /// no-op。UI から呼ばれることはない (セクション非表示)。保険として保持する
    func purchase(_ item: TipItem) async {}

    /// MAS 版と同じ判定。セルフテスト (KILDE_GUI_SELFTEST_*) では商品を取らず、
    /// 録画系の検証に ASC へのネットワークアクセスを持ち込まない
    /// (updaterStartsAtLaunch と同じ配慮)
    static func loadsProductsAtLaunch(env: [String: String]) -> Bool {
        !env.keys.contains(where: { $0.hasPrefix("KILDE_GUI_SELFTEST_") })
    }
}

/// «アプリを応援» セクションに表示するチップ 1 件分。
/// MAS 版では StoreKit の Product から、スタブでは作られない。
/// StoreKit の Product をビューに直接晒さないため、両ビルドでこの型を共有する
struct TipItem: Identifiable, Equatable {
    let id: String
    /// StoreKit の displayName («小さなチップ» 等)
    let title: String
    /// StoreKit の displayPrice («¥160» — 端末のストアフロント通貨)
    let price: String
}
#endif
