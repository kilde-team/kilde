import XCTest
@testable import KildeCore

/// SCK 起動区間ロック (issue #70) の単体テスト。
/// **実際の SCK は使わない** — ここで検証するのは「排他が成立するか」「孤児を片付けられるか」
/// というファイル操作の論理だけ。SCK との組み合わせは統合テスト (T18b) が見る
final class SCKStartupLockTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: SCKStartupLock.fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: SCKStartupLock.fileURL)
        super.tearDown()
    }

    func testSecondAcquisitionFailsWhileHeld() throws {
        let first = try XCTUnwrap(SCKStartupLock.tryAcquire())
        // 保持中は取れない — これが成立しないと同時起動を防げない
        XCTAssertNil(SCKStartupLock.tryAcquire())
        first.release()
        // 解放後は取れる
        let second = try XCTUnwrap(SCKStartupLock.tryAcquire())
        second.release()
    }

    func testReleaseIsIdempotent() throws {
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire())
        token.release()
        token.release()   // 2 回目は何もしない
        XCTAssertNotNil(SCKStartupLock.tryAcquire().map { $0.release() })
    }

    /// **保持者が死んでいたら片付けて取り直せること。** これが無いと、異常終了した
    /// プロセスのロックが残って以後の録画が永久に開始できなくなる
    /// (T23 の占有役で実際に踏んだ形の再発を防ぐ)
    func testStaleLockFromDeadHolderIsReaped() throws {
        // 存在しない PID を保持者として書き込む。0 は kill(0, 0) が
        // 「プロセスグループ全体」の意味になるため使わない
        let deadPID = 999_999
        try "\(deadPID) \(Date().timeIntervalSince1970)\n"
            .write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(SCKStartupLock.tryAcquire(), "掃除前は取れないはず")

        SCKStartupLock.reapIfStale()
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire(), "死んだ保持者のロックは片付くはず")
        token.release()
    }

    /// **保持者が生きていても、古すぎるロックは片付ける。** PID が再利用されて
    /// `kill(pid, 0)` が誤って「生存」と答える場合の保険。危険区間は実測 0.31 秒なので、
    /// 30 秒残っているロックは保持者が異常終了したとみなしてよい
    func testStaleLockFromLivingButAncientHolderIsReaped() throws {
        let ancient = Date().timeIntervalSince1970 - (SCKStartupLock.staleAfter + 10)
        try "\(getpid()) \(ancient)\n"
            .write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(SCKStartupLock.tryAcquire(), "掃除前は取れないはず")

        SCKStartupLock.reapIfStale()
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire(), "古すぎるロックは片付くはず")
        token.release()
    }

    /// 生きている保持者の**新しい**ロックは片付けない (これを消すと排他が壊れる)
    func testFreshLockFromLivingHolderIsKept() throws {
        try "\(getpid()) \(Date().timeIntervalSince1970)\n"
            .write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        SCKStartupLock.reapIfStale()
        XCTAssertNil(SCKStartupLock.tryAcquire(), "生きている保持者のロックは残すはず")
    }

    /// 中身が壊れていても (書き込み途中で死んだ場合)、古ければ片付ける
    func testCorruptLockIsReapedWhenOld() throws {
        try "こわれている".write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-(SCKStartupLock.staleAfter + 10))
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: SCKStartupLock.fileURL.path)
        SCKStartupLock.reapIfStale()
        let token = try XCTUnwrap(SCKStartupLock.tryAcquire(), "壊れた古いロックは片付くはず")
        token.release()
    }

    /// **解放は自分のロックだけを消す。** 孤児として掃除された後に別プロセスが
    /// 取り直したロックを消してしまうと、排他が黙って壊れる
    func testReleaseDoesNotRemoveSomeoneElsesLock() throws {
        let mine = try XCTUnwrap(SCKStartupLock.tryAcquire())
        // 横から掃除され、別プロセスが取り直した状況を作る
        try? FileManager.default.removeItem(at: SCKStartupLock.fileURL)
        let theirs = try XCTUnwrap(SCKStartupLock.tryAcquire())

        mine.release()   // inode が違うので消さないはず
        XCTAssertNil(SCKStartupLock.tryAcquire(), "他人のロックを消してはいけない")
        theirs.release()
    }

    /// **ロックの場所は KILDE_CONFIG_DIR に依存しない。** 依存すると、統合テストが
    /// 作業ディレクトリを分離しているため排他が効かず、T18b が直らない
    func testLockPathIsIndependentOfConfigDirectory() {
        let path = SCKStartupLock.fileURL.path
        XCTAssertFalse(path.contains(".kilde"), "設定ディレクトリ配下に置いてはいけない: \(path)")
        XCTAssertEqual(SCKStartupLock.fileURL, SCKStartupLock.fileURL, "パスは安定している")
    }
}
