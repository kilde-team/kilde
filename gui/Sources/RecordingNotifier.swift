import AppKit
import UserNotifications
import KildeCore

/// 録画完了の通知と Finder 表示 (issue #20)。
///
/// 通知のクリックで Finder に該当ファイルを選択表示する。`UNUserNotificationCenter` は
/// バンドル ID と署名を要求するため、CLI (sectcreate で Info.plist を埋め込むだけの
/// 実行ファイル) では使えない — GUI 専用の機能として gui/ 側に置く。
///
/// `UNUserNotificationCenter.delegate` は **weak** なので、AppDelegate がこのオブジェクトを
/// 強参照で保持する。手放すとデリゲートが解放され、通知をクリックしても Finder が開かない。
/// `@MainActor` にしているのは、通知の応答ハンドラから Finder を開く (AppKit) ため
@MainActor
final class RecordingNotifier: NSObject {

    /// 通知の identifier から元のファイルを引くための対応表。
    /// userInfo にパスを入れて渡すこともできるが、削除・移動されたファイルを
    /// 開こうとしたときに «選択できない» ことを判定したいので URL を保持する
    private var deliveredURLs: [String: URL] = [:]
    /// 追加順。クリックされないまま消えた通知の分が溜まり続けるので、
    /// 上限を超えたら古い方から捨てる (メニューバーアプリはプロセスが長生きする)
    private var deliveredOrder: [String] = []
    private static let deliveredLimit = 32
    /// 通知の userInfo に入れるファイルパスのキー (再起動後のクリック用)。
    /// `nonisolated` なデリゲートメソッドから読むので隔離しない
    /// (@MainActor 隔離のままだと Swift 6 言語モードでエラーになる)
    nonisolated static let urlKey = "kilde.outputPath"

    private let center = UNUserNotificationCenter.current()

    /// アプリ起動時に 1 回呼ぶ。許可ダイアログはここで出る。
    /// 拒否されても録画機能は完全に動くので、エラーにはしない
    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 録画完了を通知する。`elapsed` は一時停止を除いた実収録時間
    ///
    /// **許可状態を自前で持たない。** 一度はキャッシュする実装にしたが、
    /// 取得が非同期である以上「短い録画が旗の立つ前に終わって通知が捨てられる」
    /// という別の消え方を作るだけだった。未許可のときは `add` が黙って捨てるので、
    /// **判定せずに投げるのが最も確実で、状態も競合も持たずに済む**
    func notifyCompleted(url: URL, elapsed: TimeInterval) {
        let identifier = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "録画を保存しました"
        // 本文はファイル名 + 長さ + サイズ。パス全体は長すぎて通知に収まらないので
        // ファイル名だけにし、場所は Finder 表示で見せる
        content.body = "\(url.lastPathComponent)\n\(Self.formatDuration(elapsed)) · \(Self.formatSize(of: url))"
        content.sound = .default
        // 通知は macOS 側に残るので、**アプリを終了して起動し直した後にクリックされうる**。
        // メモリ上の対応表だけだと復元できないので、パスを通知自身に持たせる
        content.userInfo = [Self.urlKey: url.path]

        remember(identifier: identifier, url: url)
        post(identifier: identifier, content: content)
    }

    /// 録画の失敗を通知する。**ホットキーで他アプリの前面から始めた録画のため**に要る —
    /// 開始後に失敗 (収録対象のウィンドウが閉じた、デバイスが外れた、権限の失効) しても、
    /// ポップオーバーを開くまで何も見えず、メニューバーは待機アイコンに戻るだけになる
    func notifyFailed(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "録画に失敗しました"
        content.body = message
        content.sound = .default
        post(identifier: UUID().uuidString, content: content)
    }

    /// trigger: nil は «即座に配信»。時間指定の通知ではないので待たせない。
    ///
    /// **`add` 自体は非同期 (XPC) なので、「録画中にアプリを終了」経路では
    /// プロセスが先に落ちて通知が届かないことがある。** 完了時に許可状態を
    /// 問い合わせる形をやめたのはその窓を狭めるためだが、窓が閉じたわけではない
    private func post(identifier: String, content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }

    /// identifier → URL を覚える。上限を超えたら古い方から捨てる
    private func remember(identifier: String, url: URL) {
        deliveredURLs[identifier] = url
        deliveredOrder.append(identifier)
        while deliveredOrder.count > Self.deliveredLimit {
            let oldest = deliveredOrder.removeFirst()
            deliveredURLs.removeValue(forKey: oldest)
        }
    }

    /// Finder で該当ファイルを選択表示する。通知のクリックと «最近の録画» の両方から使う。
    /// ファイルが消えていたら、その親ディレクトリを開いて «場所は合っているが無い» を見せる
    static func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - 表示の整形

    /// 00:00 / h:mm:ss 形式。RecordingController.formatElapsed と同じ規則にする
    /// (メニューバーの表示と通知で長さの見え方が食い違わないように)
    private static func formatDuration(_ elapsed: TimeInterval) -> String {
        RecordingController.formatElapsed(elapsed)
    }

    private static func formatSize(of url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension RecordingNotifier: UNUserNotificationCenterDelegate {

    /// アプリが前面でも通知を出す。LSUIElement のメニューバーアプリは «前面» の
    /// 判定が直感と合わないうえ、ポップオーバーを開いたまま録画を止めることがあるため
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 通知をクリックしたら Finder で選択表示する (issue #20 の受け入れ条件)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        // 再起動後は対応表が空なので、通知自身が持つパスを使う
        let carried = (response.notification.request.content.userInfo[Self.urlKey] as? String)
            .map { URL(fileURLWithPath: $0) }
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self else { return }
            guard let url = self.take(identifier: identifier) ?? carried else { return }
            // LSUIElement のアプリは通知クリックでもアクティブにならないことがあり、
            // Finder が他のウィンドウの後ろに出る場合がある
            NSApp.activate(ignoringOtherApps: true)
            Self.revealInFinder(url)
        }
    }

    /// クリックされた通知の URL を取り出して対応表から消す
    private func take(identifier: String) -> URL? {
        deliveredOrder.removeAll { $0 == identifier }
        return deliveredURLs.removeValue(forKey: identifier)
    }
}
