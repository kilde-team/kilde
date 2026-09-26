#if APPSTORE
import Foundation
import KildeCore

/// App Sandbox 下 (App Store 配布ビルド、issue #126) でだけ必要な支援コード。
/// 直接配布ビルド (非サンドボックス) では丸ごとコンパイル対象外。
///
/// サンドボックス下で「ホーム直下の ~/.kilde」や「設定ファイルで知ったパス」には
/// アクセスできない。アクセスできるのは **アプリコンテナ内** と
/// **ユーザーが NSOpenPanel で選んだディレクトリ** (movie フォルダのエンタイトルメント
/// があれば ~/Movies も) だけ。ここではその 2 つの経路を提供する
enum SandboxSupport {

    /// KildeCore の設定保存先 (ConfigStore.directory) をアプリコンテナ内へ退避させる。
    ///
    /// 既定の `~/.kilde` はサンドボックス下で読み書きできず、config.json / monitor-state.json への
    /// load()/save() が **必ず失敗する** (設定もホットキーも保存できない)。directory は
    /// «単体テストで実環境を壊さないよう差し替える» ために公開されている static var なので、
    /// それを使う。エンジン (kilde-cli-swift) 側の変更は不要
    ///
    /// **ConfigStore を最初に触るより前に呼ぶこと** — static var は初回アクセス時に
    /// 初期化されるので、それ以降の差し替えは間に合わない。現在の最初の消費者は
    /// RecordingSetup.init (AppDelegate のプロパティ初期化)。ここ以外から先に
    /// ConfigStore に触る実装を足すときは、この呼び出しの位置を見直すこと
    static func redirectConfigStoreIntoContainer() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        // サンドボックス下では .applicationSupportDirectory がコンテナ内を指す。
        // ホーム直下の ".kilde" と対応する場所として <コンテナ>/Application Support/kilde を使う
        let directory = support.appendingPathComponent("kilde", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ConfigStore.directory = directory
    }

    /// 録画の保存先の既定 (~/Movies) を **ユーザーから見えるパス** で返す。
    ///
    /// `FileManager.urls(for: .moviesDirectory, in: .userDomainMask)` はサンドボックス下で
    /// **コンテナ内の** `~/Library/Containers/<id>/Data/Movies` を返す。新規コンテナでは
    /// そこが実ディレクトリとして作られ、**録画がコンテナの中に落ちる** (2026-09-18 実測:
    /// 修正前のビルドは ~/Movies の既存録画を 1 件も見つけられなかった)。実 `~/Movies` への
    /// symlink になっている場合でも、アプリが持ち回るパス文字列はコンテナのままなので、
    /// 録画完了のパス表示・通知の「Finder で表示」・「最近の録画」がユーザーから
    /// アクセスできない場所を指す。これで **App Store 審査 Guideline 2.4.5(i)**
    /// (ユーザーがアクセスできないコンテナへの保存) としてリジェクトされた
    /// (0.3.0 (2)、2026-09-17)。
    ///
    /// 実 `~/Movies` を指せば表示も Finder の表示先もユーザーのフォルダになり、
    /// `com.apple.security.assets.movies.read-write` があるので書き込みも通る
    /// (2026-09-18 実測)。
    ///
    /// **この関数はコンテナ内のパスを決して返さない。** 「書ける場所へ退く」ために
    /// コンテナを返すのはリジェクト理由そのもの — ~/Movies が使えない異常時は
    /// 録画開始時にエラーにして、ユーザーに「変更…」で選び直させるほうが正しい
    /// (Codex レビュー指摘)
    static func userVisibleMoviesDirectory() -> URL {
        let fileManager = FileManager.default
        // コンテナ内 Movies が実 ~/Movies への symlink なら、解決するだけで実パスになる
        if let containerMovies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let resolved = containerMovies.resolvingSymlinksInPath()
            if !isInsideContainer(resolved) { return resolved }
        }
        // symlink でなければ実ホームから組む (新規コンテナはこちら)
        let movies = realHomeDirectory().appendingPathComponent("Movies", isDirectory: true)
        var isDirectory: ObjCBool = false
        if !(fileManager.fileExists(atPath: movies.path, isDirectory: &isDirectory)
            && isDirectory.boolValue) {
            // ~/Movies が消されているのは標準の macOS では起きないが、あれば作る。
            // **作れなくてもこのパスを返す** — 上記のとおりコンテナへは退かない
            try? fileManager.createDirectory(at: movies, withIntermediateDirectories: true)
        }
        return movies
    }

    /// 保存先のパスを「ユーザーから見えるパス」へ正規化する。
    ///
    /// config.json に**コンテナ内のパスが残っている**ことがある — リジェクトされた版で
    /// «この音声・保存先の選択を既定にする» を押すと、コンテナのパスがそのまま保存されるため
    static func userVisible(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        // **実体**がコンテナ内ならユーザーはアクセスできないので既定へ戻す。
        // 判定を解決後に行うのは、`~/Movies/Archive` のような «コンテナ外に見えて
        // 中身はコンテナ» の symlink を取りこぼさないため (Codex レビュー指摘)
        if isInsideContainer(resolved) { return userVisibleMoviesDirectory() }
        // url 自体がコンテナ内の symlink (…/Data/Movies → ~/Movies) なら解決結果を使う
        if isInsideContainer(standardized) { return resolved }
        // コンテナ外のパスは **そのまま返す** — NSOpenPanel で選んだ URL を書き換えると
        // security-scoped なアクセス権を失う
        return url
    }

    /// url が (symlink を解決した実体も含めて) コンテナ内を指すか。
    /// bookmark から復元した URL の検査に使う
    static func pointsInsideContainer(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return isInsideContainer(standardized)
            || isInsideContainer(standardized.resolvingSymlinksInPath())
    }

    /// サンドボックスのコンテナ (`…/Library/Containers/<id>/Data`)。サンドボックスが
    /// **効いていない**ビルド (CODE_SIGNING_ALLOWED=NO のコンパイル確認ビルドなど) では nil。
    ///
    /// `NSHomeDirectory()` をそのままコンテナと見なしてはいけない — 非サンドボックス実行では
    /// 実ホームが返るので、`~/Desktop` や `~/Movies` まで「コンテナ内」と誤判定し、
    /// ユーザーが選んだ保存先を既定へ巻き戻してしまう。
    /// `APP_SANDBOX_CONTAINER_ID` はサンドボックス下でだけ設定される (2026-09-18 実測)。
    /// パス形の確認と **両方**揃って初めてコンテナと見なす — 環境変数は子プロセスへ
    /// 継承されうるため、単独では «サンドボックスアプリが起動した非サンドボックスの
    /// 子プロセス» を誤判定する
    private static var containerDataDirectory: String? {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        else { return nil }
        let home = NSHomeDirectory()
        return home.contains("/Library/Containers/") ? home : nil
    }

    /// サンドボックスのコンテナ内を指すパスか。
    /// **渡された URL を解決し直さない** — 呼び出し側は «解決した結果» を判定にかけるため、
    /// ここで再解決すると判定の意味が変わる
    private static func isInsideContainer(_ url: URL) -> Bool {
        guard let container = containerDataDirectory else { return false }
        // 末尾に "/" を足して "…/Data" と "…/DataOther" を取り違えないようにする
        return url.path == container || url.path.hasPrefix(container + "/")
    }

    /// 実ホームディレクトリ。`NSHomeDirectory()` はサンドボックス下でコンテナを返すため
    /// 使えない — パスワードデータベース (getpwuid) はサンドボックスの影響を受けず、
    /// 実ホームを返す (2026-09-18 実測)。
    /// 取れなかったときは `/Users/<ログイン名>` を組む — **コンテナのホームで代用しない**
    /// (コンテナを保存先にするのが今回のリジェクト原因なので、その経路を残さない)
    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
            if !isInsideContainer(home) { return home }
        }
        return URL(fileURLWithPath: "/Users", isDirectory: true)
            .appendingPathComponent(NSUserName(), isDirectory: true)
    }
}

/// 保存先ディレクトリの security-scoped bookmark の保存と復元 (issue #126)。
///
/// NSOpenPanel で選んだディレクトリへのアクセスは**そのプロセスの生存中限り**。
/// メニューバーアプリは起動をまたいで同じ保存先を使い続けるのが普通なので、
/// app-scope bookmark (KildeGUI-AppStore.entitlements の
/// com.apple.security.files.bookmarks.app-scope が必要) で永続化する。
/// UserDefaults に置くのは、~/.kilde/config.json (CLI と共有) を MAS 専用の
/// blob で汚さないため — CLI は bookmark を解釈できず、設定の検証も通らない
@MainActor
enum SandboxOutputDirectory {

    private static let bookmarkKey = "outputDirectoryBookmark"

    /// 現在アクセスを開始していて (対応する stop をまだ呼んでいない) URL。
    /// start/stop は対応が取れているのが契約 — persist() での同じ URL の再選択時に
    /// start を重ねない、保存先変更時に旧 URL を解放する、の 2 つにこの 1 変数を使う
    /// (CodeRabbit レビュー指摘: 開始しっぱなしを重ねると sandbox extension が
    /// リークして、繰り返しの保存先変更で新規の powerbox 許可が失敗しうる)
    private static var accessedURL: URL?

    /// 前回起動時に選んだ保存先を bookmark から復元する。
    /// 成功時はアクセスを開始して **プロセス終了まで保持する** — 録画のたびに
    /// start/stop を往復させず、閉じ忘れ (アクセス喪失) の経路を作らないため。
    /// nil は «bookmark が無い» または «解決に失敗した» (ディレクトリが消えた等)。
    /// 復元できなければ既定の ~/Movies のままなので、呼び出し側は失敗を通知しない
    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale),
            url.startAccessingSecurityScopedResource()
        else { return nil }
        // 0.3.0 (2) までの既定は **コンテナ内の** Movies だった。当時「変更…」を開いて
        // その既定をそのまま選ぶと、コンテナのパスが bookmark に残る。復元すると
        // config 側の正規化 (SandboxSupport.userVisible) を打ち消して録画が再び
        // コンテナへ落ちる — Guideline 2.4.5(i) の再発になる (Codex レビュー指摘)。
        // 開始したアクセスを閉じ、bookmark ごと捨てて既定 (~/Movies) に任せる
        if SandboxSupport.pointsInsideContainer(url) {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        // ディレクトリの移動等で stale になった bookmark は «この起動では解決できても
        // 次の起動では解決できない» 状態。解決できた今の URL から作り直して永続化し、
        // 保存先が黙って ~/Movies に戻るのを防ぐ (cubic レビュー指摘)
        if stale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        accessedURL = url
        return url
    }

    /// 選択された保存先を bookmark として永続化し、今このプロセスでのアクセスも開始する。
    /// bookmark の作成に失敗しても選択自体は有効 (この起動中は powerbox の許可で
    /// アクセスできる) なので、失敗は通知せず続行する — 次回起動時に既定へ戻るだけ
    ///
    /// restore() の「プロセス終了まで保持」はあくまで起動時の既定経路の話。
    /// 保存先を **変更** したときは旧 URL のアクセスをここで解放する。
    /// 録画中の書き込みは既に開かれた fd なので (sandbox extension の取り消しで
    /// 無効にならない) 影響を受けないが、**録画完了後の文字起こしは旧フォルダを
    /// 読み・サイドカーを書く** — キュー中の Job は enqueue 時に自前で
    /// security-scoped bookmark を保持し、実行時に取り直す
    /// (TranscriptionCoordinator、issue #192)
    /// NSOpenPanel で選ばれた保存先を記録する。
    ///
    /// **panel.url に `startAccessingSecurityScopedResource()` を呼んではいけない。**
    /// Apple のドキュメント (Accessing files from the macOS App Sandbox) が
    /// «The operating system starts security-scoped access on URLs passed from open
    /// panels, save panels, or items dragged to your app's icon in the Dock, as if you
    /// called startAccessingSecurityScopedResource()» と明示している — つまりパネル
    /// 由来の URL は **OS が既に 1 回分開始済み**。ここで重ねて呼ぶと start が 2 回・
    /// stop が 1 回になり、sandbox extension がリークする。保存先の変更を繰り返すと
    /// カーネル資源が積み上がり、いずれ新しい extension を取れなくなる
    /// (Codex レビュー指摘)。
    ///
    /// `accessedURL` は «1 回分の start が生きている URL» を表す — bookmark から
    /// `restore()` が明示的に開始したものも、パネルが暗黙に開始したものも同じ 1 回分
    /// 戻り値は «次回起動に持ち越せたか» (bookmark を保存できたか)。
    /// **false でも選択自体は有効** — パネル由来の URL はこのプロセスの間は使えるので、
    /// 保存先の変更は採用してよい。持ち越せないことだけ呼び出し側から知らせる
    /// (CodeRabbit レビュー指摘への対応。選択ごと拒否はしない — ユーザーが選んだ
    /// 保存先を «bookmark を作れなかったから» と無言で捨てるほうが不親切なため)
    @discardableResult
    static func persist(_ url: URL) -> Bool {
        let persisted = updateBookmark(for: url)
        if accessedURL == url {
            // 同じ保存先を選び直した。パネルが **新たに 1 回** 開始しているので、
            // その分をここで解放して数を合わせる (保持するのは既存の 1 回分)
            url.stopAccessingSecurityScopedResource()
            return persisted
        }
        // 保存先の変更。旧 URL の 1 回分を解放し、パネルが開始した新 URL の分を保持する。
        // 録画中の書き込みは開かれた fd なので無効にならないが、録画完了後の
        // 文字起こしは旧フォルダを読み書きする — キュー中の Job は enqueue 時に
        // 自前で bookmark を保持して取り直す (TranscriptionCoordinator、issue #192)
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url
        return persisted
    }

    /// 選択された保存先の bookmark を保存する。戻り値は保存できたか。
    /// 作成に失敗したときは **古い bookmark を残さない** — 残すと次回起動で
    /// «選んだ覚えのない前の保存先» が黙って復元される (cubic レビュー指摘)
    private static func updateBookmark(for url: URL) -> Bool {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return false
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }
}

/// 議事録 (.md) の書き出し先フォルダの security-scoped bookmark (issue #164)。
///
/// 録画の保存先 (`SandboxOutputDirectory`) とは**別の bookmark** にする —
/// «録画ファイルの置き場所» と «議事録を流す先 (Obsidian vault など)» は
/// 別の場所を指すのが普通で、片方の変更がもう片方を壊すべきではないため。
/// UserDefaults に置く理由 (config.json を blob で汚さない) は
/// SandboxOutputDirectory と同じ。app-scope bookmark の entitlement も共用
@MainActor
enum SandboxExportDirectory {

    private static let bookmarkKey = "exportDirectoryBookmark"

    /// 現在アクセスを開始している URL (SandboxOutputDirectory.accessedURL と同じ契約)。
    /// 書き出しは録画完了のたびに走るため、start/stop を往復させず
    /// **プロセス生存中は保持しっぱなし**にする
    private static var accessedURL: URL?

    /// 前回起動時に選んだ書き出し先を bookmark から復元する。
    /// 成功時はアクセスを開始してプロセス終了まで保持する。nil は «未設定 / 解決失敗»。
    /// コンテナ内を指す bookmark は録画の保存先と同じ理由で捨てる
    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale),
            url.startAccessingSecurityScopedResource()
        else { return nil }
        if SandboxSupport.pointsInsideContainer(url) {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        accessedURL = url
        return url
    }

    /// 書き出し先の選択を bookmark に永続化する。SandboxOutputDirectory.persist と同じ
    /// «パネル由来の URL は OS が 1 回分開始済み» の契約に従う。
    /// 戻り値は bookmark を次回起動に持ち越せたか (false でも選択は有効)
    @discardableResult
    static func persist(_ url: URL) -> Bool {
        let persisted = updateBookmark(for: url)
        if accessedURL == url {
            url.stopAccessingSecurityScopedResource()
            return persisted
        }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url
        return persisted
    }

    /// 書き出し先の解除。bookmark を捨て、保持しているアクセスを解放する
    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    /// 選択された書き出し先の bookmark を保存する。作成に失敗したときは
    /// **古い bookmark を残さない** (SandboxOutputDirectory と同じ — cubic レビュー指摘)
    private static func updateBookmark(for url: URL) -> Bool {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return false
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }
}
#endif
