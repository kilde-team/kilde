import SwiftUI
import AppKit
import KildeCore

/// 最小の診断パネル (issue #17): KildeCore のデバイス列挙 API が
/// GUI プロセスから呼べることを確認する。録画 UI 自体は issue #18 以降
struct ContentView: View {
    @State private var displays: [DisplayInfo] = []
    @State private var windows: [WindowInfo] = []
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var loadError: String?
    /// 列挙の多重発火を防ぐ (onAppear と didBecomeKey が同一開で両方来るため)。
    /// @MainActor を明示する — View の隔離を継承するのは body だけで、
    /// 通常のメソッドは nonisolated のため明示なしでは呼び出し側の引き込み次第になる。
    /// 実行中に来た再読込要求はドロップせず記録して、完了時に再実行する
    @State private var reloading = false
    @State private var needsReload = false
    /// 初回ロードが完了したか。完了前は onAppear と didBecomeKey が同時に来るが、
    /// in-flight の初回ロードと同じ結果になるため 2 回目を走らせない
    @State private var hasLoadedOnce = false
    /// didBecomeKey をこのパネル自身に限定するための window 参照
    @State private var panelWindow: NSWindow?

    var body: some View {
        // 画面上のウィンドウは通常 15〜25 件あり固定高さに収まらないため、
        // このパネルの目的 (診断情報の提示) のためにスクロールを許す
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("kilde")
                        .font(.headline)
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("デバイス一覧を更新")
                }

                // 読み込み中をエラーより優先する — 一度失敗した後の再試行でも、
                // 古いエラーではなく進行中であることを示す
                if reloading {
                    // SCShareableContent の初回列挙は数百 ms かかる。ハングした場合も
                    // 「デバイス無し」と混同されないよう、読み込み中であることを示す
                    // (列挙自体のタイムアウトは issue #35 の async 化で扱う)
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("読み込み中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .padding(.bottom, 4)
                }

                section("ディスプレイ") {
                    ForEach(displays, id: \.displayID) { d in
                        Text(d.description)
                    }
                }
                section("ウィンドウ (画面上)") {
                    ForEach(windows, id: \.windowID) { w in
                        Text(w.description)
                    }
                }
                section("オーディオ機器") {
                    ForEach(audioDevices, id: \.id) { a in
                        HStack {
                            Text(a.name)
                            Spacer()
                            Text(a.kind)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .frame(width: 360)
        .frame(maxHeight: 480)
        .onAppear(perform: reload)
        .background(WindowReader { window in
            // 同一 window でも非 Equatable 参照の書き込みは再レンダリングを起こし、
            // updateNSView → 書き込み の永久ループになり得るため変化時のみ書く
            if panelWindow !== window {
                panelWindow = window
            }
        })
        // MenuBarExtra の .window スタイルは View を一度生成すると保持するため
        // onAppear は初回のみ。閉じている間のデバイス増減 (モニタ接続等) を
        // 反映するため、このパネル自身が key になるたびに引き直す —
        // object を絞らないと将来のシート等でも再列挙が走る
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow) === panelWindow else { return }
            reload()
        }
    }

    /// SCShareableContent の初回列挙は数百 ms かかる (権限プロンプト保留中は
    /// 返らないことすらある)。列挙は detached タスクで走らせ、UI 側では
    /// `enumerationTimeout` 秒のタイムアウトを設けて loading を解除する —
    /// これが無いと権限保留中に再オープンも手動更新もすべて黙殺され、
    /// 権限不要なオーディオ一覧まで表示されない。列挙のタイムアウト自体は
    /// #35 (awaitSync の async 化) で根本対応する。
    /// (issue #35 で snapshot() の async 版が入ったら .task {} + await に移行する)
    @MainActor private func reload() {
        guard !reloading else {
            // 初回ロードの完了前に来た要求 (onAppear + didBecomeKey の同時発火) は
            // 同じ結果を返すので捨てる。以降の要求は最新化のために記録して再実行する
            if hasLoadedOnce {
                needsReload = true
            }
            return
        }
        reloading = true
        // 権限不要で速いオーディオ列挙は画面収録権限の待ちに巻き込まれないよう独立に反映
        Task.detached {
            let devices = AudioDeviceCatalog.devices
            await MainActor.run { audioDevices = devices }
        }
        let enumerate = Task.detached { () -> EnumerationResult in
            do { return .success(try DisplayCatalog.snapshot()) }
            catch { return .failure(error) }
        }
        Task {
            let finished = await Self.firstFinishedOrTimedOut(enumerate, timeout: Self.enumerationTimeout)
            await MainActor.run {
                defer {
                    reloading = false
                    hasLoadedOnce = true
                    if needsReload {
                        // 実行中に来た再読込要求 (パネル再オープン等) をここで回収する
                        needsReload = false
                        reload()
                    }
                }
                guard let result = finished else {
                    displays = []
                    windows = []
                    loadError = "画面/ウィンドウの列挙がタイムアウトしました。画面収録の権限確認が保留になっていないか確認し、再度更新してください"
                    return
                }
                switch result {
                case .success(let snapshot):
                    displays = snapshot.displays
                    windows = snapshot.windows.filter(\.isOnScreen)
                    loadError = nil
                case .failure(let error):
                    // 画面収録の権限が無いとここに来る (kilde doctor 相当の案内)
                    displays = []
                    windows = []
                    loadError = "画面/ウィンドウの列挙に失敗: \(error)"
                }
            }
        }
    }

    private typealias EnumerationResult =
        Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error>
    private static let enumerationTimeout: TimeInterval = 10

    /// 列挙の完了とタイムアウトの先着を返す。タイムアウト時は nil。
    /// withTaskGroup はスコープ退出時に全子タスクの完了を待つため、cancel できない
    /// 同期列挙の await を子に置くとタイムアウト後も戻らない (cancelAll は独立
    /// Task を止めない)。よってここはポーリングで先着を拾い、タイムアウト後も
    /// 残留する列挙タスクの結果は破棄する
    private static func firstFinishedOrTimedOut(
        _ enumerate: Task<EnumerationResult, Never>,
        timeout: TimeInterval
    ) async -> EnumerationResult? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var result: EnumerationResult?
            var done = false

            func store(_ r: EnumerationResult) {
                lock.lock()
                if !done {
                    result = r
                    done = true
                }
                lock.unlock()
            }

            func load() -> (done: Bool, result: EnumerationResult?) {
                lock.lock(); defer { lock.unlock() }
                return (done, result)
            }
        }
        let box = Box()
        let watcher = Task { box.store(await enumerate.value) }
        defer { watcher.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (done, result) = box.load()
            if done { return result }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let (done, result) = box.load()
        return done ? result : nil
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

/// この View が属する NSWindow を SwiftUI から取り出す定番の橋渡し。
/// didBecomeKey をパネル自身に限定するために使う
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 更新パス中の @State 書き込みは未定義動作 + デバッグ警告になるため
        // makeNSView と同じく次の実行ループへずらす
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
