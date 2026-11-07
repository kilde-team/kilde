import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import KildeCore

/// 録画ライブラリ (issue #165) の録画と文字起こしを Spotlight 索引へ登録する (issue #502)。
/// «Spotlight から直接録画を探せる» ようにするのが目的で、索引に載せるのは
/// «ライブラリの走査で見つかった録画» (LibraryStore.scan の結果) だけ。
///
/// **索引は端末内にのみ保存され、外部には何も送らない** (#165 の «索引はローカルのみ»
/// と同じ立付け。PRIVACY.md «Spotlight 索引» 参照)。ユーザーは設定で止められ、
/// オフにしたら即座に索引から消す (SpotlightPreferences.setEnabled の呼び出し側)。
///
/// 構成は 2 層:
/// - `SpotlightItemFactory` — CSSearchableItem の生成と差分計算の **純関数**。
///   セルフテスト (SelfTestSpotlight) からこの層だけを触らせ、実機の
///   Spotlight 索引を汚さない
/// - `SpotlightExporter` — CSSearchableIndex への反映 (actor で直列化)。
///   登録の契機は «ライブラリ再走査» «アプリ起動» «文字起こし完了» の 3 つ

/// Spotlight への登録の可否 (issue #502)。UserDefaults が正本。
/// **キーが無ければオン** (TelemetryPreferences と同じ規約 — `bool(forKey:)` は
/// 未設定で false を返すため使わない。素朴に読むと既存ユーザーがアップデート直後に
/// «オフ扱い» になる)。MAS 版はコンテナ内の UserDefaults に保存される
enum SpotlightPreferences {

    /// UserDefaults のキー。他の GUI ローカル設定 (usageTelemetryEnabled など) と
    /// 同じ camelCase
    static let enabledKey = "spotlightIndexingEnabled"

    /// 登録が許可されているか。キーが無ければ true («既定オン»)
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? true
    }

    /// 設定を保存する。索引への反映 (オフ → 全消去 / オン → 次の走査で再登録) は
    /// 呼び出し側 (SettingsPaneView) が SpotlightExporter に依頼する
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }
}

/// CSSearchableItem の生成と差分計算 (issue #502)。**実機の Spotlight 索引には
/// 触れない純関数** — SelfTestSpotlight がこの層だけを検証するのは、
/// «セルフテストの起動で開発機の Spotlight 索引が書き換わる» を避けるため。
/// 実際の検索・クリック経路は手動確認 (issue #502 の受け入れ条件)
enum SpotlightItemFactory {

    /// 文字起こし本文を索引に載せるときの上限 (文字数)。
    /// Spotlight の textContent に上限の仕様は無いが、長大な文字列は索引の
    /// 構築コストとメモリに効く。日本語の会議 1 時間 ≈ 2 万字程度、3 時間会議でも
    /// 6 万字に届かない実感値から «ほとんどの会議が丸ごと載る» 10 万字にした。
    /// 超えた分は載らない (検索対象から外れるだけ — 切り詰めたことは索引に現れないが、
    /// «後ろの方だけ探せない» という限界は PR に明記する)
    static let textContentLimit = 100_000

    /// CSSearchableItem の domainIdentifier。将来 «要約» など別種を索引に載せるときの
    /// 区分け。削除も domain 単位 (`deleteSearchableItems(withDomainIdentifiers:)`) に
    /// 出来るように固定文字列にする
    static let domainIdentifier = "recording"

    /// Spotlight のクリックで渡るユーザーアクティビティの型
    static var activityType: String { CSSearchableItemActionType }

    /// 差分計算の結果。`delete` は «録画が消えた・あるいは fingerprint が変わって
    /// 置き換わる» item の identifier。`index` は «新規・変更» の item
    struct DiffPlan {
        let delete: [String]
        let index: [CSSearchableItem]
        /// 反映成功後に保存すべき新しい manifest (fingerprint の台帳)
        let manifest: [String: String]
    }

    // MARK: - 差分

    /// manifest (itemID → fingerprint の台帳) と現在の走査結果から差分を作る。
    /// **変更も «delete → index» ではなく «index だけ»** — CSSearchableIndex は同じ
    /// uniqueIdentifier の index で置き換えるため、削除し直す必要が無い。
    /// delete は «manifest にあって今回の走査に無い» 分だけ。
    /// fingerprint が取れない録画 (読めない等) は新規には登録せず、
    /// manifest に残っていたら削除対象にする («索引の内容が実ファイルと乖離しない» 優先)
    static func diff(manifest: [String: String],
                     entries: [LibraryEntry]) -> DiffPlan {
        var fingerprints: [String: String] = [:]
        var items: [CSSearchableItem] = []
        var changed: [String] = []
        for entry in entries {
            let identifier = Self.identifier(for: entry)
            guard let fingerprint = Self.fingerprint(for: entry) else {
                // fingerprint が取れない = 実ファイルが読めない。旧 manifest に
                // あれば削除する (走査から消えているのと同じ扱い)
                if manifest[identifier] != nil { changed.append(identifier) }
                continue
            }
            fingerprints[identifier] = fingerprint
            if manifest[identifier] != fingerprint {
                if let item = Self.makeItem(for: entry) {
                    items.append(item)
                }
            }
        }
        // «manifest にあって今回無い» ものと «読めなくなった» ものを削除する
        let stale = manifest.keys.filter { fingerprints[$0] == nil }
        return DiffPlan(
            delete: Array(Set(stale).union(changed)).sorted(),
            index: items,
            manifest: fingerprints)
    }

    /// 差分検出のための fingerprint。録画とサイドカーの «更新時刻 + サイズ»。
    /// 内容ハッシュは GB 級の録画を読むことになるため使わない —
    /// «文字起こしが変わったら索引を更新する» の検出には更新時刻で十分。
    /// サイドカーが無い録画は録画側の時刻とサイズだけ («文字起こしなし» の録画も
    /// タイトル・日時・長さは載せる。文字起こしが後から付いたらサイドカーの時刻が
    /// 変わるので差分で検出して更新する)
    static func fingerprint(for entry: LibraryEntry) -> String? {
        // resourceValues(forKeys:) は Set<URLResourceKey> を受け取る ([…][] ではなく)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let recording = (try? entry.recordingURL.resourceValues(forKeys: keys))
        guard let recordingModified = recording?.contentModificationDate else { return nil }
        let recordingSize = recording?.fileSize ?? 0
        var sidecarPart = "none"
        if let sidecarURL = entry.transcriptURL {
            let sidecar = (try? sidecarURL.resourceValues(forKeys: keys))
            if let modified = sidecar?.contentModificationDate {
                sidecarPart = "\(modified.timeIntervalSince1970)|\(sidecar?.fileSize ?? 0)"
            }
        }
        return "\(recordingModified.timeIntervalSince1970)|\(recordingSize)|\(sidecarPart)"
    }

    /// CSSearchableItem の uniqueIdentifier。録画ファイルの絶対パス —
    /// «この録画» を一意に指す安定した値で、Spotlight のクリック (アクションの
    /// identifier) から URL を復元できることが唯一の要件
    static func identifier(for entry: LibraryEntry) -> String {
        entry.recordingURL.path
    }

    /// Spotlight のクリックで渡された NSUserActivity から録画の URL を復元する。
    /// kilde 以外 (他アプリの Spotlight アイテム) や形が違うものは nil
    ///
    /// userInfo のキーは **macOS では `CSSearchableItemActivityIdentifier`** —
    /// «ActionIdentifier» という名前は iOS のドキュメント・定数で、macOS の
    /// CoreSpotlight ヘッダには存在しない (CSSearchableItem.h のコメントが
    /// «CSSearchableItemActivityIdentifier is the key» と明示。定数名を iOS 記事の
    /// まま書くと macOS ビルドだけが «cannot find in scope» で落ちる)
    static func recordingURL(fromActivity activity: NSUserActivity) -> URL? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        return URL(fileURLWithPath: identifier)
    }

    // MARK: - アイテム生成

    /// LibraryEntry から CSSearchableItem を作る。fingerprint が取れない録画は
    /// nil (diff が「登録しない」を決める — ここでもnilを返して二重に判定させない)
    static func makeItem(for entry: LibraryEntry) -> CSSearchableItem? {
        guard Self.fingerprint(for: entry) != nil else { return nil }
        // macOS の init(contentType:) は **non-optional UTType** (SDK ヘッダの
        // initWithContentType: の実測)。未知の拡張子は .data («書類» の一般アイコン)
        // に落ちる — nil を渡す経路は作らない
        let attributes = CSSearchableItemAttributeSet(
            contentType: Self.contentType(of: entry) ?? .data)
        // タイトルは一覧 (LibraryEntryRow) と同じ «ファイル名の stem» —
        // «ライブラリで見えているものがそのまま Spotlight に出る» のが最も分かりやすい
        attributes.title = entry.recordingURL.deletingPathExtension().lastPathComponent
        // 説明行は «録画日時 · 長さ»。日時は一覧と同じスタイル (medium + short)
        attributes.contentDescription = description(for: entry)
        // 録画日時。Spotlight の «日付» 絞り込みが効くのはここ
        attributes.contentCreationDate = entry.recordedAt
        // 長さ (秒)。サイドカーの最終セグメント終了時刻由来の近似値
        // (LibraryEntry.duration のコメント参照) — 索引にはその近似を載せる
        if let duration = entry.duration {
            attributes.duration = NSNumber(value: duration)
        }
        // 文字起こしの本文。**ここが «発言の中身で探せる» の本体**。
        // セグメントを改行でつなげた全体を載せる (上限は textContentLimit のコメント)
        if let segments = entry.segments, !segments.isEmpty {
            let text = segments.map(\.text).joined(separator: "\n")
            attributes.textContent = String(text.prefix(Self.textContentLimit))
        }
        // キーワード。アプリ名を入れると Spotlight の «kilde» 入力でも録画が引ける
        attributes.keywords = ["kilde"]
        return CSSearchableItem(
            uniqueIdentifier: Self.identifier(for: entry),
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributes)
    }

    /// 走査結果の一括生成。fingerprint が取れない録画はスキップされる
    static func makeItems(from entries: [LibraryEntry]) -> [CSSearchableItem] {
        entries.compactMap { makeItem(for: $0) }
    }

    // MARK: - 表示用の補助

    /// 説明行 («録画日時 · 長さ»)。Spotlight の結果リストに title の下に載る。
    /// 日付の整形は LibraryEntryRow (一覧) と同じ medium + short —
    /// «一覧と Spotlight で同じ読み方» を揃える
    static func description(for entry: LibraryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var parts = [formatter.string(from: entry.recordedAt)]
        if let duration = entry.duration {
            let total = Int(duration.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            parts.append(hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds))
        }
        return parts.joined(separator: " · ")
    }

    /// 拡張子からの UTType。未知の拡張子は data (詳細 UI では «書類» に落ちるだけ)
    static func contentType(of entry: LibraryEntry) -> UTType? {
        UTType(filenameExtension: entry.recordingURL.pathExtension)
    }
}

/// CSSearchableIndex への反映 (issue #502)。**actor による非再入の直列化** —
/// «ライブラリ再走査» «アプリ起動» «文字起こし完了» «設定トグル» がほぼ同時に走ると、
/// manifest (台帳) の読み書きと delete/index の順序が競合する。
///
/// ここでの競合で起きうる最悪の事例 (cubic レビュー指摘): «オフへの切替
/// (clearAll) の最中に、先に走り出していた同期が後から索引を書き戻す»。
/// Swift の actor は `await` で **再入する** ので、actor にしただけでは
/// この順序は守られない — そこで `acquire()` / `release()` による
/// 排他区間 (バトン渡しの待合室) を設け、sync / clearAll の本体を
/// **最後まで走り切ってから次の操作を開始する** 構造にしている。
/// あわせて `sync(directory:)` の走査を排他区間の **内側** で行うことで、
/// «古い走査結果が新しい索引を上書きする» も同時に防いでいる
/// (CodeRabbit レビュー指摘 — 世代チェックよりも走査の直列化の方が単純で、
/// «走査と反映が同じスナップショット» を構造的に保証できる)
actor SpotlightExporter {

    /// LibraryStore / AppDelegate / SettingsPaneView から触る窓口。
    /// 状態は UserDefaults (設定・manifest) と Spotlight 索引 (本体) にあり、
    /// このインスタンスはそれらの窓口に過ぎないため singleton でよい
    static let shared = SpotlightExporter()

    /// manifest の UserDefaults キー。itemID → fingerprint の台帳。
    /// «前回登録した内容» を覚えておくことで、走査のたびの全件再登録を避ける。
    /// 反映が **成功したときだけ** 書き換える — 失敗時に書くと «登録できていないのに
    /// 登録済み» になり、その差分が永遠に反映されない
    private static let manifestKey = "spotlightIndexManifest"

    private let index = CSSearchableIndex.default()

    // MARK: - 排他区間 (非再入)

    /// «誰かが排他区間にいる» ことを示すフラグ。バトン渡しのため、
    /// «待っていた次の操作に直接引き渡す» 間は true のまま保つ
    private var isBusy = false

    /// 排他区間の解放を待っている操作の待合室。release() が先頭にバトンを渡す
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 排他区間に入る。空いていれば即入場、いれば待合室で自分の番を待つ。
    /// **await で再入してもこの 2 つは素通りできない** — 番が来た操作だけが
    /// 先へ進むため、await をまたぐ処列が完全に直列化される
    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // release() が resume でバトンを渡してきた — この時点で自分が区間の持ち主
    }

    /// 排他区間を出る。待合室にいれば先頭へバトンを渡し (フラグは true のまま)、
    /// いなければフラグを下ろす。呼び出し側は defer で必ず通す
    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    // MARK: - 登録

    /// 走査結果を Spotlight 索引へ反映する («ライブラリを開いた» 経路 —
    /// LibraryStore.reload が走査結果をそのまま渡す)。
    /// 設定がオフなら何もしない («オフの間の走査が索引を作らない»)。**オフ判定は
    /// 自分の番が来たときに取り直す** — 待合室で待っている間にトグルが切られたら
    /// その同期は何もしないで降りる (cubic / CodeRabbit レビュー指摘)。
    /// 反映は best-effort — Spotlight は補助的な入口なので、失敗を UI に
    /// 出さず次回の走査で再試行する (manifest を進めないことで «未反映» が残る)
    func sync(entries: [LibraryEntry]) async {
        await acquire()
        defer { release() }
        guard SpotlightPreferences.isEnabled() else { return }
        await apply(entries: entries)
    }

    /// ディレクトリを走査してから sync する («ライブラリを開いていない» 経路 —
    /// アプリ起動時と文字起こし完了 — のための入り口)。
    /// 走査を **排他区間の内側** で行う — «走査と反映が同じスナップショット» を
    /// 構造的に保証し、古い走査結果が新しい索引を壊す競合を防ぐ
    /// (CodeRabbit レビュー指摘への対応)。
    /// 走査が失敗した (nil) ときは索引に **何もしない** — «読めないフォルダ» を
    /// «空のフォルダ» と誤認して全件削除する経路を塞ぐため (CodeRabbit レビュー指摘)。
    /// 一時的な読み取り失敗は次回の走査で再試行される
    func sync(directory: URL) async {
        await acquire()
        defer { release() }
        guard SpotlightPreferences.isEnabled() else { return }
        let entries = await Task.detached {
            LibraryStore.scan(directory: directory)
        }.value
        guard let entries else {
            print("spotlight: scan failed, skipping sync (\(directory.lastPathComponent))")
            return
        }
        await apply(entries: entries)
    }

    /// 差分を組み立てて索引へ反映し、成功したら manifest を進める。
    /// **排他区間の内側からだけ呼ばれる** (呼び出し側で acquire 済み)。
    /// «削除は成功・登録は失敗» のときも manifest は進めない —
    /// 次回の走査で登録だけが再試行される (削除の再実行は冪等)
    private func apply(entries: [LibraryEntry]) async {
        let defaults = UserDefaults.standard
        let manifest = defaults.dictionary(forKey: Self.manifestKey)
            as? [String: String] ?? [:]
        let plan = SpotlightItemFactory.diff(manifest: manifest, entries: entries)
        do {
            if !plan.delete.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: plan.delete)
            }
            if !plan.index.isEmpty {
                try await index.indexSearchableItems(plan.index)
            }
        } catch {
            print("spotlight: sync failed: \(error)")
            return
        }
        defaults.set(plan.manifest, forKey: Self.manifestKey)
    }

    // MARK: - 消去

    /// 索引を全消去する (設定をオフにしたとき)。manifest も消す —
    /// «オンに戻したら次の走査で全部再登録» のためには台帳を空にする必要がある。
    /// manifest の消去は **消去が成功したときだけ** 行う (CodeRabbit レビュー指摘) —
    /// 消去に失敗したのに台帳を消すと «索引には残っているのに、次回の再登録で
    /// 消えた録画の残骸が二度と掃除されない» 状態になる。台帳を残しておけば、
    /// オンに戻したときの差分同期が «実在しない録画» を削除対象として拾う
    /// («オフの間に消去が失敗し続けた場合の自動再試行はしない» — 索引が
    /// 使えない状態は稀で、再試行のために常時起動の監視を足すほどのものではない。
    /// 失敗はログで確認できる)
    func clearAll() async {
        await acquire()
        defer { release() }
        do {
            try await index.deleteAllSearchableItems()
            UserDefaults.standard.removeObject(forKey: Self.manifestKey)
        } catch {
            print("spotlight: clearAll failed: \(error)")
        }
    }
}
