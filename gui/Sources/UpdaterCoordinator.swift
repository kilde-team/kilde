import Combine
import Sparkle

/// Sparkle 2 による自動更新の窓口 (issue #122)。
/// ポップオーバーの「アップデートを確認」から使い、更新のインストール (再起動) の
/// 直前だけ録画の状態を Sparkle に仲介する
@MainActor
final class UpdaterCoordinator: ObservableObject {

    /// 更新チェックを実行できる状態か (Sparkle の初期化が済んでいるか)。
    /// ボタンの有効化に使う
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    /// SPUStandardUpdaterController は updaterDelegate を弱参照で持つため、ここで
    /// 生存期間を持つ — 捨てると delegate が消えて、録画中の再起動保留が黙って無効になる
    private let gate: UpdateInstallGate

    /// 録画中か通知待ちかで、更新のインストール (再起動) をどう扱うか。
    /// 純関数に切り出してセルフテスト (KILDE_GUI_SELFTEST_UPDATE=1) で全ケースを確かめる
    enum InstallAction: Equatable {
        /// 録画していない — すぐ再起動してよい
        case immediate
        /// 録画中 — 停止してファイナライズ完了を待ってから再起動
        case afterStop
        /// 録画は終わっているが完了通知待ち — 通知を待ってから再起動
        case afterNotification
    }

    static func installAction(isActive: Bool, awaitingNotification: Bool) -> InstallAction {
        if isActive { return .afterStop }
        if awaitingNotification { return .afterNotification }
        return .immediate
    }

    init(recording: RecordingController, startUpdater: Bool) {
#if DEBUG
        // 開発ビルドは実フィードを定期的に見にいかないようにする。SU* キーは
        // UserDefaults が Info.plist より優先されるため、この書き込みで確実に効く。
        // **キー名は Sparkle 2 の SUEnableAutomaticChecks** (SPUUpdater.h)。旧
        // Sparkle 1 の SUAutomaticallyChecksForUpdates は効かないので書き換えないこと。
        // 残った値は Release ビルドにも効いてしまうので、戻す手順は docs/DEVELOPMENT.md §3
        UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
#endif
        gate = UpdateInstallGate(recording: recording)
        controller = SPUStandardUpdaterController(
            startingUpdater: startUpdater,
            updaterDelegate: gate,
            userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// ポップオーバーの「アップデートを確認」から呼ぶ。Sparkle 標準の更新ウィンドウが出る
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// SPUUpdaterDelegate: 更新のインストール (再起動) を録画のファイナライズより後に回す。
/// 判定の本体は `UpdaterCoordinator.installAction` (純関数) にあり、ここは
/// `AppDelegate.applicationShouldTerminate` と同じ `whenSessionEnds` パターンを
/// Sparkle に仲介するだけ
@MainActor
final class UpdateInstallGate: NSObject, SPUUpdaterDelegate {

    private weak var recording: RecordingController?

    init(recording: RecordingController) {
        self.recording = recording
    }

    /// **セレクタ名は `untilInvokingBlock:` (Sparkle 2)。** 旧名 `untilInvoking:` は
    /// オプショナルメソッドのため、間違えても警告なしで永久に呼ばれず、録画中の再起動待ちが
    /// 黙って無効になる (CLAUDE.md §5 の地雷)
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let recording else { return false }
        let action = UpdaterCoordinator.installAction(
            isActive: recording.isActive,
            awaitingNotification: recording.awaitingNotification)
        switch action {
        case .immediate:
            return false
        case .afterStop, .afterNotification:
            postponeUntilSettled(installHandler, action: action)
            return true
        }
    }

    /// installHandler を「録画も通知待ちも無い状態」まで延期する。登録したハンドラは
    /// **実行時点で状態を再評価し、まだ待つべきものがあれば現在のセッションに束縛して
    /// 待ち直す**。whenSessionEnds は登録時点のセッションに束縛されるため、通知待ちの
    /// 間にユーザーが次の録画を始めると、古いセッションの完了でハンドラが発火してしまう —
    /// 再評価なしでは進行中の新しい録画に再起動が割り込み、ファイルを壊す
    /// (cubic レビュー指摘)。applicationShouldTerminate はプロセス終了時に一度しか
    /// 走らないためこの問題が無く、ここだけに必要な工夫
    private func postponeUntilSettled(
        _ installHandler: @escaping () -> Void,
        action: UpdaterCoordinator.InstallAction
    ) {
        guard let recording else {
            installHandler()
            return
        }
        // whenSessionEnds の登録を stop() より先に行う — 先に止めると、ファイナライズの
        // 完了が誰にも待たれないまま再起動しうる (applicationShouldTerminate と同じ順序)
        recording.whenSessionEnds { [weak self] in
            guard let self else { return }
            guard let current = self.recording else {
                installHandler()
                return
            }
            let next = UpdaterCoordinator.installAction(
                isActive: current.isActive,
                awaitingNotification: current.awaitingNotification)
            switch next {
            case .immediate:
                installHandler()
            case .afterStop, .afterNotification:
                // 待つべきものが残っている — 現在のセッションに束縛して待ち直す
                self.postponeUntilSettled(installHandler, action: next)
            }
        }
        if action == .afterStop {
            recording.stop()
        }
    }
}
