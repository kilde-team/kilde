import AppKit
import Combine
import SwiftUI
import KildeCore

/// メニューバーのステータス項目とポップオーバーの管理。
/// MenuBarExtra (.window) が macOS 26 で開かないため AppKit で手動管理する
/// (経緯は KildeGUIApp.swift のコメント参照)。
///
/// 録画の状態 (RecordingController) と選択 (RecordingSetup) はここが持つ。
/// ポップオーバーを閉じても録画を続けるため、録画の寿命をビューに結び付けない (issue #18)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let recording = RecordingController()
    private let setup = RecordingSetup()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 録画中は経過時間を横に出すので可変幅にする
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem(phase: .idle, elapsed: 0)

        let p = NSPopover()
        p.contentSize = NSSize(width: 404, height: 600)
        // パネル外のクリックで閉じる (メニューバーアプリの標準挙動)。閉じても録画は止まらない
        p.behavior = .transient
        p.contentViewController = NSHostingController(
            rootView: ContentView(setup: setup, recording: recording))
        popover = p
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        // 録画の状態と経過時間をアイコンに反映する。@Published は willSet で通知するので、
        // プロパティを読み直さず流れてきた値を使う
        recording.$phase.combineLatest(recording.$elapsed)
            .sink { [weak self] phase, elapsed in
                self?.updateStatusItem(phase: phase, elapsed: elapsed)
            }
            .store(in: &cancellables)

        // セルフテストは 1 回ランループを回してから始める — applicationDidFinishLaunching の
        // 中ではステータス項目のボタンがまだウィンドウに載っておらず、NSPopover を出せないため
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            SelfTest.runIfRequested(
                setup: self.setup, recording: self.recording,
                popover: SelfTest.PopoverControl(
                    show: { [weak self] in self?.showPopover() },
                    close: { [weak self] in self?.popover?.performClose(nil) },
                    isShown: { [weak self] in self?.popover?.isShown ?? false }))
        }
    }

    /// 録画中に終了 (メニューの終了・ログアウト等) されたら、停止してファイナライズを待ってから終わる。
    /// 「停止しても必ずファイナライズする」は CLI (SIGINT / SIGTERM / SIGHUP) と同じ最重要要件
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording.isActive else { return .terminateNow }
        recording.whenSessionEnds {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        recording.stop()
        return .terminateLater
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // NSPopover の内容は key window にならないため didBecomeKey では拾えない。
        // 開くたびに通知して一覧を更新させる (閉じている間のウィンドウ・デバイスの増減を拾う)
        NotificationCenter.default.post(
            name: .kildePopoverDidShow, object: popover.contentViewController)
    }

    private func updateStatusItem(phase: RecordingController.Phase, elapsed: TimeInterval) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let tint: NSColor?
        let title: String
        switch phase {
        case .recording:
            symbol = "record.circle.fill"
            tint = .systemRed
            title = RecordingController.formatElapsed(elapsed)
        case .starting:
            symbol = "record.circle"
            tint = .systemOrange
            title = "準備中"
        case .finalizing:
            symbol = "record.circle"
            tint = .systemOrange
            title = "保存中"
        case .idle, .finished, .failed:
            symbol = "record.circle"
            tint = nil
            title = ""
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "kilde")
        // template のまま contentTintColor で色を付ける (待機中はライト/ダークの自動反転に任せる)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " \(title)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                                 weight: .regular)])
        button.toolTip = title.isEmpty ? "kilde" : "kilde — \(title)"
    }
}

extension Notification.Name {
    /// ポップオーバーを開いた直後に発火 (ContentView の再読込トリガ)
    static let kildePopoverDidShow = Notification.Name("kildePopoverDidShow")
}
