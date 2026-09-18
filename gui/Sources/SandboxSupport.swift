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
    /// (2026-09-18 実測)
    static func userVisibleMoviesDirectory() -> URL {
        let fileManager = FileManager.default
        let containerMovies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
        // コンテナ内 Movies が実 ~/Movies への symlink なら、解決するだけで実パスになる
        if let containerMovies {
            let resolved = containerMovies.resolvingSymlinksInPath()
            if !isInsideContainer(resolved) { return resolved }
        }
        // symlink でなければ実ホームから組む (新規コンテナはこちら)
        let movies = realHomeDirectory().appendingPathComponent("Movies", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: movies.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return movies
        }
        // ~/Movies が消されている場合は作る。それも通らなければ **書ける場所** へ退く —
        // 保存先として使えない実ホーム直下 (サンドボックスでは書けない) を返すより、
        // コンテナ内でも録画が成立するほうがまし
        if (try? fileManager.createDirectory(at: movies, withIntermediateDirectories: true)) != nil {
            return movies
        }
        return containerMovies ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// 保存先のパスを「ユーザーから見えるパス」へ正規化する。
    ///
    /// config.json に**コンテナ内のパスが残っている**ことがある — リジェクトされた版で
    /// «この音声・保存先の選択を既定にする» を押すと、コンテナのパスがそのまま保存されるため。
    /// コンテナ外のパス (NSOpenPanel で選んだ保存先) は触らない — security-scoped な
    /// アクセスはその URL に紐づいており、別のパスに書き換えるとアクセス権を失う
    static func userVisible(_ url: URL) -> URL {
        guard isInsideContainer(url) else { return url }
        let resolved = url.resolvingSymlinksInPath()
        // 解決してもコンテナ内 (= Movies 以外のコンテナ内ディレクトリ) なら、
        // ユーザーがアクセスできる場所ではないので既定へ戻す
        return isInsideContainer(resolved) ? userVisibleMoviesDirectory() : resolved
    }

    /// サンドボックスのコンテナ (`…/Library/Containers/<id>/Data`)。サンドボックスが
    /// **効いていない**ビルド (CODE_SIGNING_ALLOWED=NO のコンパイル確認ビルドなど) では nil。
    ///
    /// `NSHomeDirectory()` をそのままコンテナと見なしてはいけない — 非サンドボックス実行では
    /// 実ホームが返るので、`~/Desktop` や `~/Movies` まで「コンテナ内」と誤判定し、
    /// ユーザーが選んだ保存先を既定へ巻き戻してしまう
    private static var containerDataDirectory: String? {
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
    /// 実ホームを返す (2026-09-18 実測)
    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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
    /// 保存先を **変更** したときは旧 URL のアクセスをここで解放する —
    /// 録画済みファイルは既に開かれている (開いた fd は sandbox extension の
    /// 取り消しで無効にならない) ので、書きかけへの影響はない
    static func persist(_ url: URL) {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        if accessedURL == url { return }
        accessedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        } else {
            accessedURL = nil
        }
    }
}
#endif
