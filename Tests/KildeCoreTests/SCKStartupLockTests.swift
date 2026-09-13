import XCTest
@testable import KildeCore

/// SCK 起動区間ロック (issue #70) の単体テスト。
/// **実際の SCK は使わない** — ここで検証するのは排他の成立だけ。
/// SCK との組み合わせは統合テスト (T18b) が見る。
///
/// **実運用の共有ロックパスは絶対に触らない。** このリポジトリは複数セッションの
/// worktree 並行実行 (AGENTS.md §2) なので、同じユーザーで `swift test` が同時に走ると
/// 1 つのロックを取り合ってフレークする。さらに実録画の起動区間と重なると、
/// テストが排他を壊してこの仕組みが防ぐはずの固まりを起こしうる。
/// テストごとに一意なパスへ差し替える
final class SCKStartupLockTests: XCTestCase {

    private var tempDirectory: URL!
    private var savedFileURL: URL!

    override func setUp() {
        super.setUp()
        savedFileURL = SCKStartupLock.fileURL
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kilde-lock-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        SCKStartupLock.fileURL = tempDirectory.appendingPathComponent("sck-startup.lock")
    }

    override func tearDown() {
        SCKStartupLock.fileURL = savedFileURL
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - ヘルパ

    private func acquiredToken(_ message: String = "取得できるはず",
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> SCKStartupLock.Token {
        guard case .acquired(let token) = SCKStartupLock.tryAcquire() else {
            XCTFail(message, file: file, line: line)
            throw XCTSkip("取得できなかったため以降を打ち切る")
        }
        return token
    }

    private func assertHeldByOther(_ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .heldByOther = SCKStartupLock.tryAcquire() else {
            return XCTFail("\(message) (結果: \(SCKStartupLock.tryAcquire()))", file: file, line: line)
        }
    }

    // MARK: - 排他

    /// **保持中は 2 つ目が取れない。** これが成立しないと同時起動を防げない。
    /// `flock` は開いたファイル記述に対するロックなので、同一プロセスの別 fd でも
    /// 排他される (実測で確認済み — 2 つ目は EWOULDBLOCK)
    func testSecondAcquisitionFailsWhileHeld() throws {
        let first = try acquiredToken()
        assertHeldByOther("保持中に 2 つ目が取れてはいけない")
        first.release()
        let second = try acquiredToken("解放後は取れるはず")
        second.release()
    }

    func testReleaseIsIdempotent() throws {
        let token = try acquiredToken()
        token.release()
        token.release()   // 2 回目は何もしない (fd の二重 close をしない)
        let again = try acquiredToken()
        again.release()
    }

    /// Token を捨てるだけでも解放される (deinit で close する)
    func testLockIsReleasedWhenTokenIsDiscarded() throws {
        do {
            let token = try acquiredToken()
            assertHeldByOther("保持中は取れない")
            _ = token
        }
        let after = try acquiredToken("Token を捨てたら解放されるはず")
        after.release()
    }

    /// **ロックファイルを消さない。** `flock` は名前ではなく開いたファイル記述に対する
    /// ロックなので、残っていても無害。消すと unlink の競合 (別プロセスが取り直した
    /// ロックを誤って消す) を自分で作ることになる
    func testLockFileIsNotRemovedOnRelease() throws {
        let token = try acquiredToken()
        token.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: SCKStartupLock.fileURL.path),
                      "ロックファイルは残す (消すと unlink 競合を作る)")
        let next = try acquiredToken("残ったファイルでも取得できるはず")
        next.release()
    }

    /// 前の保持者が書いた内容が残らない (診断用の PID が古いままにならない)
    func testHolderPIDIsRewrittenOnAcquire() throws {
        try "999999\n".write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        let token = try acquiredToken()
        defer { token.release() }
        let text = try String(contentsOf: SCKStartupLock.fileURL, encoding: .utf8)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "\(getpid())",
                       "取得時に自分の PID へ書き換えるはず (前の保持者の PID が残らない)")
    }

    // MARK: - 失敗の区別

    /// **「他が保持中」と「そもそも開けない」を混同しない。** 混同すると、
    /// 一時ディレクトリが書けないだけなのに 15 秒待たされた挙句
    /// 「他の kilde が録画の準備中」という誤った原因が出て、無関係な復旧手順へ誘導する
    func testUnopenableLockIsReportedAsUnavailableNotHeld() throws {
        // パスをディレクトリにすると open(O_WRONLY) が EISDIR で失敗する
        // setUp はロックファイルを作らないので、無い場合がある (無条件の removeItem は throw する)
        try? FileManager.default.removeItem(at: SCKStartupLock.fileURL)
        try FileManager.default.createDirectory(at: SCKStartupLock.fileURL,
                                                withIntermediateDirectories: true)
        guard case .unavailable(let code) = SCKStartupLock.tryAcquire() else {
            return XCTFail("開けないケースを heldByOther に畳んではいけない: \(SCKStartupLock.tryAcquire())")
        }
        XCTAssertEqual(code, EISDIR, "errno=\(code)")
    }

    /// 開けないときは**待たずに**、原因の分かるエラーで失敗する
    func testAcquireFailsImmediatelyWhenLockCannotBeOpened() async throws {
        // setUp はロックファイルを作らないので、無い場合がある (無条件の removeItem は throw する)
        try? FileManager.default.removeItem(at: SCKStartupLock.fileURL)
        try FileManager.default.createDirectory(at: SCKStartupLock.fileURL,
                                                withIntermediateDirectories: true)
        let started = Date()
        do {
            _ = try await SCKStartupLock.acquire(timeout: 10)
            XCTFail("開けないのに取得できてしまいました")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("排他ロックを作成できません"), message)
            XCTAssertFalse(message.contains("他の kilde が録画の準備中"),
                           "待っても解決しない失敗に、待機の理由を出してはいけない: \(message)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                              "待たずに失敗するはず (待つと誤った原因で 10 秒待たせる)")
        }
    }

    // MARK: - 待機

    /// 待機が期限で諦め、理由の分かるエラーになる
    func testAcquireTimesOutWhileHeld() async throws {
        let holder = try acquiredToken()
        defer { holder.release() }
        do {
            _ = try await SCKStartupLock.acquire(timeout: 0.2)
            XCTFail("保持中なのに取得できてしまいました")
        } catch {
            XCTAssertTrue("\(error)".contains("他の kilde が録画の準備中"), "\(error)")
        }
    }

    /// **待機中に停止要求が来たら抜ける。** 抜けられないと Ctrl+C に反応できない
    /// (issue #70 の cubic レビュー P1 — 修正前は SIGINT に応答しなかった)
    func testAcquireStopsWhenCancelled() async throws {
        let holder = try acquiredToken()
        defer { holder.release() }
        var cancelled = false
        do {
            _ = try await SCKStartupLock.acquire(timeout: 30, isCancelled: {
                defer { cancelled = true }
                return cancelled
            })
            XCTFail("キャンセルされたのに取得できてしまいました")
        } catch {
            XCTAssertTrue("\(error)".contains("待機を中止"), "\(error)")
        }
    }

    /// **取得できた瞬間にキャンセル済みなら、握らずに中止する。**
    /// 取得と停止要求が競合したとき、トークンを返してしまうと呼び出し元が
    /// `SCShareableContent` の列挙や `startCapture()` へ進み、Ctrl+C / Stop への
    /// 応答が遅れる。**ロックを握ったまま放置しないこと**も要件。
    ///
    /// 待機側の最初の `isCancelled()` を false にしてから true に切り替え、その間に
    /// 保持者を解放することで「待機 → 取得できた、しかしキャンセル済み」を作る
    func testAcquireReleasesAndFailsWhenCancelledAtAcquisition() async throws {
        let holder = try acquiredToken()
        var polls = 0
        var released = false
        do {
            _ = try await SCKStartupLock.acquire(timeout: 10, isCancelled: {
                polls += 1
                // 1 回目は「まだキャンセルされていない」。この後に保持者を解放するので、
                // 次の周回で取得が成功し、そのときにはキャンセル済みになっている
                if polls == 1 {
                    holder.release()
                    released = true
                    return false
                }
                return true
            })
            XCTFail("取得時にキャンセル済みなら中止するはず")
        } catch {
            XCTAssertTrue("\(error)".contains("待機を中止"), "\(error)")
        }
        XCTAssertTrue(released, "保持者を解放していないと、この経路を通っていない")
        // **握ったままにしない** — 中止したのにロックが残ると、以後の録画が開始できない
        let after = try acquiredToken("中止時にロックを解放していないと取得できない")
        after.release()
    }

    /// **構造化キャンセルでも抜ける。** `try? await Task.sleep` はキャンセル例外を
    /// 握り潰すので、`Task.isCancelled` を見ないと busy-spin が期限まで続く
    /// (`Recorder.awaitOrStop` が同じ罠を避けているのと同じ理由)
    func testAcquireExitsOnStructuredCancellation() async throws {
        let holder = try acquiredToken()
        defer { holder.release() }
        let task = Task {
            try await SCKStartupLock.acquire(timeout: 30)
        }
        // 待機に入らせてからキャンセルする
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let started = Date()
        let result = await task.result
        XCTAssertThrowsError(try result.get(), "キャンセルされたら取得しない")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "キャンセル後すぐ抜けるはず (期限まで回り続けない)")
    }

    // MARK: - ロックの場所

    /// **ロックの場所は `KILDE_CONFIG_DIR` に依存しない。** 依存すると、統合テストが
    /// 作業ディレクトリを分離しているため排他が効かず、T18b が直らない。
    /// 環境変数を実際に変えて前後で一致することを確かめる
    func testLockPathIsIndependentOfConfigDirectory() {
        let saved = SCKStartupLock.fileURL
        defer { SCKStartupLock.fileURL = saved }
        SCKStartupLock.fileURL = SCKStartupLock.defaultFileURL

        // **元の環境を復元する。** 落としたままにすると、KILDE_CONFIG_DIR が
        // 設定された環境 (CI やラッパー) では同プロセス内の後続テストから消える
        let savedConfigDir = ProcessInfo.processInfo.environment["KILDE_CONFIG_DIR"]
        defer {
            if let savedConfigDir {
                setenv("KILDE_CONFIG_DIR", savedConfigDir, 1)
            } else {
                unsetenv("KILDE_CONFIG_DIR")
            }
        }

        let before = SCKStartupLock.defaultFileURL
        setenv("KILDE_CONFIG_DIR", "/tmp/kilde-config-dir-a", 1)
        let withA = SCKStartupLock.defaultFileURL
        setenv("KILDE_CONFIG_DIR", "/tmp/kilde-config-dir-b", 1)
        let withB = SCKStartupLock.defaultFileURL

        XCTAssertEqual(before, withA, "KILDE_CONFIG_DIR を変えてもロックの場所は変わらない")
        XCTAssertEqual(withA, withB, "別の KILDE_CONFIG_DIR でも同じ場所を指す")
        XCTAssertFalse(before.path.contains(".kilde"),
                       "設定ディレクトリ配下に置いてはいけない: \(before.path)")
    }

    /// **`$TMPDIR` に影響されない。** 影響されると、環境変数を差し替えたラッパー経由の
    /// kilde が別のロックを見て排他が黙って無効になる
    func testLockPathIsIndependentOfTMPDIR() {
        let savedTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        defer {
            if let savedTMPDIR { setenv("TMPDIR", savedTMPDIR, 1) } else { unsetenv("TMPDIR") }
        }
        let before = SCKStartupLock.defaultFileURL
        setenv("TMPDIR", "/tmp/kilde-fake-tmpdir", 1)
        XCTAssertEqual(SCKStartupLock.defaultFileURL, before,
                       "TMPDIR を差し替えてもロックの場所は変わらない")
    }

    // MARK: - 列挙の待機上限 (issue #90)

    /// **列挙の待機上限は録画より短い。** 列挙 (`devices` / `doctor`) は 0.2 秒で終わる
    /// 操作なので、録画と同じ 15 秒待たせると「一覧を見たいだけなのに固まった」になる。
    /// 逆に危険区間 (実測 0.31 秒) より短いと、待てば通るはずの列挙が毎回警告を出す
    func testEnumerationTimeoutIsShorterThanRecordingButLongerThanStartupWindow() {
        XCTAssertLessThan(SCKStartupLock.enumerationTimeout, SCKStartupLock.defaultTimeout,
                          "列挙の待機は録画より短くする (診断コマンドを固まらせない)")
        // 危険区間は #70 の実測で 0.31 秒。ここを下回ると待てば済む列挙まで諦めてしまう
        XCTAssertGreaterThan(SCKStartupLock.enumerationTimeout, 0.31,
                             "SCK 起動区間 (実測 0.31 秒) より長く待てること")
    }

    /// **待機秒数を切り捨てて表示しない。** `Int` へ丸めると 0.5 秒の待機が
    /// 「0 秒以内に空きませんでした」になり、意味の通らない案内になる。
    /// **この誤りは 2 度作り込んでいる** (文字列生成時と、`Failure.timedOut` を
    /// `Int` で持たせたとき) ので、テストで留める
    func testTimedOutMessageKeepsFractionalSeconds() {
        let fractional = SCKStartupLock.Failure.timedOut(seconds: 0.5).description
        XCTAssertTrue(fractional.contains("0.5 秒"), fractional)
        XCTAssertFalse(fractional.contains("0 秒以内"), "切り捨てて 0 秒にしてはいけない: \(fractional)")

        // 整数はそのまま整数で見せる ("3.0 秒" にしない)
        let whole = SCKStartupLock.Failure.timedOut(seconds: 3).description
        XCTAssertTrue(whole.contains("3 秒"), whole)
        XCTAssertFalse(whole.contains("3.0 秒"), whole)
    }

    /// **表示のための変換でトラップしない。** エラーを報告している最中にプロセスが
    /// 落ちるのが最悪の壊れ方なので、`acquire` が弾くはずの値でも書式化は生き延びる
    func testTimedOutMessageSurvivesNonFiniteSeconds() {
        for value in [TimeInterval.infinity, -TimeInterval.infinity, TimeInterval.nan] {
            let message = SCKStartupLock.Failure.timedOut(seconds: value).description
            XCTAssertTrue(message.contains("他の kilde が録画の準備中"), message)
        }
    }

    /// **指定した上限より前に諦めない。** `testAcquireTimesOutWhileHeld` は「諦めること」と
    /// エラー文言を見るが、**待ち時間が指定どおりかは見ていない**。期限の計算が壊れて
    /// 即座に諦めると、危険区間 (0.31 秒) を待てば通るはずの列挙が毎回警告を出す。
    ///
    /// 実時間で待つテストなので、`enumerationTimeout` (3 秒) ではなく短い値で確かめる —
    /// 検証したいのは「指定値に従うこと」であって特定の秒数ではない
    func testAcquireWaitsUpToTheGivenTimeoutBeforeGivingUp() async throws {
        let holder = try acquiredToken()
        defer { holder.release() }
        let limit: TimeInterval = 0.5
        let started = DispatchTime.now()
        do {
            _ = try await SCKStartupLock.acquire(timeout: limit)
            XCTFail("保持中なのに取得できてしまいました")
        } catch {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            // 50ms 間隔のポーリングなので、期限ちょうどではなく少し手前で抜けうる
            XCTAssertGreaterThan(elapsed, limit * 0.8,
                                 "指定した上限より大幅に早く諦めている: \(elapsed) 秒")
            XCTAssertLessThan(elapsed, limit + 2,
                              "上限を大きく超えて待っている: \(elapsed) 秒")
        }
    }
}
