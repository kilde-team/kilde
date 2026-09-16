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
        return url
    }

    /// 選択された保存先を bookmark として永続化し、今このプロセスでのアクセスも開始する。
    /// bookmark の作成に失敗しても選択自体は有効 (この起動中は powerbox の許可で
    /// アクセスできる) なので、失敗は通知せず続行する — 次回起動時に既定へ戻るだけ
    static func persist(_ url: URL) {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        _ = url.startAccessingSecurityScopedResource()
    }
}
#endif
