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
    /// 復元の実行中。購入と復元の並行実行を防ぐために UI が両ボタンを無効化する
    /// のに使う (cubic レビュー指摘)
    @Published private(set) var isRestoring = false

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
    /// 権利リフレッシュの世代。**古い `currentEntitlements` の列挙結果が後から
    /// 完了して購入後の権利を未購入へ戻す**のを防ぐ (cubic レビュー指摘) —
    /// 列挙中に新しいリフレッシュが始まったら、古い結果は適用しない
    private var entitlementGeneration = 0
    /// 起動後最初の権利判定が済んだか。`pro_unlocked` イベント (issue #456) は
    /// 権利の **false→true への変化** だけを数える — 初回判定で «既に購入済み»
    /// (別端末で買った・再インストール) だった場合は転換ではないので数えない。
    /// enabled=false (セルフテスト) では判定が一度も走らないため false のまま
    private var hasDeterminedEntitlement = false
    /// 購入・復元のフローに入ったことがあるか。**初回の権利判定が適用されるより
    /// 先に購入の結果が適用される** レース (起動直後に購入を終えた場合など) でも
    /// 実際の購入を転換として数えるためのフラグ (cubic レビュー指摘)。
    /// 購入フローに入っていない初回判定は «既に購入済み» の復元のまま扱う
    private var hasEngagedPurchaseFlow = false

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
                    let transaction = try Self.checkVerified(update)
                    // **Pro の商品だけを扱う**。このアプリにはチップ (kilde.tip.*) の
                    // リスナー (TipCoordinatorAppStore) が別にいて、同じ
                    // Transaction.updates を見ている — 相手の商品をここで finish すると
                    // 縄張りを壊す (CodeRabbit 指摘)。非消耗型の finish は
                    // «権利を付与した» のしるし (購入直後は purchase 側でも finish する)
                    guard transaction.productID == Self.productID else { continue }
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
    /// 購入・復元の後に呼ぶ。**オフラインで動く** (ローカルのレシート検証のみ)。
    /// - Returns: 適用したスナップショットの権利。自分より新しいリフレッシュに
    ///   追い越されて **適用を捨てたときは nil** (呼び出し側がこの結果で判定を
    ///   下せないことを表す — restore の «未購入» 判定など)
    @discardableResult
    func refreshEntitlements() async -> Bool? {
        guard enabled else { return nil }
        entitlementGeneration += 1
        let generation = entitlementGeneration
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(entitlement),
                  transaction.productID == Self.productID else { continue }
            unlocked = true
        }
        // 列挙中に自分より新しいリフレッシュが始まっていたら、この (古い)
        // スナップショットは捨てる — 例: ポップオーバー表示でのリフレッシュが
        // 購入完了のリフレッシュと並走し、後から空の結果で上書くのを防ぐ
        guard generation == entitlementGeneration else { return nil }
        // 非消耗型は権利が続く限り currentEntitlements に載り続ける (返金されると
        // 載らなくなる)。ここでは finish しない — 権利の付与は購入時に済んでいる
        let wasUnlocked = isUnlocked
        isUnlocked = unlocked
        license = LicenseContext(
            entitlement: unlocked ? .macAppStore : .none)
        // 権利の false→true 遷移 = この端末で Pro になった瞬間 (購入・復元・
        // Transaction.updates の全経路でここに集約 — issue #456)。初回判定は
        // «既に購入済み» の復元になりうるため、転換として数えない — ただし
        // 購入・復元のフローに入った後なら、それが初回判定であっても
        // この端末での購入 (復元) の結果なので数える
        if hasDeterminedEntitlement || hasEngagedPurchaseFlow {
            if unlocked, !wasUnlocked {
                UsageAnalytics.proUnlocked()
            }
        }
        hasDeterminedEntitlement = true
        return unlocked
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
        // enabled=false (セルフテスト) でも商品の取得は StoreKit へのネットワーク
        // アクセスになるため、ここで止める (cubic レビュー指摘)。isPurchasing は
        // **商品の取得より前**に立てる — 取得中の連打で購入が並行するのを防ぐため
        guard enabled, !isPurchasing, !isRestoring else { return }
        isPurchasing = true
        purchaseFailed = false
        hasEngagedPurchaseFlow = true
        UsageAnalytics.proPurchaseStarted()
        defer { isPurchasing = false }
        let product: Product
        do {
            // 商品の取得と購入は失敗の種別が違うので do を分ける (issue #456 —
            // 取得失敗を purchase_error に混ぜると内訳が読めない)
            let products = try await Product.products(for: [Self.productID])
            guard let fetched = products.first else {
                purchaseFailed = true
                UsageAnalytics.proPurchaseFailed(reason: .productUnavailable)
                return
            }
            product = fetched
        } catch {
            purchaseFailed = true
            UsageAnalytics.proPurchaseFailed(reason: .productUnavailable)
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // 非消耗型: finish で «権利を付与した» と宣言し、権利を組み立て直す。
                    // 完了のイベント (pro_unlocked) は refreshEntitlements の遷移で
                    // 送る — 経路を購入に限定しないため (issue #456)
                    await transaction.finish()
                    await refreshEntitlements()
                case .unverified:
                    // 署名検証に通らなかった購入。決済が完了している可能性があるため
                    // «失敗» の補助行は出さない (再購入を促さない) — finish もせず、
                    // Transaction.updates のリスナーが次回の回収で検証し直す
                    break
                }
            case .userCancelled:
                UsageAnalytics.proPurchaseCancelled()
            case .pending:
                // 承認待ち (Ask to Buy 等)。権利は承認後に Transaction.updates から
                // 届くため、イベントもここでは «保留» だけ数える
                UsageAnalytics.proPurchasePending()
            @unknown default:
                break
            }
        } catch {
            purchaseFailed = true
            UsageAnalytics.proPurchaseFailed(reason: .purchaseError)
        }
    }

    /// 購入の復元 (App Store の «購入済みの項目を復元»)。買い切りの再インストール・
    /// 別 Apple ID への引越しで使う。`AppStore.sync` はレシートの再取得を強制する
    /// だけのオフライン安全な操作
    func restore() async {
        // 購入中の並行実行を許さない (AppStore.sync と購入シートの競合 — cubic 指摘)
        guard enabled, !isPurchasing, !isRestoring else { return }
        isRestoring = true
        restoreFailed = false
        hasEngagedPurchaseFlow = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            // 適用結果で判定する — isUnlocked を読むと、この refresh が新しい
            // リフレッシュに追い越されて**古い権利のまま**のときに誤って
            // «未購入» と数えてしまう (cubic レビュー指摘)。nil は判定の保留
            let applied = await refreshEntitlements()
            if applied == false {
                // 同期は成功したが権利が無い = この Apple ID では未購入
                restoreFailed = true
                UsageAnalytics.proRestoreFailed(reason: .notPurchased)
            }
            // 復元で権利が付いた場合は refreshEntitlements の遷移が pro_unlocked
            // を送る (購入と同じ集約地点 — issue #456)
        } catch {
            restoreFailed = true
            UsageAnalytics.proRestoreFailed(reason: .syncError)
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
