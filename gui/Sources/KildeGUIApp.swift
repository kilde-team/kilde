import SwiftUI

/// kilde のメニューバーアプリ (DESIGN.md §9)。
/// LSUIElement = true のため Dock には出ず、メニューバーのみ
@main
struct KildeGUIApp: App {
    var body: some Scene {
        // window スタイルにして、ディスプレイ/オーディオ機器の一覧など
        // 今後のソース選択 UI を置ける領域を確保する (issue #18 への布石)
        MenuBarExtra("kilde", systemImage: "record.circle") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
