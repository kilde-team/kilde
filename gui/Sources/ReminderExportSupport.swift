import AppKit
import EventKit
import Foundation
import KildeCore
import os

/// リマインダーへの書き出し (issue #509) の GUI 側の下準備。
/// «要約のアクションアイテム → リマインダー項目の組み立て» «ボタンの有効条件と
/// ツールチップ» «EventKit 権限の写像» を置く。組み立てと判定は **EventKit に
/// 依存しない (権限の写像を除く) 純関数** にしてある — セルフテスト
/// (KILDE_GUI_SELFTEST_REMINDERS) が合成データで機械的に確かめる対象。
/// **EKReminder の生成と保存は ReminderExporter が担い、セルフテストは触らない**
/// (実機の Reminders を汚さない — Spotlight 対応 #502 と同じ線引き)
enum ReminderExportSupport {

    /// 書き出す 1 項目。EKReminder への写し前の中間形 (純関数の入出力)
    struct Item: Equatable {
        let title: String
        /// 出所 (どの議事録から来たか) をリマインダー側で追跡できるようにするための
        /// 添え文言。言語に依らない形式にする (セルフテストで突合するため)
        let notes: String
    }

    /// notes の形式。«kilde — <録画ファイル名の stem>» — stem には日時が入るため
    /// «どの会議のアクションか» がリマインダー側で分かる。カタログの既存キー
    /// («kilde — %@» — 録画開始通知の見出しと同じ。全ロケールで同形) を流用するため
    /// 出力は言語に寄らず、セルフテストの突合も安定する
    static func notes(forMeetingNamed meetingName: String) -> String {
        String(localized: "kilde — \(meetingName)")
    }

    /// 要約のアクションアイテムを書き出し対象に変える。
    /// 前後の空白は整え、**空白のみの項目は捨てる** (LLM 出力に空行・
    /// 空白行が混ざることがある)。上限は設けない — アクションは要約の
    /// 一部としてエンジン側で少数に収まる (MeetingSummarizer の出力構造) ため
    static func items(fromActions actions: [String], meetingName: String) -> [Item] {
        let notes = notes(forMeetingNamed: meetingName)
        return actions.compactMap { raw in
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return Item(title: title, notes: notes)
        }
    }

    /// 議事録の入力状態から書き出し対象のアクションを取り出す。
    /// MinutesDoc はフォローアップの下書き (issue #464) が導入した «議事録 .md の
    /// 状態» の語彙 — リマインダーの書き出しも同じ状態を読む (要約は .md にしか
    /// 載らない契約は TranscriptWriter 側で不変)
    static func actions(in doc: FollowupDraftSupport.MinutesDoc) -> [String] {
        guard case .summary(let summary) = doc else { return [] }
        return summary.actions
    }

    /// ボタンの有効条件。リマインダーの書き出しは端末内の操作で、Apple Intelligence
    /// も Pro も不要 (要約の«生成»が Pro で、出来上がった .md の持ち出しは free —
    /// «書き出し先の連携» #164 と同じ位置づけ)。書き出せるアクションがあることだけを見る
    static func isButtonEnabled(doc: FollowupDraftSupport.MinutesDoc) -> Bool {
        !actions(in: doc).isEmpty
    }

    /// ボタン・無効理由のツールチップ («議事録を作成» «フォローアップを下書き» と同じ
    /// «控えめ» 方針 — 権限の案内は押したあとの結果表示で行い、購入導線は
    /// 設定パネルにしか置かない)
    static func buttonTooltip(doc: FollowupDraftSupport.MinutesDoc) -> String {
        switch doc {
        case .summary(let summary) where !summary.actions.isEmpty:
            return String(localized: "要約のアクションアイテムを、リマインダーの既定のリストに追加します")
        case .summary:
            return String(localized: "この議事録の要約にアクションアイテムはありません")
        case .noSummary:
            return String(localized: "この議事録には要約がありません (録画後に要約を作ると使えます)")
        case .notMinutes:
            return String(localized: "リマインダーへの追加には要約つきの議事録 (.md) が必要です")
        }
    }

    /// リマインダーの EventKit 権限の状態。CalendarTitles の AccessStatus と
    /// 同じ形 — ただし **書き込みが目的** なので writeOnly も «使える» に写像する
    enum AccessStatus: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted

        /// リマインダーへの書き込みができる状態か
        var canWrite: Bool { self == .authorized }
    }

    /// EventKit の生の権限値の写像 (純関数 — セルフテスト対象)。
    /// macOS の Reminders に writeOnly の要求 API は無い (full のみ) が、
    /// 許可状態の値としては writeOnly が現れうるため «書ける» 側に寄せる
    static func status(from raw: EKAuthorizationStatus) -> AccessStatus {
        switch raw {
        case .notDetermined: return .notDetermined
        // macOS 14 未満で許可された既存ユーザー (レガシー値) と、
        // macOS 14+ の requestFullAccessToReminders で許可された状態
        case .authorized: return .authorized
        case .fullAccess: return .authorized
        // Reminders では通常現れないが、許可されていれば書き込みはできる
        case .writeOnly: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}

/// リマインダー (EventKit) への書き出しと権限 (issue #509)。
///
/// **書き込み専用の運用** — 既存項目の読み取り・変更・削除はしない。macOS の
/// EventKit には Reminders の書き込み専用の要求 API が無いため full access を
/// 要求するが、«追加だけしかしない» 保証はコードと PRIVACY.md・UI 文言で担保する
/// (カレンダー読み取りの «読み取り専用» と同じ担保のしかた — CalendarTitles のコメント)。
///
/// 権限の要求は **ボタンを押したときだけ**。起動経路・ライブラリを開く経路では
/// 要求しない — 権限ダイアログで作業を邪魔しないため (CalendarTitles と同じ理由)
@MainActor
final class ReminderExporter: ObservableObject {

    /// 文字起こしと同じく、subsystem は実行中の構成のバンドル ID (Debug と Release
    /// で分かれている — CLAUDE.md §5-21)
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.takezou621.KildeGUI",
        category: "reminders")

    /// 権限の状態。起動時は notDetermined を仮置きし、init で実状を読み直す
    @Published private(set) var status: ReminderExportSupport.AccessStatus = .notDetermined

    /// 書き出しに使う EventKit のストア。最初の書き出しのときだけ作る —
    /// EKEventStore の初期化は同期的で時間がかかることがあり、起動経路に置かない
    /// (CalendarTitles.store と同じ理由)
    private var store: EKEventStore?

    /// 書き出しの失敗。UI にそのまま出す案内文を運ぶ
    struct ExportError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }

        /// 既定のリマインダーリストが取れない (リマインダーのアカウントが無効な場合など)
        static let noDefaultList = ExportError(
            message: String(localized: "既定のリマインダーリストが見つかりません"))
        /// 権限がない (requestAccess を先に通していない・拒否された)
        static let notAuthorized = ExportError(
            message: String(localized: "リマインダーへのアクセスが許可されていません"))
    }

    init() {
        refreshStatus()
    }

    /// 権限の状態を読み直す (ダイアログは出さない)。EventKit は許可の変化を
    /// 通知しないため、参照の前後に呼ぶ (CalendarTitles.refreshStatus と同じ)
    func refreshStatus() {
        status = ReminderExportSupport.status(from: EKEventStore.authorizationStatus(for: .reminder))
    }

    /// リマインダーへのアクセスを要求する (ダイアログが出る)。**ボタンを押した
    /// ときだけ呼ぶ** — クラスコメント参照。未確定のときだけ要求する
    /// (拒否済みで呼んでもダイアログは出ない — 案内は UI 側が担う)
    func requestAccess() async {
        refreshStatus()
        guard status == .notDetermined else { return }
        let store = self.store ?? EKEventStore()
        self.store = store
        // macOS 14+ の API。デプロイ対象は 14.0 のため #available は不要
        // (requestFullAccessToEvents — issue #393 と同じ)
        _ = try? await store.requestFullAccessToReminders()
        refreshStatus()
    }

    /// 項目を **既定のリマインダーリスト** (defaultCalendarForNewReminders) へ
    /// 追加し、追加できた件数を返す。kilde 専用のリストは作らない — ユーザーの
    /// 普段のリストに流すのが «普段使う道具に流れる» (issue #164) の趣旨。
    /// 保存は **commit を 1 回にまとめる** (全件まとめて確定 — 途中で失敗したら
    /// 何も残さない)。EventKit の保存はブロックしうるため MainActor の外へ
    /// (CalendarTitles.meetingTitle の検索と同じ分け方)
    func export(_ items: [ReminderExportSupport.Item]) async throws -> Int {
        refreshStatus()
        guard status.canWrite else { throw ExportError.notAuthorized }
        let store = self.store ?? EKEventStore()
        self.store = store
        return try await Task.detached(priority: .userInitiated) {
            try Self.save(items, store: store)
        }.value
    }

    /// EventKit への保存 (MainActor の外で動く)。純粋な組み立ては
    /// ReminderExportSupport が担う
    nonisolated private static func save(
        _ items: [ReminderExportSupport.Item], store: EKEventStore) throws -> Int {
        guard let list = store.defaultCalendarForNewReminders() else {
            throw ReminderExporter.ExportError.noDefaultList
        }
        do {
            for item in items {
                let reminder = EKReminder(eventStore: store)
                reminder.title = item.title
                reminder.notes = item.notes
                reminder.calendar = list
                try store.save(reminder, commit: false)
            }
            try store.commit()
        } catch let error as ReminderExporter.ExportError {
            throw error
        } catch {
            // EventKit の保存エラー (NSError) は其のまま出すと内部情報が並ぶため、
            // 案内として要約した文言に載せ替える。ログには **domain と code だけ** を
            // 出す — localizedDescription / userInfo には項目の文面などユーザーの
            // データが混ざるおそれがあり、ログに載せない (TranscriptionCoordinator
            // の diagnosticDetail と同じ CWE-532 の配慮)
            let nsError = error as NSError
            Self.logger.error(
                "reminder save failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            throw ReminderExporter.ExportError(
                message: String(localized: "リマインダーに追加できませんでした"))
        }
        return items.count
    }

    /// リマインダーの権限のシステム設定を開く (拒否されたときの案内)。
    /// パスはカレンダー (Privacy_Calendars) と同じ系統のリマインダー用ペイン
    func openSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        if let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }
}
