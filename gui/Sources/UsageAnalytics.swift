import Foundation
import KildeCore
import FirebaseAnalytics
import FirebaseCore

/// 文字起こしの利用状況イベント (issue #153)。録画後文字起こし (issue #146) が
/// «どれだけ使われ、どこで失敗しているか» を Firebase Analytics (#136) で見るための窓口。
/// AppDelegate の `app_open` と同じく、両ターゲット (直接配布 / MAS) で
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

    /// Firebase が初期化済みのときだけ送る。**セルフテストは configure しない**
    /// (AppDelegate.applicationDidFinishLaunching 参照) ので、ここで跳ねる。
    /// 未初期化のまま logEvent しても送信は起こらないが、明示しておくと
    /// «セルフテストでは何も送っていない» が読み取れる
    private static var isEnabled: Bool { FirebaseApp.app() != nil }

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

    private static func log(_ name: String, recordingDuration: TimeInterval?,
                            processingTime: TimeInterval?, errorKind: String? = nil) {
        guard isEnabled else { return }
        var parameters: [String: String] = [:]
        if let errorKind { parameters["error_kind"] = errorKind }
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
