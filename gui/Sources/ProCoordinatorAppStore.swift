#if APPSTORE
import Foundation
import KildeCore
import StoreKit

/// App Store 配布ビルドの Pro (要約) の購入と権利 (issue #169 / #170)。
/// 非消耗型 «kilde.pro» を買い切りで販売する (¥2,800 — MONETIZATION.md §8)。
///
/// 権利の正本は StoreKit 2 の `Transaction.currentEntitlements`。ここで
/// `LicenseContext` に組み立ててエンジン (MeetingSummarizer のゲート —
/// kilde-cli-swift#135) へ渡す。**判定の実体は private エンジン側にあり、公開
/// GUI は権利の «運搬» だけを行う** (MONETIZATION.md §8 — 公開コードに DRM が
/// 現れない)。検証はオフライン完結: currentEntitlements は OS が Apple 署名の
/// JWS を検証済みのトランザクションだけを返し、電話ホーム・テレメトリはしない
/// (§8.4)。直接配布 (DMG) 版はこの実装をコンパイルしない
/// (ProCoordinator.swift のスタブ)
@MainActor
final class ProCoordinator: ObservableObject {
    /// Pro 権利を持っているか。UI のロック表示 (issue #170) はこれで切り替わる
    @Published private(set) var isUnlocked = false
    /// 購入導線の表示内容。商品が取れていないときは nil (導線に価格を出せない)
    @Published private(set) var purchaseItem: ProPurchaseItem?
    @Published private(set) var isPurchasing = false
    /// 購入の開始に失敗した (ネットワーク等)。導線の補助行に使う
    @Published private(set) var purchaseFailed = false
    /// 復元の失敗。導線の補助行に使う (成功は isUnlocked が語る)
    @Published private(set) var restoreFailed = false

    /// エンジンへ渡す権利。起動時に必ず明示的に組み立てる («まだ判定していない»
    /// を既定値に倒さない — kilde-cli-swift CLAUDE.md §6 と同じ規約)。
    /// 未購入の間は `.none` (自己ビルドもレシートが無くここになる —
    /// SPIKE-NOTES F-P の実測)
    private(set) var license: LicenseContext = LicenseContext(entitlement: .none)

    /// 買い切り Pro の商品 ID。**ASC の非消耗型 IAP («kilde Pro» ¥2,800) と
    /// 一致させる契約**。チップ (kilde.tip.*) と同じ «kilde.» 名前空間
    static let productID = "kilde.pro"

    /// false の場合は StoreKit に一切触れない (セルフテスト向け — AppDelegate は
    /// !SelfTest.isActive を渡す。TipCoordinator と同じ理由)
    private let enabled: Bool

    /// Transaction.updates の listen タスク。init から 1 回だけ始める
    private var updatesTask: Task<Void, Never>?

    /// loadProduct の二重発火 (onAppear と kildePopoverDidShow が連続する) を
    /// 吸収するためのフラグ (TipCoordinator と同じ)
    private var isLoadingProduct = false

    init(enabled: Bool) {
        self.enabled = enabled
        // 購入フローの外で権利が変わったとき (別デバイスで購入・承認待ちの解消・
        // 返金) を拾う。未 finish のトランザクションもここで回収する
        startListening()
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Transaction.updates を listen し続ける。init から 1 回だけ始める
    private func startListening() {
        guard enabled, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do {
                    // 非消耗型: finish は «権利を付与した» のしるし。ここに来るのは
                    // 購入直後 (purchase でも finish する — 二重 finish は StoreKit が
                    // 吸収する) か、承認待ち (.pending) の解消後
                    let transaction = try Self.checkVerified(update)
                    await transaction.finish()
                } catch {
                    // 検証に通らなかったトランザクションは finish しない
                    // (StoreKit が次回起動時に再検証する)
                }
                await self.refreshEntitlements()
            }
        }
    }

    /// currentEntitlements から権利を組み立て直す。起動時・ポップオーバー表示時・
    /// 購入・復元の後に呼ぶ。**オフラインで動く** (ローカルのレシート検証のみ)
    func refreshEntitlements() async {
        guard enabled else { return }
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(entitlement),
                  transaction.productID == Self.productID else { continue }
            unlocked = true
        }
        // 非消耗型は権利が続く限り currentEntitlements に載り続ける (返金されると
        // 載らなくなる)。ここでは finish しない — 権利の付与は購入時に済んでいる
        isUnlocked = unlocked
        license = LicenseContext(
            entitlement: unlocked ? .macAppStore : .none)
    }

    /// ポップオーバーを開くたびに呼ぶ (onAppear / kildePopoverDidShow)。
    /// 価格は変わらないが、審査前後で商品の可視が変わることはあるため
    /// 取れていなければ打ち直す (TipCoordinator.loadProducts と同じ)
    func loadProduct() async {
        guard enabled, purchaseItem == nil, !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            let products = try await Product.products(for: [Self.productID])
            purchaseItem = products.first.map { ProPurchaseItem(price: $0.displayPrice) }
        } catch {
            // 取れないときは静かに諦める。導線は «読み込み中» のまま
        }
    }

    func purchase() async {
        guard !isPurchasing else { return }
        do {
            let products = try await Product.products(for: [Self.productID])
            guard let product = products.first else {
                purchaseFailed = true
                return
            }
            isPurchasing = true
            purchaseFailed = false
            defer { isPurchasing = false }
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // 非消耗型: finish で «権利を付与した» と宣言し、権利を組み立て直す
                    await transaction.finish()
                    await refreshEntitlements()
                case .unverified:
                    // 署名検証に通らなかった購入。決済が完了している可能性があるため
                    // «失敗» の補助行は出さない (再購入を促さない) — finish もせず、
                    // Transaction.updates のリスナーが次回の回収で検証し直す
                    break
                }
            case .userCancelled, .pending:
                // キャンセルは何も言わない。保留 (承認待ち) も同様 — 別途届く通知に任せる
                break
            @unknown default:
                break
            }
        } catch {
            purchaseFailed = true
        }
    }

    /// 購入の復元 (App Store の «購入済みの項目を復元»)。買い切りの再インストール・
    /// 別 Apple ID への引越しで使う。`AppStore.sync` はレシートの再取得を強制する
    /// だけのオフライン安全な操作
    func restore() async {
        guard enabled else { return }
        restoreFailed = false
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isUnlocked {
                // 同期は成功したが権利が無い = この Apple ID では未購入
                restoreFailed = true
            }
        } catch {
            restoreFailed = true
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            // 署名検証に通らなかったトランザクションは権利として扱わない。
            // finish もしない (StoreKit が次回起動時に再検証する)
            throw StoreKitError.unknown
        case .verified(let safe):
            return safe
        }
    }
}

/// 購入導線に表示する Pro の商品 1 件分。StoreKit の Product をビューに直接
/// 晒さず、表示に必要な値だけを切り出す (TipItem と同じ方針)
struct ProPurchaseItem: Equatable {
    /// StoreKit の displayPrice («¥2,800» — 端末のストアフロント通貨)
    let price: String
}
#endif
