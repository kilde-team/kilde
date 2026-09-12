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
    /// completed が末尾に来る。
    /// 停止は duration に任せる — start() 直後の stop() は準備フェーズに割り込んで
    /// 録画に入らずキャンセルされる (issue #56) ので、成功フローの検証には使えない
    func testStateOrderForSuccessfulSession() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 0.2))
        XCTAssertEqual(recorder.currentState, .idle)

        var events: [RecorderEvent] = []
        let collector = Task {
            for await e in recorder.events { events.append(e) }
        }
        recorder.start()
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
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        // 所有者にも書かせない。適用できなければ (root 実行等) このテストの前提が
        // 立たないので skip する — 権限を素通りして startWriting が成功するため
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        } catch {
            throw XCTSkip("ディレクトリを読み取り専用にできません: \(error)")
        }
        guard !FileManager.default.isWritableFile(atPath: dir.path) else {
            throw XCTSkip("権限設定が効いていません (root 実行の可能性)")
        }
        let url = dir.appendingPathComponent("out.m4a")

        // 明示パスとして解決させる — 既定名だと予約 (O_CREAT) の失敗が先に起こり、
        // このテストが見たい writer 生成の失敗 (startWriting ガード) まで届かない
        var options = emptySessionOptions(url: url, duration: 5)
        options.outputPathIsExplicit = true
        let recorder = Recorder(options: options)
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

    /// 準備中の停止 (issue #56): start() より前に stop() を呼ぶと、停止要求が立った状態で
    /// セッションが走り出す。最初の中断点で畳まれ、**録画には入らず**終端イベントが流れる。
    /// 空セッションは準備が一瞬で終わるので、「準備中に割り込む」のではなく
    /// 「最初から停止済み」にすることで、タイミングに依存せず決定的に検証する
    func testStopBeforeStartCancelsDuringPreparation() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 5))

        // stop() は冪等 — 二度呼んでも遷移は増えない
        recorder.stop()
        recorder.stop()
        let events = await collectEvents(recorder)

        // recording には入らない (preparing から直接畳まれる)
        let states = events.compactMap(\.state)
        XCTAssertEqual(states, [.preparing, .error], "録画に入ってしまいました: \(states)")
        XCTAssertFalse(states.contains(.recording))
        XCTAssertTrue(recorder.cancelledBeforeRecording)

        // 終端イベントは必ず流れる — 購読側 (GUI の applicationShouldTerminate) が
        // 待ち続けないことがこの issue の主眼
        guard case .failed(let error, let partialFileExists) = events.last else {
            return XCTFail("末尾が failed ではありません: \(events)")
        }
        XCTAssertEqual("\(error)", Recorder.cancelledDuringPreparationMessage)
        XCTAssertFalse(partialFileExists)
        // 録画が成立していないので出力ファイルを残さない
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// `awaitOrStop` そのものの回帰テスト (issue #56)。
    ///
    /// 当初 `withTaskGroup` で書いていたため 2 つの欠陥があった:
    /// (a) タスクグループはスコープ終了時に未完了の子を暗黙 await するので、停止しても
    ///     本体 (TCC ダイアログ) の完了まで戻らない
    /// (b) 監視側の `try? await Task.sleep` がキャンセル例外を握り潰すので、本体が先に
    ///     終わるとループが回り続けて戻らない
    ///
    /// (b) は**停止要求が無い通常経路**で起きる。セッション経由のテストでは権限状態に
    /// 左右されてこの経路を確実に通せないので、ヘルパを直接叩く
    func testAwaitOrStopReturnsValueWhenBodyFinishesFirst() async throws {
        let recorder = Recorder(options: emptySessionOptions(url: tempURL()))
        let value = await recorder.awaitOrStop { 42 }
        XCTAssertEqual(value, 42, "本体が先に完了したのに戻ってきませんでした (欠陥 b の回帰)")
    }

    /// 停止が先なら nil を返し、**本体の完了を待たない**。
    /// 待ってしまうと「準備中の停止」がユーザーのダイアログ応答まで効かず、この issue の
    /// 目的そのものが失われる (欠陥 a の回帰)
    func testAwaitOrStopReturnsNilWithoutWaitingForBody() async throws {
        let recorder = Recorder(options: emptySessionOptions(url: tempURL()))
        recorder.stop()

        let started = Date()
        let value: Int? = await recorder.awaitOrStop {
            // 外から止められない処理の代役 (TCC ダイアログに相当)。
            // **`Task.sleep` では代役にならない** — あれはキャンセルに応じるので、
            // structured なタスクグループのままでも暗黙 await がすぐ解けてしまい、
            // この回帰テストが素通りする。キャンセルを一切見ない待ちにする必要がある
            await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    continuation.resume(returning: 1)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(value)
        XCTAssertLessThan(elapsed, 3.0, "本体 (5 秒) の完了を待ってしまっています: \(elapsed)s")
    }

    /// マイクを要求する構成でもセッションが**終端する**こと (issue #56)。
    ///
    /// **このテストは `awaitOrStop` の中までは到達しない。** `stop()` を `start()` より前に
    /// 呼ぶため、`performSession()` の最初の中断点 (マイク権限ブロックより前) で畳まれる。
    /// `awaitOrStop` 自体の回帰は上の 2 つのテストがヘルパを直接叩いて担保しており、
    /// ここで見るのは「マイクを要求する構成でもセッションが終端する」という一段外側の性質。
    ///
    /// 権限の許可状態には依存しない — 許可でも拒否でも「終端イベントが流れる」ことだけを見る。
    /// 固まると XCTest のタイムアウトではなくここで待ち続けるので、明示的に時間を区切る
    func testMicSessionTerminatesEvenWhenStoppedDuringPreparation() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var options = emptySessionOptions(url: url, duration: 5)
        options.audioSources = [.mic]  // needsMicPermission = true → awaitOrStop を通る

        let recorder = Recorder(options: options)
        recorder.stop()

        let finished = Task { () -> [RecorderEvent] in
            var events: [RecorderEvent] = []
            for await e in recorder.events { events.append(e) }
            return events
        }
        recorder.start()

        // 10 秒で終端しなければ「固まった」とみなす (TCC ダイアログの応答待ちを含めても十分)。
        // **タイムアウトしたことを戻り値で受け取って明示的に失敗させる** — collector を
        // キャンセルするだけだと、終端しない回帰が起きてもテストが緑のまま通る
        let guardTask = Task { [finished] () -> Bool in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return false  // 正常終了してキャンセルされた
            }
            finished.cancel()
            return true
        }
        let events = await finished.value
        guardTask.cancel()
        let timedOut = await guardTask.value
        XCTAssertFalse(timedOut, "10 秒たっても終端しませんでした (セッションが固まっています)")

        XCTAssertFalse(events.isEmpty, "終端イベントが流れませんでした (セッションが固まった疑い)")
        // 録画には入らない。権限が拒否されていれば .permission、停止が先なら準備中キャンセル
        XCTAssertFalse(events.compactMap(\.state).contains(.recording),
                       "停止を要求したのに録画に入りました: \(events.compactMap(\.state))")
        guard case .failed = events.last else {
            return XCTFail("末尾が failed ではありません: \(events)")
        }
    }

    /// 同期 run() でも準備中の停止は例外として返る (CLI はこれを exit 0 に読み替える)。
    /// run() が固まらないこと自体が回帰対象 — 完了通知に到達しないと呼び出し元が待ち続ける
    func testRunWrapperReturnsWhenCancelledDuringPreparation() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: emptySessionOptions(url: url, duration: 5))

        recorder.stop()
        XCTAssertThrowsError(try recorder.run()) { error in
            guard case KilError.failed(let message) = error else {
                return XCTFail("KilError.failed ではありません: \(error)")
            }
            XCTAssertEqual(message, Recorder.cancelledDuringPreparationMessage)
        }
        XCTAssertTrue(recorder.cancelledBeforeRecording)
        XCTAssertEqual(recorder.currentState, .error)
    }

    /// 実ストリームを必要としない純粋判定で、映像ありの 0 フレームだけを失敗にする。
    /// 音声のみは映像アンカーを使わないため、同じ 0 件でも成功対象のままにする
    func testVideoFrameValidationRejectsOnlyVideoSessionWithNoFrames() throws {
        XCTAssertNoThrow(
            try Recorder.validateVideoFrameCount(wantsVideo: false, videoAppended: 0, elapsed: 15)
        )
        XCTAssertNoThrow(
            try Recorder.validateVideoFrameCount(wantsVideo: true, videoAppended: 1, elapsed: 15)
        )
        XCTAssertThrowsError(
            try Recorder.validateVideoFrameCount(wantsVideo: true, videoAppended: 0, elapsed: 15)
        ) { error in
            guard case KilError.failed(let message) = error else {
                return XCTFail("KilError.failed ではありません: \(error)")
            }
            // 長時間 0 フレームなら消灯・ロックを疑う案内にする
            XCTAssertTrue(message.contains("消灯・ロック"))
        }
    }

    /// 初回フレーム到着前に停止した短時間録画は、消灯・ロックと断定しない別の案内にする
    func testVideoFrameValidationDistinguishesShortRecording() throws {
        XCTAssertThrowsError(
            try Recorder.validateVideoFrameCount(wantsVideo: true, videoAppended: 0, elapsed: 0.5)
        ) { error in
            guard case KilError.failed(let message) = error else {
                return XCTFail("KilError.failed ではありません: \(error)")
            }
            XCTAssertTrue(message.contains("短すぎ"))
            XCTAssertFalse(message.contains("消灯"))
        }
    }
}
