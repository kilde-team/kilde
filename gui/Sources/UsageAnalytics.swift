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

    /// Firebase が初期化済みのときだけ送る。**セルフテストと Debug 構成は configure
    /// しない** (AppDelegate.sendsUsageToFirebase 参照) ので、ここで跳ねる。
    /// 未初期化のまま logEvent しても送信は起こらないが、明示しておくと
    /// «セルフテスト・Debug では何も送っていない» が読み取れる
    private static var isEnabled: Bool { FirebaseApp.app() != nil }

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
    /// **isEnabled の下に置く** — セルフテストの録画経路でカウンタを進めない
    /// (UserDefaults はセルフテストで触れたままにしたくないし、setUserProperty も
    /// 届かない方が清潔)
    private static func bumpRecordingCount() {
        guard isEnabled else { return }
        let count = UserDefaults.standard.integer(forKey: recordingsCompletedKey) + 1
        UserDefaults.standard.set(count, forKey: recordingsCompletedKey)
        if let bucket = recordingsBucket(count) {
            Analytics.setUserProperty(bucket, forName: "recordings_bucket")
        }
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

    private static func log(_ name: String, recordingDuration: TimeInterval?,
                            processingTime: TimeInterval?, errorKind: String? = nil,
                            channel: String? = nil) {
        guard isEnabled else { return }
        var parameters: [String: String] = [:]
        if let errorKind { parameters["error_kind"] = errorKind }
        if let channel { parameters["channel"] = channel }
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
