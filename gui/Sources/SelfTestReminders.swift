import EventKit
import Foundation
import KildeCore

/// リマインダーへの書き出し (issue #509) の UI 無し検証。
/// «アクションアイテム → リマインダー項目の組み立て» «ボタンの有効条件と
/// ツールチップ» «EventKit 権限の写像» の純関数を合成データで確かめる。
///
/// **実機の Reminders には書き込まない** — 触れるのは ReminderExportSupport
/// (純関数) だけで、EKReminder の生成と保存 (ReminderExporter.export) は
/// このテストから呼ばない。«実際にリマインダーに追加できるか» «初回押下で
/// 権限ダイアログが出るか» は手動確認 (issue #509 の受け入れ条件) —
/// 書き込みはシステムのリマインダーが対象になり、自動検証では汚れるため。
///
/// 実録画を伴わないため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない — 並行する録画テストと同時に回せる。
///
/// 使い方: `KILDE_GUI_SELFTEST_REMINDERS=1 <GUI>` (SelfTest.runIfRequested から配線)
@MainActor
enum SelfTestReminders {

    private static var failures = 0

    static func run() {
        // MARK: 項目の組み立て (items(fromActions:meetingName:))
        let items = ReminderExportSupport.items(
            fromActions: [
                "田中さんが議事録を共有する",
                "  前後の空白は整える  ",
                "   ",
                "",
                "金曜までに予算案を見直す",
            ],
            meetingName: "kilde-20261108-100000")
        check(items.count == 3, "空白のみの項目は捨てる (実際 \(items.count) 件)")
        check(items[0].title == "田中さんが議事録を共有する", "1 件目の文面をそのまま載せる")
        check(items[1].title == "前後の空白は整える", "前後の空白を整える")
        check(items[2].title == "金曜までに予算案を見直す", "3 件目を拾う")
        check(
            items.allSatisfy { $0.notes == "kilde — kilde-20261108-100000" },
            "notes は «kilde — <録画名>» の形式 (実際 \(items.first?.notes ?? "nil"))")

        // 空のアクション列は空の結果 (追加せずに終わる — ボタン自体が無効になる)
        check(ReminderExportSupport.items(fromActions: [], meetingName: "x").isEmpty,
              "空のアクション列は 0 件")

        // MARK: 議事録の状態からの取り出し (actions(in:))
        let summary = MeetingSummary(
            points: ["要点"], decisions: [],
            actions: ["アクション A", "アクション B"])
        let noActionsSummary = MeetingSummary(points: ["要点"], decisions: ["決定"], actions: [])
        check(ReminderExportSupport.actions(in: .summary(summary)) == ["アクション A", "アクション B"],
              "要約からアクションを取り出せる")
        check(ReminderExportSupport.actions(in: .summary(noActionsSummary)).isEmpty,
              "アクションの無い要約は空")
        check(ReminderExportSupport.actions(in: .noSummary).isEmpty,
              "要約の無い議事録は空")
        check(ReminderExportSupport.actions(in: .notMinutes).isEmpty,
              "議事録でないものは空")

        // MARK: ボタンの有効条件 (isButtonEnabled)
        check(ReminderExportSupport.isButtonEnabled(doc: .summary(summary)),
              "アクションがある要約で押せる")
        check(!ReminderExportSupport.isButtonEnabled(doc: .summary(noActionsSummary)),
              "アクションの無い要約では押せない")
        check(!ReminderExportSupport.isButtonEnabled(doc: .noSummary),
              "要約の無い議事録では押せない")
        check(!ReminderExportSupport.isButtonEnabled(doc: .notMinutes),
              "議事録でないものでは押せない")

        // MARK: ツールチップ (buttonTooltip) — 4 状態すべてで空でない文面
        for (label, doc) in [
            ("アクションあり", FollowupDraftSupport.MinutesDoc.summary(summary)),
            ("アクションなし", FollowupDraftSupport.MinutesDoc.summary(noActionsSummary)),
            ("要約なし", FollowupDraftSupport.MinutesDoc.noSummary),
            ("議事録なし", FollowupDraftSupport.MinutesDoc.notMinutes),
        ] {
            let tooltip = ReminderExportSupport.buttonTooltip(doc: doc)
            check(!tooltip.isEmpty, "ツールチップが空でない (\(label))")
        }

        // MARK: EventKit 権限の写像 (status(from:)) — Reminders は書き込みが目的のため
        // writeOnly も «書ける» 側に写像する (ReminderExportSupport のコメント参照)
        check(ReminderExportSupport.status(from: .notDetermined) == .notDetermined,
              "notDetermined は未確定")
        check(ReminderExportSupport.status(from: .authorized).canWrite,
              "authorized (レガシー) は書ける")
        check(ReminderExportSupport.status(from: .fullAccess).canWrite,
              "fullAccess は書ける")
        check(ReminderExportSupport.status(from: .writeOnly).canWrite,
              "writeOnly は書ける")
        check(!ReminderExportSupport.status(from: .denied).canWrite,
              "denied は書けない")
        check(!ReminderExportSupport.status(from: .restricted).canWrite,
              "restricted は書けない")

        // MARK: エラーの案内文 — UI にそのまま出すので空でないこと
        check(!ReminderExporter.ExportError.noDefaultList.message.isEmpty,
              "noDefaultList の案内文が空でない")
        check(!ReminderExporter.ExportError.notAuthorized.message.isEmpty,
              "notAuthorized の案内文が空でない")

        print("selftest: reminders checks=\(failures == 0 ? "all passed" : "\(failures) failures")")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 検証ヘルパー

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: reminders OK \(label)")
        } else {
            failures += 1
            print("selftest: reminders FAIL \(label)")
        }
    }
}
