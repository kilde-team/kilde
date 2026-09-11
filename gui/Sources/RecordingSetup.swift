import AppKit
import KildeCore

/// ポップオーバーの選択状態と、選択肢 (ディスプレイ・ウィンドウ・入力デバイス) の列挙 (issue #18)。
/// 選択 → 録画オプションの変換は KildeCore の `RecordRequest` に任せる (CLI と同じ解決規則)
@MainActor
final class RecordingSetup: ObservableObject {
    @Published var request: RecordRequest
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    /// 操作の結果 (保存しました / 開始できません 等) を一時的に出す
    @Published var notice: String?

    /// 設定ファイル (~/.kilde/config.json) の内容。CLI と共有する (issue #14)
    private(set) var config = KildeConfig()

    /// 列挙の多重実行を防ぐ。UI の読み込み表示 (loading) はタイムアウトで解除して再試行を
    /// 許すが、SCShareableContent の列挙自体は止められない (権限プロンプト保留中は返らない
    /// こともある)。実列挙の完了まで次を始めず、その間の要求は記録して完了後に 1 回だけ再実行する
    /// (PR #45 で ContentView に入れた対策をモデルへ移したもの)
    private var enumerationInFlight = false
    private var needsReload = false
    private var hasLoadedOnce = false

    private static let enumerationTimeout: TimeInterval = 10
    /// サムネイルを撮るウィンドウ数の上限 (1 枚ごとに SCScreenshotManager の撮影が走るため)
    private static let thumbnailLimit = 24
    private static let ownBundleID = Bundle.main.bundleIdentifier

    init() {
        let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        request = RecordRequest(outputDirectory: fallback)
        do {
            config = try ConfigStore.load()
        } catch {
            // 壊れた設定でも GUI 自体は開けるようにし、録画開始時に CLI と同じエラーを出す
            notice = "設定ファイルを読めません (既定値で表示します): \(error)"
        }
        request = RecordRequest.initial(config: config, fallbackDirectory: fallback)
    }

    // MARK: - 録画オプション

    /// 現在の選択から録画オプションを作る。設定ファイルは CLI で変更されている可能性があるので
    /// 開始のたびに読み直す (壊れていれば CLI と同じく開始しない)
    func makeOptions() throws -> RecordOptions {
        config = try ConfigStore.load()
        return try request.makeOptions(config: config)
    }

    /// 選択中の音声ソース・トラック方針・保存先を設定ファイルの既定値にする (CLI の既定も変わる)
    func saveAsDefaults() {
        do {
            let updated = try request.savingDefaults(into: try ConfigStore.load())
            try ConfigStore.save(updated)
            config = updated
            notice = "既定値として保存しました (\(ConfigStore.fileURL.path))"
        } catch {
            notice = "既定値を保存できません: \(error)"
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = request.outputDirectory
        panel.prompt = "選択"
        // LSUIElement のアプリはアクティブでないとパネルが他のウィンドウの後ろに出る
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            request.outputDirectory = url
        }
    }

    func isSelected(device: AudioDeviceInfo) -> Bool {
        // 設定ファイル由来の値は名前のことがあるので、UID と名前の両方で照合する
        request.inputDevices.contains(device.uid) || request.inputDevices.contains(device.name)
    }

    func setSelected(_ selected: Bool, device: AudioDeviceInfo) {
        request.inputDevices.removeAll { $0 == device.uid || $0 == device.name }
        if selected {
            // UID は完全一致で解決されるので、同名のデバイスがあっても取り違えない
            request.inputDevices.append(device.uid)
        }
    }

    // MARK: - 列挙

    func reload() {
        guard !enumerationInFlight else {
            // 初回ロード中の要求 (onAppear とポップオーバー表示通知の同時発火) は同じ結果になるので捨てる
            if hasLoadedOnce { needsReload = true }
            return
        }
        enumerationInFlight = true
        loading = true
        // 入力デバイスは CoreAudio で権限不要・即時。画面の列挙の待ちに巻き込まない
        inputDevices = AudioDeviceCatalog.devices.filter { $0.inputChannels > 0 }

        let enumerate = Task.detached { () -> Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error> in
            do { return .success(try await DisplayCatalog.snapshot()) }
            catch { return .failure(error) }
        }
        Task {
            let finished = await Self.value(of: enumerate, timeout: Self.enumerationTimeout)
            apply(finished)
            loading = false
            hasLoadedOnce = true
            // タイムアウト後も列挙の実際の完了を待ってから次を受け付ける (列挙の積み上がり防止)。
            // await なのでメインアクターは塞がない
            _ = await enumerate.value
            enumerationInFlight = false
            if needsReload {
                needsReload = false
                reload()
            }
        }
    }

    private func apply(_ result: Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error>?) {
        guard let result else {
            loadError = "画面/ウィンドウの列挙がタイムアウトしました。画面収録の権限確認が保留になっていないか確認し、再度更新してください"
            return
        }
        switch result {
        case .success(let snapshot):
            loadError = nil
            displays = snapshot.displays
            windows = snapshot.windows
                .filter { window in
                    // メニューバーの項目やツールチップのような小さいもの・自分自身は収録対象にしない
                    window.isOnScreen && window.bundleIdentifier != nil
                        && window.bundleIdentifier != Self.ownBundleID
                        && window.frame.width >= 120 && window.frame.height >= 80
                }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            // 選択中の対象が消えていたら (ウィンドウが閉じた、ディスプレイが外れた) ディスプレイ 0 に戻す
            switch request.target {
            case .window(let id) where !windows.contains(where: { $0.windowID == id }):
                request.target = .display(index: 0)
            case .display(let index) where !displays.indices.contains(index):
                request.target = .display(index: 0)
            default:
                break
            }
            loadThumbnails()
        case .failure(let error):
            // 画面収録の権限が無いとここに来る (オンボーディングは issue #19)
            displays = []
            windows = []
            loadError = "画面/ウィンドウの列挙に失敗しました (画面収録の権限を確認してください): \(error)"
        }
    }

    private func loadThumbnails() {
        let ids = windows.prefix(Self.thumbnailLimit).map(\.windowID)
        Task.detached {
            let images = await DisplayCatalog.windowThumbnails(windowIDs: ids)
            let converted = images.mapValues { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run { [weak self] in
                self?.thumbnails = converted
            }
        }
    }

    /// タスクの完了とタイムアウトの先着を返す (タイムアウトなら nil)。
    /// withTaskGroup はスコープを抜けるときに全子タスクの完了を待つので、止められない列挙の
    /// await を子に置くとタイムアウト後も戻らない。そのためポーリングで先着を拾う
    private static func value<T>(of task: Task<T, Never>, timeout: TimeInterval) async -> T? {
        let box = ResultBox<T>()
        let watcher = Task { box.store(await task.value) }
        defer { watcher.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = box.load() { return value }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return box.load()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?

        func store(_ newValue: T) {
            lock.lock(); defer { lock.unlock() }
            if value == nil { value = newValue }
        }

        func load() -> T? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
