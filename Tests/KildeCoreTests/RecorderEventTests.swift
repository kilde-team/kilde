import XCTest
@testable import KildeCore

/// Recorder のイベント駆動 API (issue #8) の検証。
/// 権限もキャプチャデバイスも不要な「空セッション」(映像なし・音声なし) で
/// 状態遷移の順序そのものを検証する。順序は DESIGN.md §4 の状態機械の定義。
final class RecorderEventTests: XCTestCase {

    private func emptySessionOptions(url: URL, duration: TimeInterval? = nil) -> RecordOptions {
        var o = RecordOptions()
        o.wantsVideo = false
        o.audioSources = []  // SCK もマイクも使わない = 権限・デバイス不要
        o.outputURL = url
        o.duration = duration
        return o
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-recorder-test-\(UUID().uuidString).m4a")
    }

    /// イベントを収集し、ストリーム終端 (runSession の finish) まで待つ。
    /// afterStart は start() の直後に呼ぶ追加の操作 (二重 start() の検証など)
    private func collectEvents(
        _ recorder: Recorder,
        afterStart: (() -> Void)? = nil
    ) async -> [RecorderEvent] {
        var events: [RecorderEvent] = []
        let collector = Task {
            for await e in recorder.events { events.append(e) }
        }
        recorder.start()
        afterStart?()
        await collector.value
        return events
    }

    /// 成功フロー: preparing → armed → recording → finalizing → done の順に遷移し、
    /// completed が末尾に来る。stop() は冪等なので二度呼んでも遷移は増えない
    func testStateOrderForSuccessfulSession() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url))
        XCTAssertEqual(recorder.currentState, .idle)

        var events: [RecorderEvent] = []
        let collector = Task {
            for await e in recorder.events { events.append(e) }
        }
        recorder.start()
        recorder.stop()
        recorder.stop()
        await collector.value

        XCTAssertEqual(events.compactMap(\.state), [.preparing, .armed, .recording, .finalizing, .done])
        guard case .completed(let summary) = events.last else {
            return XCTFail("末尾が completed ではありません: \(events)")
        }
        XCTAssertEqual(summary.outputURL, url)
        XCTAssertEqual(summary.videoAppended, 0)
        XCTAssertEqual(summary.audioAppended, [:])
        XCTAssertEqual(recorder.currentState, .done)
    }

    /// 失敗フロー: 不明デバイスの解決は preparing 中に失敗する。
    /// error へ遷移し、failed イベントが末尾に来る。writer 生成前なので部分ファイル無し
    func testStateOrderForFailedSession() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var options = emptySessionOptions(url: url)
        options.audioSources = [.device("kilde-no-such-input-device")]

        let recorder = Recorder(options: options)
        let events = await collectEvents(recorder)

        XCTAssertEqual(events.compactMap(\.state), [.preparing, .error])
        guard case .failed(let error, let partialFileExists) = events.last else {
            return XCTFail("末尾が failed ではありません: \(events)")
        }
        XCTAssertEqual(error.exitCode, 3)  // deviceNotFound (DESIGN.md §6)
        XCTAssertFalse(partialFileExists)
        XCTAssertEqual(recorder.currentState, .error)
    }

    /// 同期 run() ラッパは duration で自動停止して Summary を返す (CLI 互換)
    func testRunWrapperBlocksUntilDuration() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 0.2))

        let summary = try recorder.run()
        XCTAssertEqual(summary.outputURL, url)
        XCTAssertEqual(recorder.currentState, .done)
        XCTAssertTrue(recorder.cleanupWarnings.isEmpty)
    }

    /// start() 直呼びでは recording 中 0.5 秒周期の progress イベントが流れる (GUI 向け)
    func testProgressEventsEmittedWhileRecording() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 1.2))

        let events = await collectEvents(recorder)
        let progressCount = events.reduce(0) { count, e in
            if case .progress = e { return count + 1 }
            return count
        }
        XCTAssertGreaterThanOrEqual(progressCount, 1, "progress イベントが来ませんでした: \(events)")
    }

    /// start() の二重呼び出しは無視され、セッションは一度だけ走る
    func testStartIsIdempotent() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 0.2))

        let events = await collectEvents(recorder, afterStart: {
            // 最初の start() の直後にもう一度呼ぶ
            recorder.start()
        })
        // 二重起動していても遷移列が二重になることはない
        XCTAssertEqual(events.compactMap(\.state), [.preparing, .armed, .recording, .finalizing, .done])
    }
}
