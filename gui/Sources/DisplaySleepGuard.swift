import Foundation
// IOPMAssertion の API は IOKit の **explicit module** の pwr_mgt にある —
// `import IOKit` だけでは見えない (本 SDK の module.modulemap の explicit module pwr_mgt)
import IOKit
import IOKit.pwr_mgt

/// 録画セッション中のディスプレイのアイドル スリープを防ぐ (issue #516)。
///
/// 消灯・ロック中は ScreenCaptureKit がフレームを出さない (CLAUDE.md §5-7)。
/// 開始時の消灯はエンジンの 0 フレーム検出 (validateVideoFrameCount) で失敗になるが、
/// **録画中**のスリープは «スリープ中のフレームの欠落» (復帰後の自動リスタートで
/// 継続はする) か «中断を使い切った早期ファイナライズ» になり、会議を
/// «録りっぱなしにする» ユースケースで破綻する。エンジン側の **検出** に対して、
/// このクラスは **発生の防止** を録画セッションの寿命に束縛して行う。
/// CLI (\`kilde rec\`) は対話的な利用が前提なので対象外 (エンジン側の issue で
/// 検討する余地を残す)。
///
/// - 映像を収録するセッションだけに効かせる (\`shouldPrevent(wantsVideo:)\`)。
///   消灯は SCK の映像フレームにのみ影響するため、音声のみの録画の挙動は変えない
/// - 取得は **best-effort**。電源管理は録画の成立条件ではないため、取得に
///   失敗しても録画は止めない (stderr に記録するだけ)
/// - 取得と解放は **参照カウント** で対にする。録画コントローラは «前のセッションの
///   解放が次のセッションの取得と重なりうる» (完了通知の待ちの間に次の録画を
///   始められる) ので、単一のフラグではなくカウントで守る
/// - プロセスの終了・クラッシュ時の解放は OS 側が行う (IOPMAssertion はプロセス単位)
@MainActor
final class DisplaySleepGuard {

    /// この構成の録画でディスプレイのアイドル スリープを防ぐべきか。
    /// 映像を収録するときだけ true。判定を純関数に分けているのは、
    /// «どの構成で効くか» をセルフテスト (KILDE_GUI_SELFTEST_SLEEP_PREVENT) で
    /// 確かめられるようにするため
    static func shouldPrevent(wantsVideo: Bool) -> Bool { wantsVideo }

    /// IOPMAssertion の取得と解放の差し替え口。セルフテストは偽ドライバを注入し、
    /// **実機の電源管理には触れない** (テストでマシンをスリープさせない)
    struct Driver {
        /// アサーションを取得できたらその ID、失敗したら nil
        let create: () -> IOPMAssertionID?
        /// 参照が 0 になったときの解放。保持している ID に対してだけ呼ぶ
        let discard: (IOPMAssertionID) -> Void

        /// 実機の IOKit。呼び出しはすべて MainActor 上 (RecordingController からのみ)
        static func powerManagement() -> Driver {
            Driver(
                create: {
                    // ヘッダの kIOPMAssertPreventUserIdleDisplaySleep は CFSTR マクロのため
                    // Swift に import されない — 同じ値の文字列を直に渡す
                    var id = IOPMAssertionID(0)
                    let status = IOPMAssertionCreateWithName(
                        "PreventUserIdleDisplaySleep" as CFString,
                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                        "kilde recording" as CFString,
                        &id)
                    guard status == kIOReturnSuccess else { return nil }
                    return id
                },
                discard: { id in
                    _ = IOPMAssertionRelease(id)
                })
        }
    }

    private let driver: Driver
    /// 取得の参照カウント (0 は «保持していない»)
    private var holders = 0
    /// 現在のアサーション ID。0 (kIOPMNullAssertionID) は «保持していない»
    private var assertionID = IOPMAssertionID(0)

    /// «電源管理に触れる実ドライバ» での初期化
    convenience init() {
        self.init(driver: .powerManagement())
    }

    init(driver: Driver) {
        self.driver = driver
    }

    /// ディスプレイのアイドル スリープを防いでいれば true。
    /// 取得に失敗した場合は false (best-effort の設計 — 録画は続く)
    var isPreventing: Bool { assertionID != 0 }

    /// 参照を 1 増やし、0 → 1 の遷移でアサーションを取得する。
    /// 取得に失敗しても例外も出さない (best-effort — 録画は続ける)
    func acquire() {
        holders += 1
        guard holders == 1 else { return }
        guard let id = driver.create() else {
            // 失敗を黙って捨てると «なぜ録画が欠けたか» の調査ができないので残す
            FileHandle.standardError.write(
                "WARNING: ディスプレイのスリープ防止を取得できませんでした (IOPMAssertionCreateWithName)\n"
                    .data(using: .utf8)!)
            return
        }
        assertionID = id
    }

    /// 参照を 1 減らし、1 → 0 の遷移で解放する。取得していない状態で呼んでも安全
    /// (音声のみの録画では取得していないため、結果経路での無条件解放が no-op になる)
    func release() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        if assertionID != 0 {
            driver.discard(assertionID)
            assertionID = 0
        }
    }
}
