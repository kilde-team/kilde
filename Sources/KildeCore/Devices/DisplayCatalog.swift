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

    /// ディスプレイと (任意の) ウィンドウ一覧を取得する (同期コンテキスト専用)
    @available(*, noasync, message: "async コンテキストでは try await DisplayCatalog.snapshot() を使ってください")
    public static func snapshot() throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        try awaitSync { try await snapshot() }
    }

    /// ディスプレイと (任意の) ウィンドウ一覧を取得する
    public static func snapshot() async throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        let content = try await shareableContent("画面の一覧を取得できません (画面収録権限を確認してください)")
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

    /// on-screen ウィンドウのうちアプリに属するものを返す (同期コンテキスト専用)
    @available(*, noasync, message: "async コンテキストでは try await DisplayCatalog.listOnScreenWindows() を使ってください")
    public static func listOnScreenWindows() throws -> [WindowInfo] {
        try awaitSync { try await listOnScreenWindows() }
    }

    /// on-screen ウィンドウのうちアプリに属するものを返す
    public static func listOnScreenWindows() async throws -> [WindowInfo] {
        try await snapshot().windows.filter { $0.isOnScreen && $0.bundleIdentifier != nil }
    }

    /// SCWindow を解決する。windowID の完全一致を最優先し、無ければタイトル / bundleID の
    /// 部分一致 (複数ヒット時は面積が最大のもの)。
    /// Recorder のセッション (async) からのみ使うので async 版だけを持つ
    static func resolveWindow(matching match: String) async throws -> SCWindow {
        let content = try await shareableContent("ウィンドウの一覧を取得できません")
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
    static func display(at index: Int) async throws -> SCDisplay {
        let content = try await shareableContent("ディスプレイの一覧を取得できません")
        guard content.displays.indices.contains(index) else {
            throw KilError.deviceNotFound("ディスプレイ \(index) は範囲外です (0...\(content.displays.count - 1))")
        }
        return content.displays[index]
    }

    /// ウィンドウのサムネイル (GUI のウィンドウ選択用 — issue #18)。列挙は 1 回にまとめ、
    /// 撮れなかったウィンドウ (最小化・権限不足・撮影中に閉じた等) は結果に含めない。
    /// サムネイルは補助表示なので、失敗しても例外にせず空の結果で返す
    public static func windowThumbnails(windowIDs: [UInt32], maxDimension: Int = 160) async -> [UInt32: CGImage] {
        guard !windowIDs.isEmpty, let content = try? await SCShareableContent.current else { return [:] }
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

    /// SCShareableContent の取得失敗は画面収録権限の不足として扱う (終了コード 2)
    private static func shareableContent(_ what: String) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.current
        } catch {
            throw KilError.permission("\(what): \(error.localizedDescription)")
        }
    }
}
