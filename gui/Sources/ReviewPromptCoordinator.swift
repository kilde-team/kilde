import Foundation
#if APPSTORE
import AppKit
import StoreKit
#endif

/// App Store の評価依頼 (issue #156) の判定規則。**この enum が規則の唯一の正本。**
/// 状態の保持 (UserDefaults) と依頼の実行 (StoreKit) は ReviewPromptCoordinator が
/// 担い、規則そのものはここに置かない。時刻と回数を引数で受け取る純関数にしてあるので、
/// セルフテスト (KILDE_GUI_SELFTEST_REVIEW=1) が実データに頼らず全分岐を検証できる
///
/// この規則は直接配布版 (APPSTORE を定義しないビルド) でもコンパイルされる —
/// «規則» の検証は両スキームで等しく意味があり、MAS 専用の部分は
/// 下の ReviewPromptCoordinator 側に分けてある
enum ReviewPromptPolicy {
    /// 成功した録画の完了がこの回数に達したときに依頼する («録画完了 3 回目»)。
    /// **閾値を越えたあとも毎回の完了で判定し直す** — 依頼の窓が無くて見送った分を
    /// 次の完了で拾うため (noteRecordingCompleted のコメント参照)
    static let requiredSuccessfulRecordings = 3

    /// これより短い録画は «極端に短い» として成功回数に数えない (秒)。
    /// 誤操作や動作確認で止めた録画を «使い込んだ実績» とみなさないための下限で、
    /// 15 秒は «収録したものがあってファイナライズまで終わった» と言える最小の長さ
    /// の目安。経過時間は progress の最終値 (0.5 秒周期) なので実長より最大 0.5 秒
    /// 短く出るが、この閾値の判定には影響しない
    static let minimumCountableDuration: TimeInterval = 15

    /// 依頼してからこの日数が経過するまで再依頼しない («最低 90 日は再表示しない»)
    static let minimumDaysBetweenRequests = 90

    /// 極端に短い録画は成功回数に数えない。失敗 (.failed) はそもそも
    /// 完了フック (noteRecordingCompleted) に入らないので、ここでは長さだけ見る
    static func isCountable(duration: TimeInterval) -> Bool {
        duration >= minimumCountableDuration
    }

    /// いま評価を依頼すべきか。**純関数** — 状態はすべて引数で受け取る
    /// - Parameters:
    ///   - successfulRecordings: 成功した録画完了の累積回数
    ///   - lastRequestDate: 前回依頼した時刻。nil は «まだ依頼したことがない»
    ///   - now: 判定時刻 (検証で固定できるように引数で受け取る)
    static func shouldRequest(successfulRecordings: Int,
                              lastRequestDate: Date?,
                              now: Date) -> Bool {
        guard successfulRecordings >= requiredSuccessfulRecordings else { return false }
        guard let last = lastRequestDate else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(minimumDaysBetweenRequests) * 86400
    }
}

#if APPSTORE
/// 評価依頼の状態保持と実行。**MAS ビルド (KildeGUI-AppStore) だけに存在する** —
/// `import StoreKit` を `#if APPSTORE` の内側に置く構図は Sparkle (§5.15) と同じで、
/// 外に出すと MAS ビルドだけが «モジュールを解決できない» で落ちる (通常ビルドは
/// 通るので単体ビルドでは気づけない)。AppDelegate が 1 つだけ持ち、録画の成功完了
/// (.finished) のたびに noteRecordingCompleted を呼ぶ。直接配布版では下の
/// 何もしない置き換えに差し替わる
@MainActor
final class ReviewPromptCoordinator {
    /// 検証では分離した suite を注入できる (実データのカウントを触らない)
    private let defaults: UserDefaults

    /// 記録先のキー。Debug 構成はバンドル ID が `.dev` に分かれている (§5.21) ので、
    /// 開発中の試行が本番のカウントに混ざることはない
    enum Keys {
        static let successfulRecordings = "reviewPromptSuccessfulRecordings"
        static let lastRequestDate = "reviewPromptLastRequestDate"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 録画の成功完了を記録し、規則を満たしていれば評価を依頼する。
    /// **«録画中・文字起こし中には出さない» の判定材料は呼び出し側 (AppDelegate) が
    /// 渡す** — @Published は willSet で流れるので、確定値を見るには次の MainActor
    /// ひと仕事が要る (呼び出し側のコメント参照)
    /// - Returns: 実際に依頼を出したか。セルフテストが «窓が無ければ見送り» を
    ///   検証するのに使う
    @discardableResult
    func noteRecordingCompleted(duration: TimeInterval,
                                recordingActive: Bool,
                                transcriptionBusy: Bool) -> Bool {
        // «数える» と «依頼する» を分けて考える。**忙しいときも数えた上で見送る** —
        // 文字起こしが常時走る使い方でも回数が進み、次の完了で依頼できる
        guard ReviewPromptPolicy.isCountable(duration: duration) else { return false }
        let count = defaults.integer(forKey: Keys.successfulRecordings) + 1
        defaults.set(count, forKey: Keys.successfulRecordings)
        guard !recordingActive, !transcriptionBusy else { return false }
        guard ReviewPromptPolicy.shouldRequest(
            successfulRecordings: count,
            lastRequestDate: defaults.object(forKey: Keys.lastRequestDate) as? Date,
            now: Date()) else { return false }
        // 依頼を出す窓が無ければ見送る。**このとき日付を記録しない** — 記録すると
        // «90 日の再依頼禁止» が «窓が無かった» ことまで束縛してしまい、次の完了で
        // 再試行できなくなる。LSUIElement のアプリは popover を閉じている間窓を
        // 持たないので、«次の録画完了時にパネルが開いていれば依頼» が自然な再試行になる
        guard let presenter = Self.reviewPresenter() else { return false }
        AppStore.requestReview(in: presenter)
        defaults.set(Date(), forKey: Keys.lastRequestDate)
        return true
    }

    /// 依頼を出す先のビューコントローラ。**StoreKit の requestReview は macOS では
    /// NSWindow ではなく NSViewController を受け取る** (iOS の UIViewController と同じ
    /// 形 — NSWindow を渡すと MAS ビルドだけが型エラーで落ち、単体ビルドは通る。
    /// 2026-09-26 実測)。メニューバーアプリは通常のウィンドウを持たないので、
    /// «今ある窓» の contentViewController — パネル (popover) を開いていればその
    /// NSHostingController — に頼るほかない。ステータス項目の窓は canBecomeKey
    /// でないので選ばれない。nil は «出せない»
    static func reviewPresenter() -> NSViewController? {
        NSApp.keyWindow?.contentViewController
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.contentViewController
    }
}
#else
/// 直接配布版の何もしない置き換え。**型と呼び出し口だけを揃える** — AppDelegate は
/// `#if` を知らずに両ビルドで同じコードを通る (UpdaterCoordinator /
/// UpdaterCoordinatorAppStore と同じ構図)。App Store が無い配布形態では
/// 評価依頼が意味を持たないので、カウントも含めて何もしない
@MainActor
final class ReviewPromptCoordinator {
    init(defaults: UserDefaults = .standard) {}
    @discardableResult
    func noteRecordingCompleted(duration: TimeInterval,
                                recordingActive: Bool,
                                transcriptionBusy: Bool) -> Bool { false }
}
#endif

/// 評価依頼 (issue #156) のセルフテスト (KILDE_GUI_SELFTEST_REVIEW=1)。
///
///     KILDE_GUI_SELFTEST_REVIEW=1 KildeGUI.app/Contents/MacOS/KildeGUI
///
/// **実録画もシステムの評価ダイアログも伴わない。** 2 段で確かめる:
/// 1. 判定規則 (ReviewPromptPolicy) を合成データで全分岐検証する (両ビルド)
/// 2. MAS ビルドでは状態保持の配線 (UserDefaults への記録・«窓が無ければ見送る»)
///    を分離した suite で検証する。本物の依頼 (requestReview) は出さない —
///    «実際に表示される» ことは実機確認 (PR の手順) に頼る
extension SelfTest {
    @MainActor
    static func reportReviewRequest() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            print("selftest: review [\(ok ? "PASS" : "FAIL")] \(name)")
        }

        // 1. 判定規則。時刻は固定値で «90 日» の境界を含めて検証する
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-30 * 86400)
        let boundary = now.addingTimeInterval(-90 * 86400)
        let stale = now.addingTimeInterval(-91 * 86400)
        struct RuleCase { let name: String; let count: Int; let last: Date?; let expected: Bool }
        let ruleCases: [RuleCase] = [
            RuleCase(name: "2 回では依頼しない", count: 2, last: nil, expected: false),
            RuleCase(name: "3 回目で依頼する", count: 3, last: nil, expected: true),
            RuleCase(name: "3 回超え (見送り分の再試行) も依頼する", count: 7, last: nil, expected: true),
            RuleCase(name: "90 日未満は依頼しない", count: 5, last: recent, expected: false),
            RuleCase(name: "ちょうど 90 日で依頼する", count: 5, last: boundary, expected: true),
            RuleCase(name: "90 日超えで依頼する", count: 5, last: stale, expected: true),
        ]
        for c in ruleCases {
            let got = ReviewPromptPolicy.shouldRequest(
                successfulRecordings: c.count, lastRequestDate: c.last, now: now)
            check("規則: \(c.name) expected=\(c.expected) got=\(got)", got == c.expected)
        }
        for (seconds, expected) in [(0.0, false), (14.0, false), (15.0, true), (600.0, true)] {
            let got = ReviewPromptPolicy.isCountable(duration: seconds)
            check("規則: \(seconds) 秒の録画は数え\(got ? "る" : "ない") expected=\(expected)",
                  got == expected)
        }

#if APPSTORE
        // 2. 状態保持の配線 (MAS ビルドのみ)。実データと分離するため suite を
        // 分けて使い、検証後に掃除する
        let suiteName = "kilde-selftest-review-prompt"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        let countKey = ReviewPromptCoordinator.Keys.successfulRecordings
        let dateKey = ReviewPromptCoordinator.Keys.lastRequestDate

        // 極端に短い録画は数えない
        coordinator.noteRecordingCompleted(duration: 5, recordingActive: false,
                                           transcriptionBusy: false)
        check("配線: 短い録画は数えない (count=0)", defaults.integer(forKey: countKey) == 0)

        // 文字起こし中でも回数は進むが、依頼は出ない
        var requested = false
        for _ in 0..<3 {
            requested = coordinator.noteRecordingCompleted(
                duration: 60, recordingActive: false, transcriptionBusy: true) || requested
        }
        check("配線: 文字起こし中も回数は進む (count=3)", defaults.integer(forKey: countKey) == 3)
        check("配線: 文字起こし中は依頼しない", !requested)
        check("配線: 依頼していないので日付は記録されない",
              defaults.object(forKey: dateKey) == nil)

        // 空きが出た次の完了。このセルフテストはパネル (popover) を開かないので
        // 依頼の窓は無い — «窓が無ければ見送り、日付も記録しない» を確かめる
        requested = coordinator.noteRecordingCompleted(
            duration: 60, recordingActive: false, transcriptionBusy: false)
        check("配線: 窓が無ければ依頼しない", !requested)
        check("配線: 見送りでも日付は記録しない", defaults.object(forKey: dateKey) == nil)
        check("配線: 見送りでも回数は進む (count=4)", defaults.integer(forKey: countKey) == 4)

        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
#endif

        print("selftest: review failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
