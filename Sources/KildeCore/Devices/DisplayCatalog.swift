import Foundation
import CoreGraphics
import ScreenCaptureKit

public struct DisplayInfo: CustomStringConvertible {
    public let index: Int
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int

    public var description: String {
        "display[\(index)] \(width)x\(height) displayID=\(displayID)"
    }
}

public struct WindowInfo: CustomStringConvertible {
    public let windowID: UInt32
    public let title: String?
    public let bundleIdentifier: String?
    public let frame: CGRect
    public let isOnScreen: Bool

    public var description: String {
        "  [\(windowID)] \(bundleIdentifier ?? "?") \"\(title ?? "")\" \(Int(frame.width))x\(Int(frame.height))"
    }

    func matches(_ text: String) -> Bool {
        (title ?? "").localizedCaseInsensitiveContains(text)
            || (bundleIdentifier ?? "").localizedCaseInsensitiveContains(text)
    }
}

/// SCShareableContent の列挙ラッパ (DESIGN.md §4 DeviceCatalog)。
///
/// 公開 API は同期版と async 版を同名で持つ (issue #35)。
/// - async 版: Recorder のセッションや GUI の `.task { }` など async コンテキストから使う
/// - 同期版: CLI のサブコマンドや GUI の onAppear など同期コンテキスト専用。内部で awaitSync
///   (呼び出しスレッドをブロック) するため noasync にしてあり、async コンテキストから呼ぶと警告になる
public enum DisplayCatalog {

    /// ディスプレイと (任意の) ウィンドウ一覧を取得する (同期コンテキスト専用)。
    ///
    /// 同期版は `awaitSync` で呼び出しスレッドを塞ぐので、ロックの待機上限は
    /// 録画用の 15 秒ではなく `enumerationTimeout` (3 秒) を使う — `devices` /
    /// `doctor` が一覧を出すだけで長時間無反応になるのを避けるため (issue #90)
    @available(*, noasync, message: "async コンテキストでは try await DisplayCatalog.snapshot() を使ってください")
    public static func snapshot() throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        try awaitSync { try await snapshot(lockTimeout: SCKStartupLock.enumerationTimeout) }
    }

    /// ディスプレイと (任意の) ウィンドウ一覧を取得する。
    /// `usesStartupLock` の意味は `shareableContent(_:usesStartupLock:lockTimeout:)` を参照
    public static func snapshot(usesStartupLock: Bool = true,
                                lockTimeout: TimeInterval = SCKStartupLock.defaultTimeout)
        async throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        let content = try await shareableContent("画面の一覧を取得できません (画面収録権限を確認してください)",
                                                 usesStartupLock: usesStartupLock,
                                                 lockTimeout: lockTimeout)
        let displays = content.displays.enumerated().map { i, d in
            DisplayInfo(index: i, displayID: d.displayID, width: Int(d.width), height: Int(d.height))
        }
        let windows = content.windows.map { w in
            WindowInfo(
                windowID: w.windowID,
                title: w.title,
                bundleIdentifier: w.owningApplication?.bundleIdentifier,
                frame: w.frame,
                isOnScreen: w.isOnScreen
            )
        }
        return (displays, windows)
    }

    /// on-screen ウィンドウのうちアプリに属するものを返す (同期コンテキスト専用)。
    /// 待機上限が `enumerationTimeout` なのは `snapshot()` と同じ理由 (issue #90)
    @available(*, noasync, message: "async コンテキストでは try await DisplayCatalog.listOnScreenWindows() を使ってください")
    public static func listOnScreenWindows() throws -> [WindowInfo] {
        try awaitSync { try await listOnScreenWindows(lockTimeout: SCKStartupLock.enumerationTimeout) }
    }

    /// on-screen ウィンドウのうちアプリに属するものを返す
    public static func listOnScreenWindows(usesStartupLock: Bool = true,
                                           lockTimeout: TimeInterval = SCKStartupLock.defaultTimeout)
        async throws -> [WindowInfo] {
        try await snapshot(usesStartupLock: usesStartupLock, lockTimeout: lockTimeout)
            .windows.filter { $0.isOnScreen && $0.bundleIdentifier != nil }
    }

    /// SCWindow を解決する。windowID の完全一致を最優先し、無ければタイトル / bundleID の
    /// 部分一致 (複数ヒット時は面積が最大のもの)。
    /// Recorder のセッション (async) からのみ使うので async 版だけを持つ
    /// 指定をまとめて解決する (issue #13)。指定ごとに 1 つのウィンドウを選び
    /// (windowID の完全一致を最優先し、無ければタイトル / bundleID の部分一致で面積が最大のもの
    /// — `resolve(_:in:)` の規則)、同じウィンドウが二重に入らないよう windowID で重複を除く。
    /// 列挙は 1 回にまとめる — 指定ごとに SCShareableContent.current を呼ぶと、その間の
    /// ウィンドウの開閉で指定どうしが食い違った一覧を見ることになる
    static func resolveWindows(matching matches: [String],
                               usesStartupLock: Bool = true) async throws -> [SCWindow] {
        guard !matches.isEmpty else { return [] }
        let content = try await shareableContent("ウィンドウの一覧を取得できません",
                                                 usesStartupLock: usesStartupLock)
        var resolved: [SCWindow] = []
        for match in matches {
            let window = try resolve(match, in: content)
            if !resolved.contains(where: { $0.windowID == window.windowID }) {
                resolved.append(window)
            }
        }
        return resolved
    }

    /// bundleID から実行中アプリを解決する (--exclude-app、issue #13)。
    /// ウィンドウ指定と違って部分一致にしていないのは、除外は「写っていないはず」を期待する
    /// 操作で、取り違えても画面を見るまで気づけないため (例: "slack" で別アプリまで消える)
    static func resolveApplications(bundleIDs: [String],
                                    usesStartupLock: Bool = true) async throws -> [SCRunningApplication] {
        guard !bundleIDs.isEmpty else { return [] }
        let content = try await shareableContent("実行中アプリの一覧を取得できません",
                                                 usesStartupLock: usesStartupLock)
        return try bundleIDs.flatMap { id -> [SCRunningApplication] in
            // 同じ bundleID のインスタンスが複数動いていることがある (プロファイルを分けた
            // ブラウザなど)。first で 1 つだけ返すと、残りのインスタンスの映像と音声が
            // 出力に残ってしまう — 「隠したはずが写っている」ので全部を渡す
            let matched = content.applications.filter {
                $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame
            }
            guard !matched.isEmpty else {
                throw KilError.deviceNotFound(
                    "bundleID \"\(id)\" のアプリが実行中に見つかりません (kilde devices で確認)")
            }
            return matched
        }
    }

    private static func resolve(_ match: String, in content: SCShareableContent) throws -> SCWindow {
        let candidates = content.windows.filter { $0.isOnScreen && $0.owningApplication != nil }
        // windowID の完全一致 (kilde devices の [ID]、GUI・meeting プリセットの選択結果) を先に見る。
        // 部分一致と同列に扱うと、タイトルに同じ数字を含むより大きいウィンドウが選ばれてしまう
        if let exact = candidates.first(where: { String($0.windowID) == match }) {
            return exact
        }
        let matched = candidates.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(match)
                || ($0.owningApplication?.bundleIdentifier ?? "").localizedCaseInsensitiveContains(match)
        }
        guard let best = matched.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            throw KilError.deviceNotFound("\"\(match)\" にマッチするウィンドウがありません (kilde devices で一覧)")
        }
        return best
    }

    /// Recorder のセッション (async) からのみ使うので async 版だけを持つ
    static func display(at index: Int, usesStartupLock: Bool = true) async throws -> SCDisplay {
        let content = try await shareableContent("ディスプレイの一覧を取得できません",
                                                 usesStartupLock: usesStartupLock)
        guard content.displays.indices.contains(index) else {
            throw KilError.deviceNotFound("ディスプレイ \(index) は範囲外です (0...\(content.displays.count - 1))")
        }
        return content.displays[index]
    }

    /// ウィンドウのサムネイル (GUI のウィンドウ選択用 — issue #18)。列挙は 1 回にまとめ、
    /// 撮れなかったウィンドウ (最小化・権限不足・撮影中に閉じた等) は結果に含めない。
    /// サムネイルは補助表示なので、失敗しても例外にせず空の結果で返す
    ///
    /// **列挙はここも `SCKStartupLock` で直列化する (issue #90)。** GUI のサムネイル取得は
    /// `SCShareableContent.current` を直接呼ぶ経路なので、塞がないとここだけ穴が残る。
    /// 補助表示なので待ちは短く (`enumerationTimeout`)、取れなくても続行する
    /// (`shareableContent` と同じ判断 — 失敗させるより競合の危険を取る)。
    ///
    /// **他の列挙と違って `usesStartupLock` を持たない。** サムネイルは GUI のウィンドウ選択
    /// 専用で、**ロックを保持している録画経路からは呼ばれない**ため opt-out する相手がいない。
    /// 録画中の `Recorder` から呼ぶ経路を足す場合は、他の列挙と同じく引数で外せるようにすること
    /// (自分のロックに阻まれて `enumerationTimeout` ぶん待たされ、警告が出る)
    public static func windowThumbnails(windowIDs: [UInt32], maxDimension: Int = 160) async -> [UInt32: CGImage] {
        guard !windowIDs.isEmpty else { return [:] }
        let token = try? await SCKStartupLock.acquire(timeout: SCKStartupLock.enumerationTimeout)
        defer { token?.release() }
        guard let content = try? await SCShareableContent.current else { return [:] }
        var images: [UInt32: CGImage] = [:]
        for id in windowIDs {
            guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
            let longest = max(window.frame.width, window.frame.height, 1)
            let scale = min(1, CGFloat(maxDimension) / longest)
            let configuration = SCStreamConfiguration()
            // points 基準の縮小サイズで撮る (Retina の実解像度はサムネイルには不要)
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                      configuration: configuration) {
                images[id] = image
            }
        }
        return images
    }

    /// SCShareableContent の取得失敗は画面収録権限の不足として扱う (終了コード 2)。
    ///
    /// **列挙も `SCKStartupLock` で直列化する (issue #90)。** `rec` の SCK 起動と列挙が
    /// 重なると、起動側が `SCStream.startCapture()` で `-3801`
    /// (「ユーザがアプリケーション、ウインドウ、ディスプレイ取り込みの TCC を拒否しました」)
    /// を受けて失敗する。実測 (macOS 26、秒境界を揃えて 10 回ずつ交互):
    /// **`devices` 併走ありで 7/10 失敗、単独では 0/10**。権限は付与済みで、
    /// `Recorder` は `startCapture()` の手前で `Permissions.hasScreenCapture` を確認済みなので、
    /// **この `-3801` は権限拒否ではなく競合**。#70 のハングと違って固まりはしないが、
    /// 録画が即座に落ちる。
    ///
    /// `usesStartupLock` を既定 `true` にしているのは、**新しい呼び出し元が黙って
    /// 穴を開けないようにするため**。ロックを既に持っている経路だけが明示的に `false` を渡す。
    ///
    /// **「このプロセスが保持中なら素通りする」再入方式は採らない。** `flock` は同一プロセスの
    /// 別 fd でも排他される (実測で `EWOULDBLOCK`) ので再入対策自体は要るが、プロセス単位の
    /// フラグで素通りさせると、GUI の列挙タスクが**録画開始中に**素通りしてしまう。
    /// 同一プロセス内の列挙と録画開始の競合は DESIGN.md §6 が危険としている当のもので、
    /// 呼び出し箇所ごとの明示指定ならその穴ができない
    private static func shareableContent(_ what: String,
                                         usesStartupLock: Bool = true,
                                         lockTimeout: TimeInterval = SCKStartupLock.defaultTimeout)
        async throws -> SCShareableContent {
        var token: SCKStartupLock.Token?
        // 列挙が throw しても必ず手放す。release() は冪等なので二重解放にならない
        defer { token?.release() }
        if usesStartupLock {
            // **取れなくても列挙は続ける。** ここで失敗させると、`rec` がハング (issue #95) して
            // ロックを握ったままのときに `devices` / `doctor` まで巻き添えで使えなくなる。
            // 診断コマンドは「壊れているときに動く」ことが値打ちなので、待てなかった場合は
            // 競合の危険を承知で進み、理由を stderr に出す
            do {
                token = try await SCKStartupLock.acquire(timeout: lockTimeout)
            } catch {
                // **秒数は切り捨てない。** `Int(0.5)` は 0 になり「0 秒以内に空きませんでした」
                // という意味の通らない文言になる。`lockTimeout` は公開 API の引数なので
                // 任意の値が来うる (同じ誤りを SCKStartupLock 側で一度指摘されている)
                let seconds = lockTimeout == lockTimeout.rounded()
                    ? String(Int(lockTimeout))
                    : String(format: "%.1f", lockTimeout)
                let warning = "WARNING: 他の kilde が録画を開始中のため待機しましたが、"
                    + "\(seconds) 秒以内に空きませんでした。"
                    + "列挙を続行します (同時に録画を開始すると双方が失敗することがあります — issue #90)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
        }
        do {
            return try await SCShareableContent.current
        } catch {
            throw KilError.permission("\(what): \(error.localizedDescription)")
        }
    }
}
