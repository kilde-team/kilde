import Foundation

/// ホットキー待機から Recorder の開始・停止・完了までを管理する。
/// CLI と GUI が同じ状態遷移を使い、待機中の終了要求で Recorder を作らないため KildeCore に置く。
public final class HotkeyRecordingController {
    public enum Outcome {
        /// 録画開始前に Ctrl+C 等で待機を中止した。出力ファイルは作られていない。
        case cancelled
        /// 録画開始前の設定再解決に失敗した。
        case failed(Error)
        /// Recorder が完了した。Result の失敗には部分ファイルが残る場合がある。
        case completed(Recorder, Result<Recorder.Summary, Error>)
    }

    public typealias StartedHandler = (Recorder, RecordOptions, String) -> Void
    public typealias FinishedHandler = (Outcome) -> Void

    private enum State {
        case waiting
        case recording(Recorder)
        case finished
    }

    public let normalizedHotkey: String
    private let baseOptions: RecordOptions
    private let overrides: RecordOverrides
    private let config: KildeConfig
    private let environment: [String: String]
    private let onStarted: StartedHandler
    private let onFinished: FinishedHandler
    private var state: State = .waiting
    private var monitor: HotkeyMonitor!
    private var monitoringStarted = false

    public init(hotkey source: String, options: RecordOptions, overrides: RecordOverrides,
                config: KildeConfig, environment: [String: String],
                onStarted: @escaping StartedHandler,
                onFinished: @escaping FinishedHandler) throws {
        normalizedHotkey = try HotkeyParser.parse(source).normalized
        baseOptions = options
        self.overrides = overrides
        self.config = config
        self.environment = environment
        self.onStarted = onStarted
        self.onFinished = onFinished
        monitor = try HotkeyMonitor(source) { [weak self] in
            self?.handleHotkey()
        }
    }

    deinit {
        // 正常終了以外の経路 (GUI が待機中にコントローラを破棄する等) でもホットキー登録が
        // 残らないよう、未停止なら解除する。メインスレッドでの破棄は同期的に止める —
        // dispatch で遅らせると直後の再登録 (同じキーの使い回し) が登録競合になるため。
        // バックグラウンドからの破棄だけメインキューへ配送する
        if monitoringStarted, let monitor = self.monitor {
            if Thread.isMainThread {
                monitor.stop()
            } else {
                DispatchQueue.main.async { monitor.stop() }
            }
        }
    }

    /// Carbon 登録を開始する。メインスレッドから呼ぶこと。
    /// requestStop() が先に来て .finished になっていたら何もしない —
    /// ここで登録すると解除できずに残ってしまうため
    public func start() throws {
        precondition(Thread.isMainThread, "HotkeyRecordingController.start() はメインスレッドから呼んでください")
        guard !monitoringStarted else { return }
        guard case .waiting = state else { return }
        try monitor.start()
        monitoringStarted = true
    }

    /// 待機中ならファイルを作らず終了し、録画中なら Recorder.stop() で安全停止する。
    /// シグナル用 DispatchSource のキューから呼ばれた場合も、状態変更はメインキューへ集約する。
    public func requestStop() {
        if Thread.isMainThread {
            handleStopRequest()
        } else {
            DispatchQueue.main.async { [weak self] in self?.handleStopRequest() }
        }
    }

    private func handleHotkey() {
        precondition(Thread.isMainThread)
        switch state {
        case .waiting:
            startRecording()
        case .recording(let recorder):
            recorder.stop()
        case .finished:
            break
        }
    }

    private func startRecording() {
        var options = baseOptions
        // HDR 可否は待機開始前ではなく「いま」の表示状態で決める (issue #16)。
        // 待機は数時間に及びうるので、その間に HDR ディスプレイを繋いだ / 外した /
        // 切り替えたことが反映されないと、指定どおりに録れない。
        // ここは handleHotkey() 経由でメインスレッド上なので DisplayHDR を読める
        if options.hdr {
            options.hdrCapableDisplayIDs = MainActor.assumeIsolated { DisplayHDR.capableDisplayIDs() }
        }
        do {
            if overrides.outputPath == nil {
                // 待機が長時間でも既定ファイル名を実際の開始時刻に合わせる。
                try RecordSettings.apply(overrides, config: config, environment: environment, to: &options)
            }
        } catch {
            finishMonitoring()
            onFinished(.failed(error))
            return
        }

        let recorder = Recorder(options: options)
        state = .recording(recorder)
        onStarted(recorder, options, normalizedHotkey)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try recorder.run() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.finishMonitoring()
                self.onFinished(.completed(recorder, result))
            }
        }
    }

    private func handleStopRequest() {
        precondition(Thread.isMainThread)
        switch state {
        case .waiting:
            finishMonitoring()
            onFinished(.cancelled)
        case .recording(let recorder):
            recorder.stop()
        case .finished:
            break
        }
    }

    private func finishMonitoring() {
        monitor.stop()
        monitoringStarted = false
        state = .finished
    }
}
