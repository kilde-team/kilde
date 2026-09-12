import SwiftUI
import AppKit
import KildeCore

/// ポップオーバーの中身 (issue #18): 収録対象・音声ソース・トラック方針・保存先の選択と、
/// Rec / Stop・経過時間・ソース別レベルメーター。
/// 状態は AppDelegate が持つモデル (RecordingSetup / RecordingController) にあり、このビューは
/// 表示と操作の受け渡しだけ — ポップオーバーを閉じても録画は続く
struct ContentView: View {
    @ObservedObject var setup: RecordingSetup
    @ObservedObject var recording: RecordingController

    private enum Mode: Hashable {
        case display, window, audioOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if recording.isActive {
                sessionView
            } else {
                ScrollView {
                    form.padding(.trailing, 6)
                }
                .frame(maxHeight: 420)
                resultView
                startButton
            }
            if let notice = setup.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("終了") {
                    // 録画中なら AppDelegate.applicationShouldTerminate がファイナライズを待つ
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        // 録画中は選択肢を出さないので列挙しない (止められない SCK の列挙を録画と並走させない)
        .onAppear { if !recording.isActive { setup.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .kildePopoverDidShow)) { _ in
            // 録画中は選択肢を出さないので列挙しない (SCK の列挙を録画と並走させない)
            if !recording.isActive { setup.reload() }
        }
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("kilde")
                .font(.headline)
            Spacer()
            if !recording.isActive {
                if setup.loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    setup.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("ディスプレイ・ウィンドウ・入力デバイスの一覧を更新")
            }
        }
    }

    // MARK: - 選択フォーム

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("収録対象") {
                Picker("収録対象", selection: modeBinding) {
                    Text("画面").tag(Mode.display)
                    Text("ウィンドウ").tag(Mode.window)
                    Text("音声のみ").tag(Mode.audioOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 読み込み中は前回のエラーを隠す (再試行中に古い権限エラーが今の結果に見えてしまう)
                if !setup.loading, let error = setup.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch mode {
                case .display:
                    displayList
                case .window:
                    windowList
                case .audioOnly:
                    Text("映像は録らず、音声だけを M4A に保存します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            section("音声") {
                audioToggles
            }
            section("複数の音声ソース") {
                Picker("複数の音声ソース", selection: $setup.request.trackPolicy) {
                    Text("1 トラックに合成").tag(AudioTrackPolicy.mixed)
                    Text("ソースごとに分離").tag(AudioTrackPolicy.separate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(setup.request.audioSourceCount < 2)
            }
            section("保存先") {
                outputRow
            }
        }
    }

    private var mode: Mode {
        switch setup.request.target {
        case .display: return .display
        case .window: return .window
        case .audioOnly: return .audioOnly
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .display:
                    setup.request.target = .display(index: 0)
                case .window:
                    // 面積が最大のウィンドウを仮選択する (一覧は面積の降順)
                    if let first = setup.windows.first {
                        setup.request.target = .window(id: first.windowID)
                    } else {
                        setup.notice = "収録できるウィンドウが見つかりません (更新ボタンで一覧を取り直せます)"
                    }
                case .audioOnly:
                    setup.request.target = .audioOnly
                }
            })
    }

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if setup.displays.isEmpty && !setup.loading {
                Text("ディスプレイが見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(setup.displays, id: \.displayID) { display in
                selectableRow(selected: setup.request.target == .display(index: display.index)) {
                    setup.request.target = .display(index: display.index)
                } content: {
                    Image(systemName: "display")
                    Text("ディスプレイ \(display.index)")
                    Spacer()
                    Text("\(display.width)×\(display.height)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if setup.windows.isEmpty && !setup.loading {
                Text("収録できるウィンドウが見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(setup.windows, id: \.windowID) { window in
                selectableRow(selected: setup.request.target == .window(id: window.windowID)) {
                    setup.request.target = .window(id: window.windowID)
                } content: {
                    thumbnail(for: window)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(windowTitle(window))
                            .lineLimit(1)
                        Text(window.bundleIdentifier ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func windowTitle(_ window: WindowInfo) -> String {
        if let title = window.title, !title.isEmpty { return title }
        return "(タイトルなし)"
    }

    private func thumbnail(for window: WindowInfo) -> some View {
        Group {
            if let image = setup.thumbnails[window.windowID] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "macwindow").foregroundStyle(.secondary))
            }
        }
        .frame(width: 64, height: 40)
    }

    private var audioToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("システム音声 (相手の声・アプリの音)", isOn: $setup.request.captureSystemAudio)
            Toggle("マイク (既定の入力デバイス)", isOn: $setup.request.captureMic)
            ForEach(setup.inputDevices, id: \.uid) { device in
                Toggle(isOn: Binding(
                    get: { setup.isSelected(device: device) },
                    set: { setup.setSelected($0, device: device) })) {
                    Text(device.name)
                }
            }
            if case .window = setup.request.target, setup.request.captureSystemAudio {
                // ウィンドウ単位の収録では SCK がそのアプリの音声だけを渡す (SPIKE-NOTES F-B)
                Text("ウィンドウ収録ではシステム音声もそのアプリの音だけになります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "folder")
                Text((setup.request.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(setup.request.outputDirectory.path)
                Spacer()
                Button("変更…") {
                    setup.chooseOutputDirectory()
                }
            }
            Button("この音声・保存先の選択を既定にする") {
                setup.saveAsDefaults()
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("~/.kilde/config.json に保存します (CLI の kilde rec の既定値も変わります)")
        }
    }

    // MARK: - 開始・結果

    private var startButton: some View {
        Button {
            start()
        } label: {
            Label(mode == .audioOnly ? "録音開始" : "録画開始", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        // 列挙中の開始は、進行中の SCShareableContent 列挙と Recorder の対象解決が
        // 同時に SCK へ行くことになるので受け付けない
        .disabled(setup.loading || (mode == .audioOnly && setup.request.audioSourceCount == 0))
    }

    private func start() {
        do {
            let options = try setup.makeOptions()
            setup.notice = nil
            recording.start(options)
        } catch {
            setup.notice = "開始できません: \(error)"
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch recording.phase {
        case .finished(let url):
            VStack(alignment: .leading, spacing: 2) {
                Label("保存しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                ForEach(recording.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    // MARK: - 録画中

    private var sessionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                switch recording.phase {
                case .recording:
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(RecordingController.formatElapsed(recording.elapsed))
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: recording.outputBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                case .finalizing:
                    ProgressView()
                        .controlSize(.small)
                    Text("ファイルを仕上げています…")
                default:
                    ProgressView()
                        .controlSize(.small)
                    Text("準備中…")
                }
            }
            if let url = recording.outputURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !recording.peaks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recording.peaks.keys.sorted(), id: \.self) { label in
                        LevelMeter(label: sourceName(label), peak: recording.peaks[label] ?? 0)
                    }
                }
            }
            Button {
                recording.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            // 準備中の停止も受け付ける (Recorder は録画開始直後に停止要求を処理する)
            .disabled(recording.phase == .finalizing)
            Text("ポップオーバーを閉じても録画は続きます。経過時間はメニューバーに表示されます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Recorder のソースラベル (system / mic / dev:<名前>) を表示名にする
    private func sourceName(_ label: String) -> String {
        switch label {
        case "system": return "システム音声"
        case "mic": return "マイク"
        default: return label.hasPrefix("dev:") ? String(label.dropFirst("dev:".count)) : label
        }
    }

    // MARK: - 部品

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func selectableRow<Content: View>(
        selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                content()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
