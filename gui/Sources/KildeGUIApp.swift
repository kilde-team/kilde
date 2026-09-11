import SwiftUI

/// kilde のメニューバーアプリ (DESIGN.md §9)。
/// LSUIElement = true のため Dock には出ず、メニューバーのみ。
///
/// SwiftUI の MenuBarExtra は使わない — macOS 26 実機で .window スタイルの
/// パネルがクリックしても開かないことを切り分け済み (アイコンのハイライトは
/// 返るがパネルが出ない。.menu スタイルは開くが自由レイアウト不可)。
/// ため AppKit の NSStatusItem + NSPopover を AppDelegate で手動管理する
/// (主要メニューバーアプリで実績のある構成。切り分け記録は PR #43)。
@main
struct KildeGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // MenuBarExtra を廃止したためシーンは空。Settings は将来の設定画面 (#14 連携) で使う
        Settings {
            EmptyView()
        }
    }
}
