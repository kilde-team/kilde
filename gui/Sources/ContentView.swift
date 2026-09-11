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
    /// 列挙の多重発火を防ぐ。@MainActor を明示する — View の隔離を継承するのは
    /// body だけで、通常のメソッドは nonisolated のため明示なしでは呼び出し側の
    /// 引き込み次第になる。実行中に来た再読込要求はドロップせず記録して、完了時に再実行する
    @State private var reloading = false
    @State private var needsReload = false
    /// 列挙タスクの生存と UI の読み込み表示は別物 — タイムアウトで reloading は
    /// 解除して再試行を許すが、同期 awaitSync を wrap した列挙タスク自体は cancel
    /// できず残る。前の列挙と次の列挙が並走してタスクが蓄積するのを防ぐため、
    /// 実列挙の完了まで新規開始を 1 件に制限する (残った要求は完了後に再実行)
    @State private var enumerationInFlight = false
    /// 初回ロードが完了したか。完了前は onAppear と popover 表示通知が同時に来るが、
    /// in-flight の初回ロードと同じ結果になるため 2 回目を走らせない
    @State private var hasLoadedOnce = false

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
        // NSPopover の内容は key window にならないため didBecomeKey は使えない。
        // AppDelegate がポップオーバーを開いた直後に投げる通知で再読込する
        // (閉じている間のモニタ接続等のデバイス増減を拾う)
        .onReceive(NotificationCenter.default.publisher(for: .kildePopoverDidShow)) { _ in
            reload()
        }
    }

    /// SCShareableContent の初回列挙は数百 ms かかる (権限プロンプト保留中は
    /// 返らないことすらある)。列挙は async 版 snapshot() を detached タスクで
    /// 走らせ、UI 側では `enumerationTimeout` 秒のタイムアウトを設けて loading を
    /// 解除する — これが無いと権限保留中に再オープンも手動更新もすべて黙殺され、
    /// 権限不要なオーディオ一覧まで表示されない
    @MainActor private func reload() {
        guard !reloading, !enumerationInFlight else {
            // 初回ロードの完了前に来た要求は同じ結果になるので捨てる。以降の要求は
            // 最新化のために記録し、列挙の完了時に再実行する
            if hasLoadedOnce {
                needsReload = true
            }
            return
        }
        reloading = true
        enumerationInFlight = true
        // 権限不要で速いオーディオ列挙は画面収録権限の待ちに巻き込まれないよう独立に反映
        Task.detached {
            let devices = AudioDeviceCatalog.devices
            await MainActor.run { audioDevices = devices }
        }
        let enumerate = Task.detached { () -> EnumerationResult in
            do { return .success(try await DisplayCatalog.snapshot()) }
            catch { return .failure(error) }
        }
        Task {
            let finished = await Self.firstFinishedOrTimedOut(enumerate, timeout: Self.enumerationTimeout)
            await MainActor.run {
                defer {
                    reloading = false
                    hasLoadedOnce = true
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
            // タイムアウト済みでも cancel できない列挙の実際の完了を待ってから次を
            // 受け入れる — ここで並走を許すと権限プロンプト保留中の再試行で
            // 列挙タスクが蓄積する (await なのでメインアクターは塞がない)
            _ = await enumerate.value
            await MainActor.run {
                enumerationInFlight = false
                if needsReload {
                    needsReload = false
                    reload()
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
