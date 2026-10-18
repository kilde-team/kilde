#if APPSTORE
import Foundation
import StoreKit

/// App Store 配布ビルドのチップ購入 (issue #171)。
/// 消耗型 IAP 3 段階 (kilde.tip.small / kilde.tip.medium / kilde.tip.large) を
/// ポップオーバー最下部の «アプリを応援» セクションから買えるようにする。
/// «無料利用者の体験を損なわない» (issue 本文) のため、商品一覧が取れないときは
/// セクションごと非表示になり、購入のキャンセル・失敗もアラートを出さず
/// 補助行の文言だけで静かに済ませる。直接配布 (DMG) 版はこの実装を
/// コンパイルしない (TipCoordinator.swift のスタブ — StoreKit は App Store
/// 経由の購入にしか使えないため)
@MainActor
final class TipCoordinator: ObservableObject {
    /// チップの表示内容。価格の昇順 (小 → 大) に整列する
    @Published private(set) var items: [TipItem] = []
    @Published private(set) var isPurchasing = false
    /// 直近の購入成功。«ありがとう» の一時表示に使い、数秒で nil に戻る
    @Published private(set) var lastPurchasedID: String?
    /// 購入の開始に失敗した (ネットワーク等)。補助行の案内表示に使う
    @Published private(set) var purchaseFailed = false

    /// 商品一覧が取れていない (取得失敗 or 取得前)。UI はセクションごと隠す
    var isUnavailable: Bool { items.isEmpty }

    /// id → Product。purchase は UI から TipItem で受けるため引き直すのに使う
    private var productsByID: [String: Product] = [:]
    private let productIDs = [
        "kilde.tip.small",
        "kilde.tip.medium",
        "kilde.tip.large",
    ]

    /// false の場合は商品を取りにいかない (セルフテスト向け — AppDelegate は !SelfTest.isActive を渡す)
    private let enabled: Bool

    /// Transaction.updates の listen タスク。startListening が 1 回だけ始める
    private var updatesTask: Task<Void, Never>?

    /// loadProducts の二重発火 (onAppear と kildePopoverDidShow が連続する) を
    /// 吸収するためのフラグ
    private var isLoading = false

    init(enabled: Bool) {
        self.enabled = enabled
        // 購入フローの外で完了・未完了になったトランザクション (.pending の承認待ちが
        // 後から承認された、アプリ停止中に残った未 finish など) を回収する。
        // このアプリの IAP はチップのみなので、ここで finish するのはすべてチップの
        // トランザクション (エンタイトルメントの保持は不要 — 消耗型のため finish のみ)
        startListening()
    }

    /// Transaction.updates を listen し続ける。init から 1 回だけ始める
    private func startListening() {
        guard enabled, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try Self.checkVerified(update)
                    await transaction.finish()
                } catch {
                    // 検証に通らなかったトランザクションは finish しない
                    // (StoreKit が次回起動時に再検証する)
                }
            }
        }
    }

    /// ポップオーバーを開くたびに呼ぶ (onAppear / kildePopoverDidShow)。
    /// 既に取れている場合は打ち直さない — 開くたびに ASC を叩く必要はなく、
    /// 商品が ASC から消えることもない。失敗時は次回の表示で再試行する
    func loadProducts() async {
        // «全件取得済み» のときだけ no-op にする — 一部の商品だけ取れた場合
        // (審査中の商品が一覧に出ない等) は、ポップオーバーを開くたびに残りを
        // 再取得する (CodeRabbit レビュー指摘)
        guard enabled, productsByID.count < productIDs.count, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: productIDs)
            productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            items = products
                .sorted { $0.price < $1.price }
                .map { TipItem(id: $0.id, title: $0.displayName, price: $0.displayPrice) }
        } catch {
            // 取れないときは静かに諦める。セクションは出ない (isUnavailable)
        }
    }

    func purchase(_ item: TipItem) async {
        guard !isPurchasing, let product = productsByID[item.id] else { return }
        isPurchasing = true
        purchaseFailed = false
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // 消耗型のためトランザクションは finish するだけ (所有権の保持は不要)
                    await transaction.finish()
                    celebrate(item.id)
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

    /// «ありがとう» を表示して数秒で消す。連続購入でも上書きして構わない
    private func celebrate(_ id: String) {
        lastPurchasedID = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.lastPurchasedID == id {
                self?.lastPurchasedID = nil
            }
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            // 署名検証に通らなかったトランザクションは購入として扱わない。
            // finish もしない (StoreKit が次回起動時に再検証する)
            throw StoreKitError.unknown
        case .verified(let safe):
            return safe
        }
    }
}

/// «アプリを応援» セクションに表示するチップ 1 件分。
/// StoreKit の Product をビューに直接晒さず、表示に必要な値だけを
/// 切り出す (DMG 版のスタブとこの型を共有する)
struct TipItem: Identifiable, Equatable {
    let id: String
    /// StoreKit の displayName («小さなチップ» 等)
    let title: String
    /// StoreKit の displayPrice («¥160» — 端末のストアフロント通貨)
    let price: String
}
#endif
