import AppKit
import SwiftUI

/// メニューバーのステータス項目とポップオーバーの管理。
/// MenuBarExtra (.window) が macOS 26 で開かないため AppKit で手動管理する
/// (経緯は KildeGUIApp.swift のコメント参照)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "record.circle", accessibilityDescription: "kilde")
        // template 化でライト/ダークモードの自動反転に任せる
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "kilde"

        let p = NSPopover()
        p.contentSize = NSSize(width: 376, height: 480)
        // パネル外のクリックで閉じる (メニューバーアプリの標準挙動)
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: ContentView())

        statusItem = item
        popover = p
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
    }

    @objc private func togglePopover() {
        guard let item = statusItem, let button = item.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // NSPopover の内容は key window にならないため、ContentView の
            // didBecomeKey による再読込は発火しない。開くたびに明示的に更新する
            NotificationCenter.default.post(
                name: .kildePopoverDidShow, object: popover.contentViewController)
        }
    }
}

extension Notification.Name {
    /// ポップオーバーを開いた直後に発火 (ContentView の再読込トリガ)
    static let kildePopoverDidShow = Notification.Name("kildePopoverDidShow")
}
