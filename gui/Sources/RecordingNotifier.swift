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

    /// 文字起こし完了通知のカテゴリ (issue #147)。«開く» / «Finder で表示» の 2 アクションを
    /// 持つ。id は固定文字列 — 登録済みカテゴリと content.categoryIdentifier の突き合わせに
    /// 使うだけなので、文言の変更に引きずられない
    nonisolated static let transcriptCategoryID = "kilde.transcript.completed"
    /// «開く» のアクション id。既定のバナー全体のクリックと同じ動作 (ファイルを開く) にする
    private nonisolated static let transcriptOpenActionID = "kilde.transcript.open"
    /// «Finder で表示» のアクション id。録画完了通知と同じ選択表示にする
    private nonisolated static let transcriptRevealActionID = "kilde.transcript.reveal"

    private let center = UNUserNotificationCenter.current()

    /// アプリ起動時に 1 回呼ぶ。許可ダイアログはここで出る。
    /// 拒否されても録画機能は完全に動くので、エラーにはしない
    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // 文字起こし完了通知のカテゴリ (issue #147)。**ここで 1 回だけ登録する** —
        // 通知を出すたびに setNotificationCategories を投げると、登録の反映を待たずに
        // add した通知がアクション無しのバナーになる競合を作る。起動直後の登録は
        // 最初の文字起こし完了 (数分以上先) より十分早い
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.transcriptCategoryID,
                actions: [
                    // .foreground: 押したらアプリ (と開く先のアプリ) を前面にする。
                    // メニューバーアプリは通知クリックでも前面にならないことがある
                    // (didReceive のコメント参照) ので、«開く» は明示的に前面化する
                    UNNotificationAction(
                        identifier: Self.transcriptOpenActionID,
                        title: String(localized: "開く"),
                        options: [.foreground]),
                    UNNotificationAction(
                        identifier: Self.transcriptRevealActionID,
                        title: String(localized: "Finder で表示"),
                        options: []),
                ],
                intentIdentifiers: [])
        ])
    }

    /// 録画完了を通知する。`elapsed` は一時停止を除いた実収録時間
    ///
    /// **許可状態を自前で持たない。** 一度はキャッシュする実装にしたが、
    /// 取得が非同期である以上「短い録画が旗の立つ前に終わって通知が捨てられる」
    /// という別の消え方を作るだけだった。未許可のときは `add` が黙って捨てるので、
    /// **判定せずに投げるのが最も確実で、状態も競合も持たずに済む**
    /// `bytes` は進捗由来のサイズ。**出力ファイルを `stat` しない。**
    ///
    /// 三つの要求は同時には満たせない、というのがレビューの往復で分かったこと:
    ///
    /// 1. 通知が確実に届く (録画完了直後にアプリを終了しても)
    /// 2. MainActor を塞がない (遅いボリュームで `attributesOfItem` が返らない)
    /// 3. 進捗が 1 度も来なかった短い録画でも実サイズを出す
    ///
    /// MainActor で `stat` すると 2 が壊れ、`Task.detached` で逃がすと
    /// **`notifyThenEndSession` のタイムアウトも `applicationShouldTerminate` も
    /// その完了を待てず 1 が壊れる**。1 は issue #20 の目的そのもの (他アプリで
    /// 作業している人に結果を伝える) なので、**3 を捨てる**。
    /// 短い録画でサイズが 0 になるが、通知が届かないことに比べれば軽い
    func notifyCompleted(url: URL, elapsed: TimeInterval, bytes: Int64,
                         completion: @escaping () -> Void = {}) {
        let identifier = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = String(localized: "録画を保存しました")
        // 本文はファイル名 + 長さ + サイズ。パス全体は長すぎて通知に収まらないので
        // ファイル名だけにし、場所は Finder 表示で見せる。
        // サイズが分からない (進捗が 1 度も来ない短い録画) ときは、`0 bytes` と
        // 嘘を書くより出さない。長さとファイル名だけでも用は足りる
        let size = bytes > 0
            ? " · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            : ""
        content.body = "\(url.lastPathComponent)\n\(Self.formatDuration(elapsed))\(size)"
        content.sound = .default
        // 通知は macOS 側に残るので、**アプリを終了して起動し直した後にクリックされうる**。
        // メモリ上の対応表だけだと復元できないので、パスを通知自身に持たせる
        content.userInfo = [Self.urlKey: url.path]

        remember(identifier: identifier, url: url)
        post(identifier: identifier, content: content, completion: completion)
    }

    /// 文字起こしの完了を通知する (issue #147)。
    ///
    /// **録画完了通知との違いは 2 つ**: アクション («開く» / «Finder で表示») を持ち、
    /// クリックの対象がサイドカー (文字起こし本文) である点。長時間の会議録画の
    /// 文字起こしは完了がポップオーバーの外 (パネルを閉じた後) になることが普通なので、
    /// «できました» を他アプリの前面からでも受け取れるようにする。
    /// TranscriptionCoordinator の onCompletion (AppDelegate が配線) から呼ばれる
    func notifyTranscriptionCompleted(sidecarURL: URL,
                                      completion: @escaping () -> Void = {}) {
        let identifier = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = String(localized: "文字起こしを保存しました")
        // パス全体は長すぎるのでファイル名だけ。場所は «Finder で表示» と
        // «最近の録画» で見せる (録画完了通知と同じ方針)
        content.body = sidecarURL.lastPathComponent
        content.sound = .default
        content.categoryIdentifier = Self.transcriptCategoryID
        // 通知は macOS 側に残るため、再起動後のクリックでも対象を開けるように
        // パスを通知自身に持たせる (録画完了通知と同じ)
        content.userInfo = [Self.urlKey: sidecarURL.path]

        remember(identifier: identifier, url: sidecarURL)
        post(identifier: identifier, content: content, completion: completion)
    }

    /// 録画の失敗を通知する。**ホットキーで他アプリの前面から始めた録画のため**に要る —
    /// 開始後に失敗 (収録対象のウィンドウが閉じた、デバイスが外れた、権限の失効) しても、
    /// ポップオーバーを開くまで何も見えず、メニューバーは待機アイコンに戻るだけになる
    func notifyFailed(message: String, completion: @escaping () -> Void = {}) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "録画に失敗しました")
        content.body = message
        content.sound = .default
        post(identifier: UUID().uuidString, content: content, completion: completion)
    }

    /// trigger: nil は «即座に配信»。時間指定の通知ではないので待たせない。
    ///
    /// `add` は非同期 (XPC) なので、「録画中にアプリを終了」経路ではプロセスが先に
    /// 落ちて通知が届かないことがある。**その窓を閉じるため、登録の完了を
    /// `completion` で呼び出し元へ返し、終了応答をそれまで待たせる。**
    /// 応答が来ないまま終了が止まらないよう、呼び出し元はタイムアウトを持つこと
    private func post(identifier: String, content: UNMutableNotificationContent,
                      completion: @escaping () -> Void) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in
            Task { @MainActor in completion() }
        }
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
        switch revealTarget(for: url) {
        case .select(let target):
            NSWorkspace.shared.activateFileViewerSelecting([target])
        case .open(let directory):
            NSWorkspace.shared.open(directory)
        }
    }

    /// Finder で何を開くかの決定。**副作用を持たないので検証から呼べる** —
    /// `revealInFinder` の分岐をテスト側で書き写すと、実装が退行しても
    /// テストが通ってしまう (T21 がまさにそうなっていた)
    enum RevealTarget: Equatable {
        /// 実在するファイル。Finder で選択表示する
        case select(URL)
        /// ファイルが無いので親ディレクトリを開く
        case open(URL)

        /// 検証・表示用のパス
        var url: URL {
            switch self {
            case .select(let url), .open(let url): return url
            }
        }
    }

    static func revealTarget(for url: URL) -> RevealTarget {
        FileManager.default.fileExists(atPath: url.path)
            ? .select(url)
            : .open(url.deletingLastPathComponent())
    }

    // MARK: - 表示の整形

    /// 00:00 / h:mm:ss 形式。RecordingController.formatElapsed と同じ規則にする
    /// (メニューバーの表示と通知で長さの見え方が食い違わないように)
    private static func formatDuration(_ elapsed: TimeInterval) -> String {
        RecordingController.formatElapsed(elapsed)
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

    /// 通知をクリックしたら Finder で選択表示する (issue #20 の受け入れ条件)。
    /// 文字起こし完了通知 (issue #147) は «開く» / 既定クリックでファイルを開き、
    /// «Finder で表示» で選択表示する
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        // 再起動後は対応表が空なので、通知自身が持つパスを使う
        let carried = (response.notification.request.content.userInfo[Self.urlKey] as? String)
            .map { URL(fileURLWithPath: $0) }
        let isTranscript = response.notification.request.content.categoryIdentifier
            == Self.transcriptCategoryID
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self else { return }
            guard let url = self.take(identifier: identifier) ?? carried else { return }
            // LSUIElement のアプリは通知クリックでもアクティブにならないことがあり、
            // 開いた Finder / テキストエディタが他のウィンドウの後ろに出る場合がある
            NSApp.activate(ignoringOtherApps: true)
            if isTranscript, action != Self.transcriptRevealActionID {
                // «開く» と既定クリック (バナー本体) は既定アプリで開く。
                // «Finder で表示» (revealAction) だけが選択表示に分岐する。
                // 予期しないアクション id も «開く» 側に倒す — 潰すより用は足りる
                NSWorkspace.shared.open(url)
            } else {
                Self.revealInFinder(url)
            }
        }
    }

    /// クリックされた通知の URL を取り出して対応表から消す
    private func take(identifier: String) -> URL? {
        deliveredOrder.removeAll { $0 == identifier }
        return deliveredURLs.removeValue(forKey: identifier)
    }
}
