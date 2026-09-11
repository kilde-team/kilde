import SwiftUI
import KildeCore

/// 最小の診断パネル (issue #17): KildeCore のデバイス列挙 API が
/// GUI プロセスから呼べることを確認する。録画 UI 自体は issue #18 以降
struct ContentView: View {
    @State private var displays: [DisplayInfo] = []
    @State private var windows: [WindowInfo] = []
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var loadError: String?

    var body: some View {
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
        .frame(width: 360)
        .onAppear(perform: reload)
    }

    /// 列挙は同期的に待つものではないほど軽いが、MenuBarExtra の UI スレッドを
    /// 長時間ブロックしないよう、画面表示後に一度だけ呼ぶ
    private func reload() {
        do {
            let snapshot = try DisplayCatalog.snapshot()
            displays = snapshot.displays
            windows = snapshot.windows.filter(\.isOnScreen)
            loadError = nil
        } catch {
            // 画面収録の権限が無いとここに来る (kilde doctor 相当の案内)
            displays = []
            windows = []
            loadError = "画面/ウィンドウの列挙に失敗: \(error)"
        }
        audioDevices = AudioDeviceCatalog.devices
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

import AppKit
