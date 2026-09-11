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

/// SCShareableContent の列挙ラッパ (DESIGN.md §4 DeviceCatalog)
public enum DisplayCatalog {

    /// ディスプレイと (任意の) ウィンドウ一覧を取得する
    public static func snapshot() throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        let content: SCShareableContent
        do {
            content = try awaitSync { try await SCShareableContent.current }
        } catch {
            throw KilError.permission("画面の一覧を取得できません (画面収録権限を確認してください): \(error.localizedDescription)")
        }
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

    /// on-screen ウィンドウのうち title / bundleID が部分一致するものを返す
    public static func listOnScreenWindows() throws -> [WindowInfo] {
        try snapshot().windows.filter { $0.isOnScreen && $0.bundleIdentifier != nil }
    }

    /// 部分一致で SCWindow を解決する (複数ヒット時は面積が最大のもの)
    static func resolveWindow(matching match: String) throws -> SCWindow {
        let content: SCShareableContent
        do {
            content = try awaitSync { try await SCShareableContent.current }
        } catch {
            throw KilError.permission("ウィンドウの一覧を取得できません: \(error.localizedDescription)")
        }
        let candidates = content.windows.filter { $0.isOnScreen && $0.owningApplication != nil }
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

    static func display(at index: Int) throws -> SCDisplay {
        let content = try awaitSync { try await SCShareableContent.current }
        guard content.displays.indices.contains(index) else {
            throw KilError.deviceNotFound("ディスプレイ \(index) は範囲外です (0...\(content.displays.count - 1))")
        }
        return content.displays[index]
    }
}
