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

    /// **保持中は 2 つ目が取れない。** これが成立しないと同時起動を防げない。
    /// `flock` は開いたファイル記述に対するロックなので、同一プロセスの別 fd でも
    /// 排他される (実測で確認済み — 2 つ目は EWOULDBLOCK)
    func testSecondAcquisitionFailsWhileHeld() throws {
        let first = try XCTUnwrap(SCKStartupLock.tryAcquire())
        XCTAssertNil(SCKStartupLock.tryAcquire(), "保持中に 2 つ目が取れてはいけない")
        first.release()
        let second = try XCTUnwrap(SCKStartupLock.tryAcquire(), "解放後は取れるはず")
        second.release()
    }

    func testReleaseIsIdempotent() throws {
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire())
        token.release()
        token.release()   // 2 回目は何もしない (fd の二重 close をしない)
        let again = try XCTUnwrap(SCKStartupLock.tryAcquire())
        again.release()
    }

    /// Token を捨てるだけでも解放される (deinit で close する)
    func testLockIsReleasedWhenTokenIsDiscarded() throws {
        do {
            let token = try XCTUnwrap(SCKStartupLock.tryAcquire())
            XCTAssertNil(SCKStartupLock.tryAcquire(), "保持中は取れない")
            _ = token
        }
        let after = try XCTUnwrap(SCKStartupLock.tryAcquire(), "Token を捨てたら解放されるはず")
        after.release()
    }

    /// **ロックファイルを消さない。** `flock` は名前ではなく開いたファイル記述に対する
    /// ロックなので、残っていても無害。消すと unlink の競合 (別プロセスが取り直した
    /// ロックを誤って消す) を自分で作ることになる
    func testLockFileIsNotRemovedOnRelease() throws {
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire())
        token.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: SCKStartupLock.fileURL.path),
                      "ロックファイルは残す (消すと unlink 競合を作る)")
        // 残っていても次の取得を妨げない
        let next = try XCTUnwrap(SCKStartupLock.tryAcquire(), "残ったファイルでも取得できるはず")
        next.release()
    }

    /// 前の保持者が書いた内容が残らない (診断用の PID が古いままにならない)
    func testHolderPIDIsRewrittenOnAcquire() throws {
        try "999999\n".write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire())
        defer { token.release() }
        let text = try String(contentsOf: SCKStartupLock.fileURL, encoding: .utf8)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "\(getpid())",
                       "取得時に自分の PID へ書き換えるはず (前の保持者の PID が残らない)")
    }

    /// 待機が期限で諦め、理由の分かるエラーになる
    func testAcquireTimesOutWhileHeld() async throws {
        let holder = try XCTUnwrap(SCKStartupLock.tryAcquire())
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
        let holder = try XCTUnwrap(SCKStartupLock.tryAcquire())
        defer { holder.release() }
        var cancelled = false
        do {
            // 1 周目は待たせ、2 周目でキャンセル済みにする
            _ = try await SCKStartupLock.acquire(timeout: 30, isCancelled: {
                defer { cancelled = true }
                return cancelled
            })
            XCTFail("キャンセルされたのに取得できてしまいました")
        } catch {
            XCTAssertTrue("\(error)".contains("待機を中止"), "\(error)")
        }
    }

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
}
