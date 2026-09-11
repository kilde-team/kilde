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

    /// 失敗フロー: 出力先ディレクトリが存在しても書き込めない (権限不足) 場合は
    /// preparing 中に失敗する。startWriting の status を確認しないと「録画成功扱いの
    /// ままセッションが停止待ちで迷子になる」ため、writer 生成時点で弾く
    func testUnwritableOutputDirectoryFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 所有者にも書かせない。後続テストに響かないよう必ず戻す
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("out.m4a")

        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 5))
        let events = await collectEvents(recorder)

        XCTAssertEqual(events.compactMap(\.state), [.preparing, .error])
        guard case .failed(let error, let partialFileExists) = events.last else {
            return XCTFail("末尾が failed ではありません: \(events)")
        }
        XCTAssertEqual(error.exitCode, 1)
        XCTAssertFalse(partialFileExists)
    }

    /// 失敗フロー: 出力先ディレクトリが存在しない場合は preparing 中に失敗する。
    /// error へ遷移し、failed イベントが末尾に来る。権限チェックを通らない経路なので
    /// マイク TCC 権限のない環境 (CI 等) でもこの順序で検証できる。
    /// duration は、検証想定が外れてセッションが終わらないままになるのを防ぐ安全装置
    func testStateOrderForFailedSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-no-such-dir-\(UUID())/out.m4a")
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 5))
        let events = await collectEvents(recorder)

        XCTAssertEqual(events.compactMap(\.state), [.preparing, .error])
        guard case .failed(let error, let partialFileExists) = events.last else {
            return XCTFail("末尾が failed ではありません: \(events)")
        }
        XCTAssertEqual(error.exitCode, 1)  // failed (DESIGN.md §6)
        XCTAssertFalse(partialFileExists)
        XCTAssertEqual(recorder.currentState, .error)
    }

    /// 同期 run() ラッパは duration で自動停止して Summary を返す (CLI 互換)。
    /// 完了後の再呼び出しは同じ結果を返し、二度目の待機で固まらない
    func testRunWrapperBlocksUntilDuration() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 0.2))

        let summary = try recorder.run()
        XCTAssertEqual(summary.outputURL, url)
        XCTAssertEqual(recorder.currentState, .done)
        XCTAssertTrue(recorder.cleanupWarnings.isEmpty)

        let second = try recorder.run()
        XCTAssertEqual(second.outputURL, summary.outputURL)
    }

    /// 巨大な duration でもクラッシュしない (nanoseconds 変換は 1 年で飽和)。
    /// trap はキャプチャ開始後に起きると未ファイナライズのファイルを残すため回帰させない
    func testHugeDurationDoesNotTrap() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var options = emptySessionOptions(url: url)
        options.duration = 999_999_999_999  // ~31,700 年 — parseDuration も通す値

        let recorder = Recorder(options: options)
        var events: [RecorderEvent] = []
        let collector = Task {
            for await e in recorder.events { events.append(e) }
        }
        recorder.start()
        // duration の sleep に入ったことを保証してから停止で割り込む
        try await Task.sleep(nanoseconds: 300_000_000)
        recorder.stop()
        await collector.value

        XCTAssertEqual(events.compactMap(\.state).last, .done)
    }

    /// start() 直呼びでは recording 中 0.5 秒周期の progress イベントが流れる (GUI 向け)。
    /// duration は 3 秒 — 初回 tick (0.5s) までの余裕が薄いと負荷時の CI で flaky になる
    func testProgressEventsEmittedWhileRecording() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 3.0))

        let events = await collectEvents(recorder)
        let progressCount = events.reduce(0) { count, e in
            if case .progress = e { return count + 1 }
            return count
        }
        XCTAssertGreaterThanOrEqual(progressCount, 1, "progress イベントが来ませんでした: \(events)")
        // 進捗は recording 中のみ。finalizing 以降に混入していないこと
        if let lastProgress = events.lastIndex(where: { if case .progress = $0 { return true }; return false }),
           let finalizing = events.firstIndex(where: { $0.state == .finalizing }) {
            XCTAssertLessThan(lastProgress, finalizing, "finalizing 以降に progress が来ています")
        }
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
