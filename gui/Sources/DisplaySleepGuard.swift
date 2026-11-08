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
/// CLI (`kilde rec`) は本リポジトリの対象外 (録画エンジン =
/// kilde-team/kilde-cli-swift 側のコード。README が示す `--duration` の無人利用でも
/// 同じ欠落は起こりうるため、エンジン側の issue で検討する余地を残す)。
///
/// - 映像を収録するセッションだけに効かせる (`shouldPrevent(wantsVideo:)`).
///   消灯は SCK の映像フレームにのみ影響するため、音声のみの録画の挙動は変えない
/// - 取得は **best-effort**。電源管理は録画の成立条件ではないため、取得に
///   失敗しても録画は止めない (ステータスコードを stderr に記録するだけ)
/// - 取得と解放は **参照カウント** で対にする。録画コントローラは «前のセッションの
///   解放が次のセッションの取得と重なりうる» (完了通知の待ちの間に次の録画を
///   始められる) ので、単一のフラグではなくカウントで守る
/// - **解放に失敗した ID は捨てない** — IOPMAssertionRelease の失敗を見過ごすと
///   アサーションが OS 側に残り、«録画が終わったのにディスプレイがスリープしない»
///   状態が続く。失敗した ID は pendingRelease に保持し、次の acquire() / release()
///   で再試行する。プロセスの終了・クラッシュ時の解放は OS 側が行う
///   (IOPMAssertion はプロセス単位)
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
        /// IOReturn のステータスと、取得できた場合のアサーション ID (失敗時は nil)
        let create: () -> (status: IOReturn, id: IOPMAssertionID?)
        /// 解放の結果。kIOReturnSuccess 以外のときは呼び出し側が再試行を管理する
        let discard: (IOPMAssertionID) -> IOReturn

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
                    return (status, status == kIOReturnSuccess ? id : nil)
                },
                discard: { id in
                    IOPMAssertionRelease(id)
                })
        }
    }

    private let driver: Driver
    /// 取得の参照カウント (0 は «保持していない»)
    private var holders = 0
    /// 現在のアサーション ID。0 (kIOPMNullAssertionID) は «保持していない»
    private var assertionID = IOPMAssertionID(0)
    /// 解放に失敗して再試行を待つ ID (成功したら nil に戻す)
    private var pendingRelease: IOPMAssertionID?

    /// «電源管理に触れる実ドライバ» での初期化
    convenience init() {
        self.init(driver: .powerManagement())
    }

    init(driver: Driver) {
        self.driver = driver
    }

    /// «このセッションの取得» を保持していれば true。
    /// 取得に失敗した場合は false (best-effort の設計 — 録画は続く)。
    /// 解放に失敗して pendingRelease に残った ID は OS 側にアサーションが残るが、
    /// それは «セッションの取得» ではないのでこの値には反映しない
    var isPreventing: Bool { assertionID != 0 }

    /// 参照を 1 増やし、0 → 1 の遷移でアサーションを取得する。
    /// 取得に失敗しても例外も出さない (best-effort — 録画は続ける)
    func acquire() {
        retryPendingRelease()
        holders += 1
        guard holders == 1 else { return }
        let (status, id) = driver.create()
        guard let id else {
            // 失敗を黙って捨てると «なぜ録画が欠けたか» の調査ができないので、
            // ステータスコード (権限不足と別要因の切り分け用 — cubic レビュー指摘) を残す
            let message = "WARNING: ディスプレイのスリープ防止を取得できませんでした"
                + " (IOPMAssertionCreateWithName, IOReturn=0x\(String(status, radix: 16)))\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }
        assertionID = id
    }

    /// 参照を 1 減らし、1 → 0 の遷移で解放する。取得していない状態で呼んでも安全
    /// (音声のみの録画では取得していないため、結果経路での無条件解放が no-op になる)
    func release() {
        retryPendingRelease()
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        guard assertionID != 0 else { return }
        let status = driver.discard(assertionID)
        guard status == kIOReturnSuccess else {
            // 解放に失敗した ID は保持して再試行する (cubic レビュー指摘)。失敗を見過ごすと
            // «録画が終わったのにディスプレイがスリープしない» が続く
            let message = "WARNING: ディスプレイのスリープ防止を解放できませんでした"
                + " (IOPMAssertionRelease, IOReturn=0x\(String(status, radix: 16)))"
                + " — 次の録画の開始・停止のときに再試行します\n"
            FileHandle.standardError.write(Data(message.utf8))
            pendingRelease = assertionID
            assertionID = 0
            return
        }
        assertionID = 0
    }

    /// 解放に失敗して残った ID の再試行。成功したらクリアする (失敗したら次へ持ち越し)。
    /// acquire() と release() の頭で呼ぶ — ループさせない (失敗が続いても 1 回だけ試す)
    private func retryPendingRelease() {
        guard let pending = pendingRelease else { return }
        if driver.discard(pending) == kIOReturnSuccess {
            pendingRelease = nil
        }
    }
}
