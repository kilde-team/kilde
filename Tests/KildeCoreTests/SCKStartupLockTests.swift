import XCTest
@testable import KildeCore

/// SCK 起動区間ロック (issue #70) の単体テスト。
/// **実際の SCK は使わない** — ここで検証するのは「排他が成立するか」「孤児を片付けられるか」
/// というファイル操作の論理だけ。SCK との組み合わせは統合テスト (T18b) が見る。
///
/// **実運用の共有ロックパスは絶対に触らない。** このリポジトリは複数セッションの
/// worktree 並行実行 (AGENTS.md §2) なので、同じユーザーで `swift test` が同時に走ると
/// 1 つのロックを取り合ってフレークする。さらに実録画の起動区間と重なると、
/// テストが**生きたロックを削除してプロセス間排他を壊し**、この仕組みが防ぐはずの
/// 固まりをテスト自身が起こしうる。テストごとに一意なパスへ差し替える
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
        let again = try XCTUnwrap(SCKStartupLock.tryAcquire())
        again.release()
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

    /// 中身が壊れていても**新しければ**残す (書き込み中の他プロセスを追い出さない)
    func testCorruptButFreshLockIsKept() throws {
        try "かきこみちゅう".write(to: SCKStartupLock.fileURL, atomically: true, encoding: .utf8)
        SCKStartupLock.reapIfStale()
        XCTAssertNil(SCKStartupLock.tryAcquire(), "新しい壊れたロックは残すはず")
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

    /// **掃除も自分が読んだロックだけを消す。** 「孤児」と判定した後・削除する前に
    /// 別プロセスが先に片付けて取り直した場合、その**生きているロック**を消すと
    /// 3 つ目のプロセスまで取得できてしまい、防ぎたい同時起動が起きる。
    ///
    /// `reapIfStale` は「読む」と「消す」を連続して行うため、その隙間に外から割り込めない。
    /// 防御が入っているのは `removeIfInodeMatches` なので、そこを直接確かめる。
    /// **`reapIfStale` 経由で書いた最初の版はこの欠陥を検出できなかった** —
    /// 取り直した後のファイルは「生きている保持者」なので孤児と判定されず、
    /// 削除に到達しないまま通っていた (inode 照合を外しても落ちなかった)
    func testRemoveIgnoresFileReplacedAfterInspection() throws {
        // 掃除対象として読み取った (と想定する) ロックの inode を控える
        let doomed = try XCTUnwrap(SCKStartupLock.tryAcquire())
        let staleInode = try inodeOfLockFile()

        // 別プロセスが先に片付けて取り直した状況を作る (実体が入れ替わり inode が変わる)
        try FileManager.default.removeItem(at: SCKStartupLock.fileURL)
        let theirs = try XCTUnwrap(SCKStartupLock.tryAcquire())
        let liveInode = try inodeOfLockFile()
        XCTAssertNotEqual(staleInode, liveInode, "実体が入れ替わっていないとこのテストは無意味")

        // 古い inode で消しにいっても、今あるのは別物なので消してはいけない
        SCKStartupLock.removeIfInodeMatches(url: SCKStartupLock.fileURL, inode: staleInode)
        XCTAssertNil(SCKStartupLock.tryAcquire(), "取り直された生きたロックを消してはいけない")

        // 一致する inode なら消える (消せない実装になっていないことの確認)
        SCKStartupLock.removeIfInodeMatches(url: SCKStartupLock.fileURL, inode: liveInode)
        let after = try XCTUnwrap(SCKStartupLock.tryAcquire(), "一致する inode なら消えるはず")
        after.release()

        theirs.release()
        doomed.release()
    }

    private func inodeOfLockFile() throws -> ino_t {
        let attrs = try FileManager.default.attributesOfItem(atPath: SCKStartupLock.fileURL.path)
        return ino_t(try XCTUnwrap(attrs[.systemFileNumber] as? UInt64))
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
}
