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
    /// reload 自体は @MainActor なのでこの読み書きに競合は無い
    @State private var reloading = false

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

                if let loadError {
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
        // MenuBarExtra の .window スタイルは View を一度生成すると保持するため
        // onAppear は初回のみ。閉じている間のデバイス増減 (モニタ接続等) を
        // 反映するため、パネルが key になるたびに引き直す
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    /// SCShareableContent の初回列挙は数百 ms かかる (権限プロンプト保留中は
    /// さらに長く) なるため、メニューバーのパネルを開くたびにメインスレッドを
    /// 塞がないよう detached タスクで列挙し、結果だけ @State に書き戻す。
    /// View のメソッドは @MainActor 隔離なので Task {} では隔離を継承して
    /// ブロッキング呼び出しがメインに留まる — detached が必須。
    /// (issue #35 で snapshot() の async 版が入ったら .task {} + await に移行する)
    private func reload() {
        guard !reloading else { return }
        reloading = true
        Task.detached {
            let result: Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error>
            do {
                result = .success(try DisplayCatalog.snapshot())
            } catch {
                result = .failure(error)
            }
            let devices = AudioDeviceCatalog.devices
            await MainActor.run {
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
                audioDevices = devices
                reloading = false
            }
        }
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
