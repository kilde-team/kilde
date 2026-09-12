import Foundation
import KildeCore

/// 録画セッションの GUI 側の持ち主 (issue #18)。
///
/// AppDelegate が 1 つだけ持ち、ポップオーバー (ContentView) は状態を表示して操作を渡すだけ。
/// Recorder への参照とイベント購読をビューから切り離しているので、ポップオーバーを閉じても
/// 録画は続く (issue #18 の受け入れ条件)。録画そのものは CLI と同じ `Recorder` が行う
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// 権限確認・デバイス解決・ストリーム構築中
        case starting
        case recording
        /// 停止後のファイナライズ中
        case finalizing
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var outputBytes: Int64 = 0
    /// ソースのラベル (system / mic / dev:<名前>) ごとの直近のピーク (0...1)
    @Published private(set) var peaks: [String: Float] = [:]
    @Published private(set) var warnings: [String] = []
    @Published private(set) var outputURL: URL?

    private var recorder: Recorder?
    private var sessionEndHandlers: [() -> Void] = []

    var isActive: Bool {
        switch phase {
        case .starting, .recording, .finalizing: return true
        case .idle, .finished, .failed: return false
        }
    }

    func start(_ options: RecordOptions) {
        guard !isActive else {
            // 既に録画中で options を使わないとき、makeOptions が確保した予約だけが
            // 0 バイトのファイルとして残る — Recorder に渡らないため誰も消さない
            options.outputReservation?.removeIfStillReserved()
            return
        }
        let recorder = Recorder(options: options)
        self.recorder = recorder
        phase = .starting
        elapsed = 0
        outputBytes = 0
        peaks = [:]
        warnings = []
        outputURL = options.outputURL
        // Recorder.events は start() の前に購読する契約 (購読前のイベントは捨てられうる)。
        // この Task は MainActor を引き継ぐので、handle は常にメインスレッドで走る
        let events = recorder.events
        Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        recorder.start()
    }

    /// 停止を要求する (SIGINT / --duration と同じ経路。冪等)。完了は phase の変化で分かる
    func stop() {
        recorder?.stop()
    }

    /// 経過時間の表示 (mm:ss、1 時間以上は h:mm:ss)。メニューバーとポップオーバーで共用
    nonisolated static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 次のセッション終了 (成功・失敗) で 1 回だけ呼ぶ。アプリ終了時のファイナライズ待ちとセルフテストが使う
    func whenSessionEnds(_ handler: @escaping () -> Void) {
        sessionEndHandlers.append(handler)
    }

    private func handle(_ event: RecorderEvent) {
        switch event {
        case .stateChanged(let state):
            switch state {
            case .preparing, .armed: phase = .starting
            case .recording: phase = .recording
            case .finalizing: phase = .finalizing
            // 結果は .completed / .failed で確定させる (done / error の遷移は必ずその直前に来る)
            case .idle, .done, .error: break
            }
        case .progress(let progress):
            elapsed = progress.elapsed
            outputBytes = progress.outputBytes
            peaks = progress.peaks
        case .cleanupWarning(let warning):
            // monitor の既定出力の復元失敗など。録画は成立しているので結果と一緒に見せる
            warnings.append(warning)
        case .completed(let summary):
            phase = .finished(summary.outputURL)
            endSession()
        case .failed(let error, let partialFileExists):
            var message = "\(error)"
            if partialFileExists, let outputURL {
                message += "\n不完全なファイルが残っています: \(outputURL.path)"
            }
            phase = .failed(message)
            endSession()
        }
    }

    private func endSession() {
        recorder = nil
        peaks = [:]
        let handlers = sessionEndHandlers
        sessionEndHandlers = []
        handlers.forEach { $0() }
    }
}
