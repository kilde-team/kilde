import AppKit
import EventKit
import Foundation

/// カレンダーの予定と検知時刻の突き合わせ (issue #393)。EventKit に依存しない純関数 —
/// セルフテスト (KILDE_GUI_SELFTEST_MEETING) が合成データで機械的に確かめる
enum CalendarEventMatcher {

    /// 予定 1 件分 (EKEvent から必要な情報だけを抜いた形)
    struct Candidate: Equatable {
        let title: String
        let start: Date
        let end: Date
        /// 終日の予定 (「○○旅行」のようなその日全体の予定は会議の名前にならない)
        let isAllDay: Bool
        let isCancelled: Bool
    }

    /// 予定の開始前のどこまで «この予定の会議» とみなすか。数分早く入室する人は普通にいる
    static let earlyJoinTolerance: TimeInterval = 10 * 60
    /// 予定の終了後のどこまで猶予を見るか。会議が予定時刻を超えて続くのはよくある
    static let overrunTolerance: TimeInterval = 30 * 60

    /// 検知時刻に重なる予定を 1 つ選び、その題名を返す。
    ///
    /// 突き合わせは «検知を正とする» (issue #393 — 録画開始が予定どおりでなくても
    /// 検知した会議に予定を紐付ける)。よって予定の開始が遅れている・早く入室した
    /// 場合も earlyJoinTolerance / overrunTolerance の範囲で拾う。
    /// 複数の予定が重なるときは **最も遅く始まった予定** を選ぶ — 「今の会議」に
    /// 最も近い
    static func title(matching candidates: [Candidate], at date: Date) -> String? {
        let overlapping = candidates.filter { candidate in
            guard !candidate.isAllDay, !candidate.isCancelled else { return false }
            return date >= candidate.start.addingTimeInterval(-Self.earlyJoinTolerance)
                && date <= candidate.end.addingTimeInterval(Self.overrunTolerance)
        }
        // 題名の空白は突き合わせに影響しないように整える (カレンダーの題名は
        // 前後に空白が入りやすい)。空の題名は使わない
        return overlapping
            .max { $0.start < $1.start }
            .flatMap { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// カレンダー (EventKit) の読み取りと権限 (issue #393)。
///
/// **読み取り専用** — 予定の作成・変更・招待はしない。読んだ内容は会議の自動録画の
/// ファイル名のためだけに使われ、ネットワークへは一切送信されない (PRIVACY.md)。
///
/// 権限の要求は **設定トグルをオンにしたときだけ**。会議の検知・録画開始の経路では
/// 要求しない — 会議に参加した瞬間に権限ダイアログが出ると会議の操作を邪魔する
/// (マイクの許可ダイアログを出さないのと同じ理由。MeetingAutoRecorder.start のコメント)
@MainActor
final class CalendarTitles: ObservableObject {

    /// macOS の EventKit 権限。macOS 14 で .authorized は .fullAccess / .writeOnly に
    /// 分裂した (「読み取り専用」は iOS 17 の .readOnly のみで macOS には無い)
    enum AccessStatus: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted

        /// 予定の読み取りができる状態か (書き込み専用の許可ではイベントを読めない)
        var canRead: Bool { self == .authorized }
    }

    /// 権限の状態。起動時は notDetermined を仮置きし、init で実状を読み直す
    @Published private(set) var status: AccessStatus = .notDetermined

    /// 題名の検索に使う EventKit のストア。最初の読み取りのときだけ作る —
    /// EKEventStore の初期化は同期的で時間がかかることがあり、起動経路に置かない
    private var store: EKEventStore?

    /// 検索窓。実行中の長い予定 (立案・勉強会など) も拾えるよう、検知時刻から
    /// 6 時間前までに始まった予定までを見る。これより前から続いている予定は
    /// 「今の会議」とは呼べないため割り切る。nonisolated: 検索は MainActor の外で
    /// 動くため (fetchTitle)
    nonisolated private static let fetchLookback: TimeInterval = 6 * 60 * 60
    nonisolated private static let fetchLookahead: TimeInterval = 60 * 60

    init() {
        refreshStatus()
    }

    /// 権限の状態を読み直す (ダイアログは出さない)
    func refreshStatus() {
        status = Self.status(from: EKEventStore.authorizationStatus(for: .event))
    }

    private static func status(from raw: EKAuthorizationStatus) -> AccessStatus {
        switch raw {
        case .notDetermined: return .notDetermined
        // macOS 14 未満で許可された既存ユーザー (レガシー値)
        case .authorized: return .authorized
        // macOS 14+ の要求 (requestFullAccessToEvents) で許可された状態
        case .fullAccess: return .authorized
        // 書き込み専用の許可ではイベントを読めない (このアプリは書き込まないので
        // 「使えない」と同じ扱い)
        case .writeOnly: return .denied
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// カレンダーへのアクセスを要求する (ダイアログが出る)。**設定トグルをオンにした
    /// ときだけ呼ぶ** — クラスコメント参照。拒否されても題名が付かないだけで
    /// 機能は縮退する (自動録画は現行どおり動く)
    func requestAccess() async {
        // 未確定のときだけ要求する。拒否済みで呼んでもダイアログは出ない
        // (システム設定への案内は UI 側が担う)
        guard status == .notDetermined else { return }
        let store = self.store ?? EKEventStore()
        self.store = store
        // macOS の EventKit には iOS 17 の読み取り専用 API (requestReadAccessToEvents)
        // が無い。macOS 14+ の要求 API は full / writeOnly の 2 択で、読み取りには
        // full を要求するしかない。**アプリは許可されても読み取りだけを行い**、
        // 作成・変更・招待はしない — «読み取り専用» の保証はコードと PRIVACY.md・
        // UI 文言で担保する (案内文は NSCalendarsFullAccessUsageDescription)
        _ = try? await store.requestFullAccessToEvents()
        refreshStatus()
    }

    /// 検知時刻に重なる予定の題名。権限が無い・予定が見つからないときは nil
    /// (呼び出し側は既定のファイル名のまま録画を始める)。
    /// **この呼び出しは EventKit の応答を待つ** — 同期呼び出しをキャンセル付きで
    /// 打ち切る仕組みが Swift には無いため、録画の開始経路で直接待たないこと
    /// (MeetingAutoRecorder は検知の候補ができた時点で先行して呼び、開始時点で
    /// 結果があれば使う — MeetingAutoRecorder.beginCalendarLookup のコメント)
    func meetingTitle(at date: Date) async -> String? {
        // システム設定で許可が変わった直後の初回でも拾えるように、問い合わせの前に
        // 権限を読み直す (EventKit は許可の変化を通知しない)
        refreshStatus()
        guard status.canRead else { return nil }
        let store = self.store ?? EKEventStore()
        self.store = store
        // EventKit の検索はローカルでも同期的にブロックしうるので MainActor の外へ
        // (CGWindowList・CoreAudio の観測と同じ分け方)
        return await Task.detached(priority: .userInitiated) {
            Self.fetchTitle(store: store, at: date)
        }.value
    }

    /// EventKit からの取得 (MainActor の外で動く)。純粋な変換は CalendarEventMatcher が担う
    nonisolated private static func fetchTitle(store: EKEventStore, at date: Date) -> String? {
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-fetchLookback),
            end: date.addingTimeInterval(fetchLookahead),
            calendars: nil)
        let candidates = store.events(matching: predicate).map { event in
            CalendarEventMatcher.Candidate(
                title: event.title ?? "", start: event.startDate, end: event.endDate,
                isAllDay: event.isAllDay, isCancelled: event.status == .canceled)
        }
        return CalendarEventMatcher.title(matching: candidates, at: date)
    }

    /// カレンダーの権限のシステム設定を開く (拒否されたときの案内)
    func openSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        if let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }
}
