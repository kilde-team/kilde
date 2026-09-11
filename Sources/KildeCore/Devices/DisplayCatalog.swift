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

    /// 部分一致で SCWindow を解決する (複数ヒット時は面積が最大のもの)。
    /// Recorder のセッション (async) からのみ使うので async 版だけを持つ
    static func resolveWindow(matching match: String) async throws -> SCWindow {
        let content = try await shareableContent("ウィンドウの一覧を取得できません")
        let candidates = content.windows.filter { $0.isOnScreen && $0.owningApplication != nil }
        let matched = candidates.filter {
            // windowID の完全一致 (kilde devices に表示される [ID] を直接指定できる)
            String($0.windowID) == match
                || ($0.title ?? "").localizedCaseInsensitiveContains(match)
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

    /// SCShareableContent の取得失敗は画面収録権限の不足として扱う (終了コード 2)
    private static func shareableContent(_ what: String) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.current
        } catch {
            throw KilError.permission("\(what): \(error.localizedDescription)")
        }
    }
}
