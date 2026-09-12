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

    /// 生存中のインスタンス。**`NSApp.delegate` からは取れない** —
    /// `@NSApplicationDelegateAdaptor` は SwiftUI が独自のプロキシを
    /// `NSApp.delegate` に据え、この型はその内側に保持されるため、
    /// `NSApp.delegate as? AppDelegate` は nil になる (実測)。
    /// ビュー側からホットキーの再登録を頼む経路がそれで無反応になっていた
    static private(set) weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let recording = RecordingController()
    private let setup = RecordingSetup()
    private let permissions = PermissionsModel()
    /// 録画完了通知 (issue #20)。UNUserNotificationCenter はデリゲートを弱参照するので、
    /// ここで生存期間を持つ
    private let notifier = RecordingNotifier()
    private var cancellables: Set<AnyCancellable> = []
    /// グローバルホットキー (issue #20)。CLI と同じ `HotkeyMonitor` / `HotkeySettings` を使い、
    /// 設定 (~/.kilde/config.json の `hotkey`) も CLI と共有する。
    /// nil は «設定されていない» (待機しない)
    private var hotkeyMonitor: HotkeyMonitor?

    /// 現在登録できているホットキー (nil は未登録)。検証から参照する。
    /// **self-test が自前で HotkeyMonitor を作ると、ここで登録済みのキーと
    /// 排他登録 (kEventHotKeyExclusive) で衝突して必ず失敗する** — 同一プロセス内でも
    /// 二重登録はできないため、登録できたかどうかはこの値で判断する
    var registeredHotkey: String? { hotkeyMonitor?.source }

    /// 検証用。self-test が見ている RecordingSetup が、この AppDelegate が
    /// ホットキーの解決に使ったものと同一インスタンスかを確かめる
    func debugUsesSameSetup(_ other: RecordingSetup) -> Bool { setup === other }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // 通知の許可要求はここで 1 回だけ。拒否されても録画は完全に動くので、
        // 失敗として扱わない (通知が出ないだけ)
        notifier.start()
        recording.notifier = notifier

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
            rootView: ContentView(setup: setup, recording: recording, permissions: permissions))
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

        applyHotkeyFromConfig()

        // セルフテストは 1 回ランループを回してから始める — applicationDidFinishLaunching の
        // 中ではステータス項目のボタンがまだウィンドウに載っておらず、NSPopover を出せないため
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            SelfTest.runIfRequested(
                setup: self.setup, recording: self.recording, permissions: self.permissions,
                popover: SelfTest.PopoverControl(
                    show: { [weak self] in self?.showPopover() },
                    // performClose は「閉じる要求」なので transient の popover では
                    // 遅延・無視されうる。検証では確実に閉じたいので close() を使う
                    close: { [weak self] in self?.popover?.close() },
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
        // 猶予を設けて終了を許す案は採らない: writer は Recorder の preparing の途中で作られ、
        // 状態イベントからは「作られた瞬間」が分からない。マイク初期化が長引くと、writer 生成後
        // なのに preparing のまま猶予が切れ、ファイナライズされないファイルを残しうる。
        // 準備中に stop() が効かず終了できない問題は Recorder 側で直す (issue #56)
        return .terminateLater
    }

    /// 設定のホットキーを登録し直す (issue #20)。設定画面からの変更でも呼ぶ。
    ///
    /// **新しい登録が成功するまで旧モニターを捨てない。** 先に解除してから登録すると、
    /// 登録に失敗したときに**旧ホットキーまで失われる** (設定だけ新しい値が残り、
    /// どのキーも効かない状態になる)。`revert` が渡されているときは、
    /// 失敗した設定を書き戻さないよう永続設定も旧値へ巻き戻す。
    ///
    /// 登録失敗 (他アプリとの競合) 自体は録画機能を止める理由にならないので、
    /// notice に出して続ける — 黙って無効にすると «押しても効かない» になる
    /// `revert` を渡すと、登録に失敗したときに設定をその値へ巻き戻す。
    /// **`Optional<String?>` にしているのは «巻き戻さない» と «nil (未設定) へ戻す» を
    /// 区別するため** — 未設定からホットキーを足して登録に失敗したとき、
    /// 区別できないと競合するキーが設定に残り、次回起動でも GUI と CLI が同じ失敗を繰り返す
    func applyHotkeyFromConfig(revert: String?? = nil) {
        let previous = revert ?? nil
        let source: String?
        do {
            source = try HotkeySettings.resolve(explicit: nil, config: setup.config)
        } catch {
            setup.notice = "ホットキーの設定を解釈できません: \(error)"
            if revert != nil { setup.restoreHotkey(previous) }
            return
        }

        // 新しい登録を先に作る。ここで失敗しても旧モニターは生きたまま
        var replacement: HotkeyMonitor?
        if let source {
            do {
                let monitor = try HotkeyMonitor(source) { [weak self] in
                    self?.toggleRecordingByHotkey()
                }
                // 旧モニターが同じキーを握っている間は排他登録が必ず失敗するので、
                // 同じキーへの再適用に限っては先に解除してから登録する
                if hotkeyMonitor?.source == source { releaseHotkeyMonitor() }
                try monitor.start()
                replacement = monitor
            } catch {
                setup.notice = "ホットキーを登録できません (旧設定のままにします): \(error)"
                if revert != nil { setup.restoreHotkey(previous) }
                // 同じキーの再適用で解除だけ済んでいた場合は、旧設定で登録し直す
                if hotkeyMonitor == nil, let previous,
                   let monitor = try? HotkeyMonitor(previous, handler: { [weak self] in
                       self?.toggleRecordingByHotkey()
                   }), (try? monitor.start()) != nil {
                    hotkeyMonitor = monitor
                }
                return
            }
        }
        // 新しい登録が成功した (または設定が空になった) のでここで旧モニターを手放す。
        // **解除に失敗したら置き換えない** — 上書きすると旧モニターへの参照が消え、
        // 新旧のホットキーが両方効いたまま、旧モニターを再解除する機会も失われる
        guard releaseHotkeyMonitor() else {
            replacement?.stop()
            return
        }
        hotkeyMonitor = replacement
    }

    /// 旧モニターを解除する。`stop()` が false を返したら解除しきれていない —
    /// HotkeyMonitor は «参照を保持したままリークさせ、再 stop() で再試行できる»
    /// 契約なので、失敗時は参照を捨てずに残す
    @discardableResult
    private func releaseHotkeyMonitor() -> Bool {
        guard let monitor = hotkeyMonitor else { return true }
        if monitor.stop() {
            hotkeyMonitor = nil
            return true
        }
        setup.notice = "前のホットキーを解除できませんでした (もう一度「適用」を押すと再試行します)"
        return false
    }

    /// ホットキーでの開始/停止。録画中なら止め、そうでなければ今の選択で始める。
    /// Carbon のハンドラはメインスレッドで呼ばれるので、そのまま MainActor の状態を触れる
    private func toggleRecordingByHotkey() {
        if recording.isActive {
            recording.stop()
            return
        }
        permissions.refresh()
        // 開始ボタンと同じ判定を通す — ここを «権限だけ» にしていたために、
        // 列挙中でもホットキーで録画を始められる経路ができていた (cubic P2)。
        // issue #70 で実測したとおり、列挙と録画開始の競合は両方を無期限に止める
        if let reason = setup.startBlockReason(permissions: permissions) {
            // ポップオーバーを開いていないと notice は見えないので、開いて理由を見せる。
            // 他アプリの前面で押されている前提なので «黙って何も起きない» を避ける
            setup.notice = reason
            showPopover()
            return
        }
        do {
            let options = try setup.makeOptions()
            setup.notice = nil
            recording.start(options)
        } catch {
            setup.notice = "開始できません: \(error)"
            showPopover()
        }
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
