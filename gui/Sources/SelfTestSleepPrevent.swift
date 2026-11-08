import Foundation

/// ディスプレイのスリープ防止 (issue #516) の UI 無し検証。
/// «映像/音声のみの判定» «取得の参照カウントと解放» «取得失敗時の挙動» を
/// 偽ドライバ (実機の IOPMAssertion には触れない) で確かめる。
///
/// **実機のマシンはスリープさせない** — «録画中に実際にスリープしないか»
/// «解放が OS 側で反映されるか» (pmset -g assertions) は手動確認
/// (issue #516 の受け入れ条件)。実録画を伴わないため、録画のスロット
/// (画面収録・マイクの権限、スピーカー) を占有しない — 並行する録画テストと
/// 同時に回せる。
///
/// 使い方: `KILDE_GUI_SELFTEST_SLEEP_PREVENT=1 <GUI>` (SelfTest.runIfRequested から配線)
@MainActor
enum SelfTestSleepPrevent {

    private static var failures = 0

    static func run() {
        // MARK: 効かせる構成の判定 (shouldPrevent)
        check(DisplaySleepGuard.shouldPrevent(wantsVideo: true),
              "映像ありの録画はスリープを防ぐ")
        check(!DisplaySleepGuard.shouldPrevent(wantsVideo: false),
              "音声のみの録画は効かせない (挙動を変えない)")

        // MARK: 参照カウントと解放 — 偽ドライバで呼び出しを数える
        var created = 0
        var discarded: [IOPMAssertionID] = []
        let counting = DisplaySleepGuard.Driver(
            create: { created += 1; return (kIOReturnSuccess, IOPMAssertionID(7)) },
            discard: { discarded.append($0); return kIOReturnSuccess })
        let guardInstance = DisplaySleepGuard(driver: counting)
        check(!guardInstance.isPreventing, "初期状態では保持していない")

        guardInstance.acquire()
        check(guardInstance.isPreventing, "1 回の取得で保持する")
        check(created == 1, "0 → 1 の遷移でだけドライバに頼む (実際 \(created) 回)")

        guardInstance.acquire()
        check(created == 1, "2 つ目の取得では取得し直さない (参照カウント)")
        check(discarded.isEmpty, "参照が残っている間は解放しない")

        guardInstance.release()
        check(guardInstance.isPreventing, "参照が 1 つ残っていれば保持し続ける")
        check(discarded.isEmpty, "参照が残っている間は解放しない")

        guardInstance.release()
        check(!guardInstance.isPreventing, "参照が 0 になったら解放する")
        check(discarded == [7], "取得した ID を解放する (実際 \(discarded))")

        // 過剰な解放は安全 (no-op)。«音声のみの録画で acquire していないまま
        // 結果経路で release する» のと同じ経路
        guardInstance.release()
        check(discarded == [7] && !guardInstance.isPreventing, "過剰な解放で壊れない")

        // 再取得 — 前のセッションが解放されたあとの次の録画
        guardInstance.acquire()
        check(guardInstance.isPreventing && created == 2, "解放後の再取得で取得し直す")

        // MARK: 取得に失敗したとき — best-effort (録画は止めない設計)。
        // ステータスは警告 (stderr) に載るので、ここでは保持の挙動だけを見る
        let failing = DisplaySleepGuard(driver: DisplaySleepGuard.Driver(
            create: { (kIOReturnError, nil) },
            discard: { _ in kIOReturnError }))
        failing.acquire()
        check(!failing.isPreventing, "取得に失敗したら保持しない")
        failing.release()
        check(!failing.isPreventing, "失敗した取得の解放で壊れない")
        failing.acquire()
        failing.acquire()
        failing.release()
        failing.release()
        check(!failing.isPreventing, "失敗が混ざっても参照カウントは対になる")

        // MARK: 解放に失敗した ID の保持と再試行 (cubic レビュー指摘)。
        // 失敗を見過ごすと «録画後もディスプレイがスリープしない» が続くため、
        // 失敗した ID を pendingRelease に保持し、次の acquire()/release() で再試行する
        var nextID = IOPMAssertionID(20)
        var discardCalls: [(IOPMAssertionID, IOReturn)] = []
        var failFirstRelease = true
        let flaky = DisplaySleepGuard.Driver(
            create: { nextID += 1; return (kIOReturnSuccess, nextID) },
            discard: { id in
                let result: IOReturn = failFirstRelease ? kIOReturnError : kIOReturnSuccess
                failFirstRelease = false
                discardCalls.append((id, result))
                return result
            })
        let guarded = DisplaySleepGuard(driver: flaky)
        guarded.acquire()                       // create → 21
        guarded.release()                       // discard(21) が失敗 → pendingRelease へ
        check(!guarded.isPreventing, "解放に失敗したら保持を下ろす (OS 側の再試行に委ねる)")
        check(discardCalls.map { Self.trace($0) } == ["21:fail"], "最初の解放の失敗がドライバに届く")
        guarded.acquire()                       // retry discard(21) 成功 → create → 22
        check(discardCalls.map { Self.trace($0) } == ["21:fail", "21:ok"],
              "次の取得のときに失敗した ID を再試行する")
        check(guarded.isPreventing, "再試行のあとに新しい録画の取得が効く")
        guarded.release()                       // discard(22) は成功
        check(discardCalls.last.map { Self.trace($0) } == "22:ok", "新しい ID はふつうに解放される")

        print("selftest: sleep-prevent checks=\(failures == 0 ? "all passed" : "\(failures) failures")")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 検証ヘルパー

    /// 解放の呼び出し記録を «ID: 成否» の文字列にする (タプルは == で比較できないため)
    private static func trace(_ call: (IOPMAssertionID, IOReturn)) -> String {
        "\(call.0):\(call.1 == kIOReturnSuccess ? "ok" : "fail")"
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: sleep-prevent OK \(label)")
        } else {
            failures += 1
            print("selftest: sleep-prevent FAIL \(label)")
        }
    }
}
