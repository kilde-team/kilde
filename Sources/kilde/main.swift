import Foundation
import AppKit
import ArgumentParser

// GUI を持たない CLI プロセスからの SCK ウィンドウ収録を有効化するための初期化
// (SPIKE-NOTES F-D.3 — これがないと CGS_REQUIRE_INIT で落ちる)
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

KildeCommand.main()
