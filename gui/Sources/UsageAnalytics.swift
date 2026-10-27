import Foundation
import KildeCore
import FirebaseAnalytics
import FirebaseCore

/// 利用状況イベントの窓口。文字起こし (#153) に加え、録画完了 (#159) も見る。
/// «どれだけ使われ、どこで失敗しているか» を Firebase Analytics (#136) で見るための
/// 窓口。AppDelegate の `app_open` と同じく、両ターゲット (直接配布 / MAS) で
/// FirebaseAnalyticsCore をリンクしているため `#if APPSTORE` 分岐は不要
/// (PRIVACY.md «直接配布版・Mac App Store 版の両方» どおり)。
///
/// **送るのは «いつ・何件・どこで失敗したか» と時間の区分のみ。** 文字起こしの
/// テキスト、録画ファイル・サイドカーの名前やパスは絶対に含めない。さらに
/// エラーも «種別» のみで、TranscriptionError の付帯文字列
/// (ロケール ID やパスを含みうる — KildeCore TranscriptSegment.swift の
/// description 参照) と生のエラーメッセージは送らない。
/// 時間は生の秒数ではなく区分で送る — «会議がどれくらいの長さか» «処理が
/// どれくらいかかるか» を知るには区分で十分で、値が粗い方が PRIVACY.md の
/// «利用統計» の枠にとどまる (App Privacy ラベル «製品の操作» も変えない)。
enum UsageAnalytics {

    /// Firebase が初期化済みで、かつユーザーが設定でオフにしていないときだけ送る。
    /// **セルフテストと Debug 構成は configure しない**、**設定オフでは起動時に
    /// configure しない** (AppDelegate.sendsUsageToFirebase 参照) ので、どちらも
    /// ここで跳ねる。未初期化のまま logEvent しても送信は起こらないが、明示して
    /// おくと «セルフテスト・Debug・設定オフでは何も送っていない» が読み取れる。
    /// 実行中にオフへ切替えた直後の呼び出しもここで跳ねる (Firebase 側の収集停止に
    /// 加えての二重のガード — TelemetryPreferences.applyToFirebase 参照)
    private static var isEnabled: Bool {
        FirebaseApp.app() != nil && TelemetryPreferences.isEnabled()
    }

    /// 完了した録画の生涯累計。**区分に変換した値だけを送る** ので生の回数が
    /// Google へ出ることはないが、数え続ける台帳として端末の UserDefaults に置く。
    /// issue #159 の «録画完了 3 回以上のユーザー率» は 1 ユーザーあたりの回数が
    /// 無いと出せない — Firebase コンソールのイベント集計は «何回発火したか» だけで
    /// «何人のユーザーが 3 回以上録ったか» を返さない。キーは «利用統計の内部
    /// カウンタ» であることが読み取れる名前にする (RecordingSetup の設定キーと混ぜない)。
    /// 旧バージョンからの引き継ぎは migrateRecordingCountIfNeeded が行う
    private static let recordingsCompletedKey = "usage_recordings_completed"

    /// 配布チャネル (issue #159 の «チャネル別 (MAS / Homebrew / 直接配布)»)。
    /// **Homebrew は CLI 専用** (formula は `bin.install` のみ) で、CLI は計測しない
    /// 方針 (PRIVACY.md «kilde コマンドラインは解析を行いません») なので、語彙は
    /// 計測できる GUI の 2 チャネル。コンパイル条件で確定する — レシート検証など
    /// 実行時の判別を持ち込むほど、この内訳に精度は要らない
    static var distributionChannel: String {
#if APPSTORE
        return "mas"
#else
        return "direct"
#endif
    }

    /// 起動時に 1 回、ユーザー プロパティを設定する (AppDelegate の app_open と並べる)。
    /// ユーザー プロパティは **直近の値でユーザーを分類する** ので、起動ごとに
    /// 設定し直して最新に保つ。recordings_bucket は端末の累計から復元する —
    /// 録画のたびにしか更新しないと、前回録画時の値のまま取り込まれる恐れがある
    /// (プロパティの反映はコンソールのレポートにまで時間がかかるため、起動時の
    /// 復元で古い値のままでいる期間を減らす)
    static func setUserProperties() {
        guard isEnabled else { return }
        Analytics.setUserProperty(distributionChannel, forName: "distribution_channel")
        // このアプリは 2 ターゲットとも **ネイティブ macOS** (project.yml の
        // platform: macOS) だが、Firebase には **iOS アプリとして** 登録されている
        // («Kilde iOS» ストリーム) ため、GA4 のプラットフォーム / デバイス カテゴリは
        // «iOS» と表示される (GA4 分析 2026-10-12)。«実プラットフォームの真実» を
        // ユーザー プロパティに持たせ、集計はそちらで揃える。将来ビルド構成を足して
        // も語彙が破綻しないよう 3 経路で確定する — コンパイル条件で決まる
        // (distributionChannel と同じく実行時の判別を持ち込まない)。GA4 側の
        // カスタム ディメンション «app_platform» は、この値が届いた後で作る
        // (実在するユーザー プロパティしか選べないため)
        #if os(iOS)
            #if targetEnvironment(macCatalyst)
            // Catalyst は Mac 上で動くので «macos»
            Analytics.setUserProperty("macos", forName: "app_platform")
            #else
            Analytics.setUserProperty("ios", forName: "app_platform")
            #endif
        #else
            // ネイティブ macOS (現在の 2 ターゲットはすべてここ)
            Analytics.setUserProperty("macos", forName: "app_platform")
        #endif
        let defaults = UserDefaults.standard
        migrateRecordingCountIfNeeded(defaults)
        let count = defaults.integer(forKey: recordingsCompletedKey)
        if let bucket = recordingsBucket(count) {
            Analytics.setUserProperty(bucket, forName: "recordings_bucket")
        }
    }

    /// 旧カウンタ (issue #156 の評価依頼が数えた «15 秒以上の録画完了») からの移行。
    /// **キーがまだ無い端末だけで 1 回** 行い、移行の有無はキーの存在で表す —
    /// キーが無いと UserDefaults の読み取りは 0 になるので、移行しないと既存
    /// ユーザーが «0 回» に戻り、生涯累計という KPI の定義が崩れる (CodeRabbit
    /// レビュー指摘)。旧カウンタを書くのは **MAS ビルドだけ** (#156 は App Store の
    /// 評価依頼で、直接配布版の ReviewPromptCoordinator はカウントもしない) ので、
    /// 直接配布版は履歴源が無く 0 から始まる («履歴が無い» は真)。旧カウンタは
    /// 15 秒未満の録画を数えていないため **下振れする** — 短い録画が «3_5» の
    /// 境界を跨ぐ程度で、«定着している» 側に上振れする (0 に戻す) より安全。
    /// 以後は bumpRecordingCount が進める
    private static func migrateRecordingCountIfNeeded(_ defaults: UserDefaults) {
        guard defaults.object(forKey: recordingsCompletedKey) == nil else { return }
#if APPSTORE
        let seeded = defaults.integer(
            forKey: ReviewPromptCoordinator.Keys.successfulRecordings)
#else
        // 直接配布版に書いた旧カウンタは存在しない (上のコメント)
        let seeded = 0
#endif
        defaults.set(seeded, forKey: recordingsCompletedKey)
    }

    /// 録画を始めた (issue #343)。«試行 → 完了» のファネルの始点 —
    /// recording_complete (#159) だけだと «何件完了したか» しか分からず、
    /// 成功率 (どこで諦められているか) が出ない。文字起こしの
    /// transcription_start (#153) と同じ位置づけで、**収録が実際に始まった
    /// 瞬間** に送る (準備中のキャンセルは数えない — 呼び出し側 RecordingController
    /// の recordingStartedAt の初回セットと同じ条件)。チャネルは
    /// recording_complete と同じくイベント パラメータにも載せる。
    ///
    /// `usesAppAudio`: «アプリの音声» を使った構成か (issue #364)。**新規イベントは
    /// 足さず、既存の recording_start のパラメータに語彙を 1 つ足す** — «アプリ別収録が
    /// どれだけ使われるか» は «開始の構成» の属性であって別種の行為ではないため。
    /// 値は "yes" / "no" の 2 値で、**bundleID やアプリ名は絶対に送らない**
    /// (PRIVACY.md «利用統計» の枠 — «何のアプリか» は行動の計測に要らない)
    ///
    /// `windowService`: 収録対象がウィンドウのときの区分 (issue #429)。
    /// **語彙は WindowService の列挙に閉じる** (errorKind / ScreenName と同じ規約) —
    /// 送るのは rawValue (zoom / google_meet / … / other) だけで、ウィンドウの
    /// タイトルや bundleID は送らない。«どのようなサービスが録画されているか» は
    /// 事前に定めたこの区分で十分測れる (PRIVACY.md に記載)。nil は
    /// «ウィンドウ収録ではない (または対象ウィンドウが取れなかった)» で、
    /// パラメータ自体を省略する
    static func recordingStarted(usesAppAudio: Bool, windowService: WindowService?) {
        log("recording_start", recordingDuration: nil,
            processingTime: nil, channel: distributionChannel,
            appAudio: usesAppAudio ? "yes" : "no",
            windowService: windowService?.rawValue)
    }

    /// 録画 1 件が完了した (issue #159)。«月間アクティブ (録画完了) ユーザー数» と
    /// «録画完了 3 回以上のユーザー率» の基礎データ。チャネルはユーザー プロパティ
    /// だけでなくイベントのパラメータにも載せる — «recording_complete の何%が
    /// MAS か» をイベント側だけで読めるようにするため
    static func recordingCompleted(recordingDuration: TimeInterval?) {
        bumpRecordingCount()
        log("recording_complete", recordingDuration: recordingDuration,
            processingTime: nil, channel: distributionChannel)
    }

    /// 完了回数を進めて、区分をユーザー プロパティに反映する。
    ///
    /// カウンタ (UserDefaults) を進める条件とイベント / ユーザー プロパティを送る条件は
    /// **分けている** (cubic レビュー指摘): カウンタは**端末内の台帳**で、送信を伴わない
    /// ため **テレメトリの設定 (オプトアウト — issue #435) には影響されない**。オフの間も
    /// 累計を進めないと、オンに戻した後の `recordings_bucket` が実際より低い区分になる
    /// (docs/metrics.md «0.8.2 以降の完了はすべて数える» とも矛盾する)。対象外は
    /// セルフテストと Debug 構成だけ — 実行環境の録画を実ユーザーの累計に混ぜないため。
    /// ユーザー プロパティの反映 (setUserProperty) は isEnabled のままでよい — 送信の
    /// 一部であり、オフなら届かないのが正しい
    private static func bumpRecordingCount() {
        guard countsLocalRecording else { return }
        let count = UserDefaults.standard.integer(forKey: recordingsCompletedKey) + 1
        UserDefaults.standard.set(count, forKey: recordingsCompletedKey)
        if let bucket = recordingsBucket(count) {
            guard isEnabled else { return }
            Analytics.setUserProperty(bucket, forName: "recordings_bucket")
        }
    }

    /// 端末内の録画完了カウンタを進めてよいか (bumpRecordingCount 専用 — 上のコメント)。
    /// 送信の可否 (isEnabled) とは別物
    private static var countsLocalRecording: Bool {
#if DEBUG
        return false
#else
        return !SelfTest.isActive
#endif
    }

    /// 累計録画完了回数の区分。**返す値はこの関数に閉じる** (recordingLengthBucket と
    /// 同じ規約)。«3 回以上» の判定に使うので 3 の境界をまたがない — 1・2 はそのまま、
    /// 3 以降は荒い区分にする (定着を見るのに «7 回» と «8 回» の違いは要らない)。
    /// **0 («まだ録っていない») も語彙に含める** — 0 を外すと録画したことのない
    /// ユーザーが分布から消え、«3 回以上のユーザー率» の分母が «1 回以上録った
    /// ユーザー» にすり替わる (CodeRabbit レビュー指摘)。分母は «起動したことが
    /// あるユーザー全体» とするのがこの KPI の意図
    static func recordingsBucket(_ count: Int) -> String? {
        guard count >= 0 else { return nil }
        switch count {
        case 0: return "0"
        case 1: return "1"
        case 2: return "2"
        case 3...5: return "3_5"
        case 6...9: return "6_9"
        default: return "10_plus"
        }
    }

    /// 文字起こしの実行に取りかかった (待ち行列に積まれた時点ではなく、
    /// 実行が始まった時点)
    static func transcriptionStarted(recordingDuration: TimeInterval?) {
        log("transcription_start",
            recordingDuration: recordingDuration, processingTime: nil)
    }

    static func transcriptionCompleted(recordingDuration: TimeInterval?,
                                       processingTime: TimeInterval?) {
        log("transcription_complete",
            recordingDuration: recordingDuration, processingTime: processingTime)
    }

    /// 失敗。**エラーは«種別»のみ** (理由: クラスコメント)。
    /// 呼び出し側 (TranscriptionCoordinator.fail) がキャンセルを除外してから呼ぶ —
    /// まぎれて届いた場合も種別は bounded なので壊れない
    static func transcriptionFailed(error: Error, recordingDuration: TimeInterval?,
                                    processingTime: TimeInterval?) {
        log("transcription_fail", recordingDuration: recordingDuration,
            processingTime: processingTime, errorKind: errorKind(error))
    }

    /// «中止»。キャンセルは失敗に数えない方針 (TranscriptionCoordinator.fail 参照) と
    /// 同じく、失敗と別のイベントにする
    static func transcriptionCancelled(recordingDuration: TimeInterval?,
                                       processingTime: TimeInterval?) {
        log("transcription_cancel",
            recordingDuration: recordingDuration, processingTime: processingTime)
    }

    /// 断続的な失敗を **自動で 1 回だけ** やり直した (issue #221)。«自動再試行で
    /// 救われた» 実行は成功イベントにしか現れないため、再現頻度の測定には
    /// このイベントが要る。再試行は失敗でもキャンセルでもない第三の経路なので
    /// 別イベントにする — «失敗» に混ぜると «どこで壊れているか» の解析が誤る
    /// (transcription_cancel と同じ分割)
    static func transcriptionRetry(recordingDuration: TimeInterval?) {
        log("transcription_retry",
            recordingDuration: recordingDuration, processingTime: nil)
    }

    // MARK: - Pro (要約の買い切り) の転換計測 (issue #456 / エピック #174)

    /// 0.26.0 の Pro 実装は購入導線・要約の実行に利用統計を一切出していなかった。
    /// エピック #174 の出口条件 (有料転換 2%) の判定は ASC の IAP 販売数が正本だが、
    /// **アプリ内のファネル (ロック行の露出 → 購入開始 → 完了) と要約の実利用** は
    /// ここにしか現れない。#159 / #343 と同じ位置づけ。
    ///
    /// **購入系 (`pro_*`) は MAS 版だけで発火する** — 直接配布版は
    /// ProCoordinator のスタブで常にロック解除済み (Pro 直接販売 #172 は見送り中の
    /// 無料開放) で、ロック行も購入ボタンも存在しないため。要約系 (`summary_*`) は
    /// 両チャネルで発火する (直接配布版は Pro 無料開放なので要約だけが計測される)。
    /// 価格・金額・トランザクション ID は絶対に送らない (PRIVACY.md «利用統計» の枠)

    /// Pro 未購入のロック行がパネルに表示された。購入ファネルの分母
    /// (impression)。パネルを開くたびに数える
    static func proUpsellView() {
        logParameterless("pro_upsell_view")
    }

    /// 購入ボタンを押して StoreKit の購入フローを開始した
    static func proPurchaseStarted() {
        logParameterless("pro_purchase_start")
    }

    /// ユーザーが購入シートをキャンセルした
    static func proPurchaseCancelled() {
        logParameterless("pro_purchase_cancel")
    }

    /// 購入が承認待ち (Ask to Buy 等) になった。この後の権利付与は
    /// Transaction.updates → refreshEntitlements の遷移で `proUnlocked` に現れる
    static func proPurchasePending() {
        logParameterless("pro_purchase_pending")
    }

    /// 購入の開始に失敗した (商品の取得失敗・StoreKit エラー)。理由は区分のみ
    static func proPurchaseFailed(reason: ProPurchaseFailureReason) {
        logParameterless("pro_purchase_fail", errorKind: reason.rawValue)
    }

    /// 購入の失敗理由。**値はこの列挙に閉じる** (errorKind と同じ規約)
    enum ProPurchaseFailureReason: String {
        /// 商品 (kilde.pro) が StoreKit から取得できない (非公開・ストア不調)
        case productUnavailable = "product_unavailable"
        /// `Product.purchase()` がエラーを投げた (ネットワーク等)
        case purchaseError = "purchase_error"
    }

    /// この端末で Pro の権利が付与された (権利の false→true 遷移。購入・復元・
    /// Transaction.updates のどの経路でもここに 1 回集約する — 経路別の内訳は
    /// `pro_purchase_start` 等の前段イベントで読む)。**起動時の初回判定で
    /// «既に購入済み» だった場合は数えない** (転換ではなく保有の復元なので —
    /// ProCoordinatorAppStore.hasDeterminedEntitlement 参照)
    static func proUnlocked() {
        logParameterless("pro_unlocked")
    }

    /// 購入の復元に失敗した。成功 (未購入 → 権利あり) は `proUnlocked` に現れる
    static func proRestoreFailed(reason: ProRestoreFailureReason) {
        logParameterless("pro_restore_fail", errorKind: reason.rawValue)
    }

    /// 復元の失敗理由。**値はこの列挙に閉じる**
    enum ProRestoreFailureReason: String {
        /// 同期は成功したがこの Apple ID では未購入
        case notPurchased = "not_purchased"
        /// `AppStore.sync()` がエラーを投げた (ネットワーク等)
        case syncError = "sync_error"
    }

    /// 要約の生成を開始した (Pro 権利と環境の確認を通った後。両チャネル)
    static func summaryStarted(recordingDuration: TimeInterval?) {
        log("summary_start", recordingDuration: recordingDuration, processingTime: nil)
    }

    /// 要約の生成が完了した (両チャネル)
    static func summaryCompleted(recordingDuration: TimeInterval?, processingTime: TimeInterval?) {
        log("summary_complete",
            recordingDuration: recordingDuration, processingTime: processingTime)
    }

    /// 要約の生成が失敗した。録画・文字起こしは成功済みで、ジョブ全体は
    /// サイドカーを書かずに失敗する (TranscriptionCoordinator の契約) —
    /// «文字起こしは成功したのに要約で落ちた» 実態を見るためのイベント。
    /// エラーは種別のみ (KilError のコード / Unavailable / モデルエラー)。
    /// **キャンセルは呼び出し側が除外する** (transcription_cancel と同じ
    /// «キャンセルは失敗に数えない» 方針 — ジョブ単位の cancel イベントが
    /// fail 側で送る)。失敗までの所要時間も載せる («どのくらいで落ちたか» が
    /// モデル呼び出しの健全性のヒントになるため)
    static func summaryFailed(
        _ error: Error, recordingDuration: TimeInterval?, processingTime: TimeInterval?
    ) {
        log("summary_fail", recordingDuration: recordingDuration, processingTime: processingTime,
            errorKind: summaryErrorKind(error))
    }

    /// 要約を生成せずにジョブを完了した (録画・文字起こしは成功。両チャネル)。
    /// «要約が生成されなかった» 体験の上位 (Pro 未購入より環境非対応が多い想定)
    static func summarySkipped(_ reason: SummarySkipReason, recordingDuration: TimeInterval?) {
        log("summary_skip", recordingDuration: recordingDuration, processingTime: nil,
            errorKind: reason.rawValue)
    }

    /// 要約が生成されなかった理由。**値はこの列挙に閉じる**
    enum SummarySkipReason: String {
        /// Apple Intelligence が無効・非対応 (macOS 26 未満を含む)
        case unsupportedEnvironment = "unsupported_environment"
        /// Pro 未購入 (返金で権利を失った等 — UI のロックで通常は選べないため稀)
        case proRequired = "pro_required"
    }

    /// 要約の失敗種別。付帯文字列は送らない (errorKind と同じ規約)
    private static func summaryErrorKind(_ error: Error) -> String {
        if let e = error as? KilError {
            switch e.code {
            case .licenseRequired: return "license_required"
            case .summaryEmptyTranscript: return "empty_transcript"
            default: return "engine_error"
            }
        }
        if error is MeetingSummarizer.Unavailable { return "unsupported_environment" }
        // キャンセルは呼び出し側 (TranscriptionCoordinator) が送らないが、
        // まぎれて届いても種別は bounded なので壊れない (transcriptionFailed の
        // cancelled と同じ防御)
        if error is CancellationError { return "cancelled" }
        // Foundation Models の生エラー (GenerationError 等)
        return "model_error"
    }

    /// パラメータなし (または error_kind のみ) のイベント用。録画長などの
    /// バケットを載せる既存 `log` と別にしたのは、Pro のUI 系イベントには
    /// «関連する録画» が無い (ロック行の表示は録画と結び付かない) ため
    private static func logParameterless(_ name: String, errorKind: String? = nil) {
        guard isEnabled else { return }
        var parameters: [String: String] = [:]
        if let errorKind { parameters["error_kind"] = errorKind }
        Analytics.logEvent(name, parameters: parameters)
    }

    /// screen_view の画面名。**この列挙に閉じる** (errorKind と同じ規約) —
    /// 呼び出し側の文字列をそのまま送らない。メニューバー アプリに画面遷移は
    /// 無いので、«開かれた UI» 単位で語彙を増やす
    enum ScreenName: String {
        /// メニューバーのキャプチャ パネル (NSPopover)
        case capturePanel = "capture_panel"
        /// 録画ライブラリのウィンドウ
        case library = "library"
    }

    /// 画面を表示した (issue #343)。`screen_view` が無いと GA4 の «ページと
    /// スクリーン» «ランディング ページ» が `(not set)` のみになり、«表示回数» が
    /// 常に 0 になる (GA4 分析 2026-10-12)。Automatic screen reporting は
    /// ViewController ベースのアプリ向けなので、自分で送る
    static func screenView(_ name: ScreenName) {
        guard isEnabled else { return }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name.rawValue
        ])
    }

    private static func log(_ name: String, recordingDuration: TimeInterval?,
                            processingTime: TimeInterval?, errorKind: String? = nil,
                            channel: String? = nil, appAudio: String? = nil,
                            windowService: String? = nil) {
        guard isEnabled else { return }
        var parameters: [String: String] = [:]
        if let errorKind { parameters["error_kind"] = errorKind }
        if let channel { parameters["channel"] = channel }
        if let appAudio { parameters["app_audio"] = appAudio }
        // 値は呼び出し側で WindowService.rawValue に閉じたものだけが来る
        // (recordingStarted のコメント)。ここでは追加の検証をしない
        if let windowService { parameters["window_service"] = windowService }
        if let bucket = recordingLengthBucket(recordingDuration) {
            parameters["recording_length"] = bucket
        }
        if let bucket = processingTimeBucket(processingTime) {
            parameters["processing_time"] = bucket
        }
        Analytics.logEvent(name, parameters: parameters)
    }

    /// エラーの種別。**返す値はこの列挙に閉じる** — 付帯文字列や localizedDescription
    /// をそのまま送ると、ロケール ID やパスが含まれるおそれがある
    private static func errorKind(_ error: Error) -> String {
        if let e = error as? TranscriptionError {
            switch e {
            case .unavailable: return "unavailable"
            case .unsupportedLocale: return "unsupported_locale"
            case .modelNotInstalled: return "model_not_installed"
            case .noAudioTrack: return "no_audio_track"
            case .cancelled: return "cancelled"
            case .failed: return "engine_error"
            }
        }
        // AVFoundation / ファイルアクセスなど TranscriptionError 以外。
        // 種別としては «エンジン外» で十分で、種類ごとに広げたくなったら
        // この関数を増やす (値の語彙を Analytics 側で増やさない)
        return "system_error"
    }

    /// 録音の長さの区分。境界は «会議» の長さ感覚に合わせる (1 時間超えも 1 区分)。
    /// nil は «不明» (セルフテストの直接 enqueue など) でパラメータ自体を省略する
    static func recordingLengthBucket(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        switch seconds {
        case ..<60: return "lt_1m"
        case ..<300: return "1m_5m"
        case ..<900: return "5m_15m"
        case ..<1800: return "15m_30m"
        case ..<3600: return "30m_1h"
        default: return "gte_1h"
        }
    }

    /// 処理時間の区分。文字起こしは数秒〜数十分かかるので 10 秒から切る
    static func processingTimeBucket(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        switch seconds {
        case ..<10: return "lt_10s"
        case ..<60: return "10s_1m"
        case ..<300: return "1m_5m"
        case ..<1800: return "5m_30m"
        default: return "gte_30m"
        }
    }
}
