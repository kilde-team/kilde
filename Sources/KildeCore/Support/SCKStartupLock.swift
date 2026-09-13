import Foundation
import Darwin

/// SCK セッションの**起動区間**だけをプロセス間で直列化するロック (issue #70)。
///
/// ## なぜ必要か
///
/// 2 つのプロセスが同時に SCK のシステム音声キャプチャを開始すると、双方が replayd との
/// XPC から戻らなくなる。実測では `SCShareableContent.current` で止まる側と
/// `SCStream.startCapture()` で止まる側に分かれ、**100% 再現する**。
/// 一度この状態に入ると、片方を SIGKILL しても**もう片方は 60 秒経っても回復しない**ので、
/// 「詰まってから諦める」(タイムアウト) では救えない。**重ねないことでしか防げない。**
///
/// ## なぜ起動区間だけで足りるか
///
/// 実測で切り分けた:
/// - 1 つ目が起動を終えた後なら、2 つ目が起動して固まっても**1 つ目は完走する**
/// - 1 つ目が録画中に 2 つ目を起動すると、**両方とも完走する**
/// - 起動を 0.5 秒ずらすだけで**両方 exit 0**
///
/// つまり危険なのは起動処理が重なる瞬間だけで、その長さは実測 **0.31 秒**。
/// 録画全体を排他すると「2 本同時録画」を潰してしまうが、起動区間だけなら
/// 少し待つだけで**両方録れる**。
///
/// ## なぜ設定ディレクトリに置かないか
///
/// **`~/.kilde` (`KILDE_CONFIG_DIR`) ではダメ。** replayd はユーザーセッションに 1 つなので、
/// `KILDE_CONFIG_DIR` を別々にした 2 プロセスでも衝突する (実測済み)。統合テストは
/// `KILDE_CONFIG_DIR` を作業ディレクトリへ分離するため、そこにロックを置くと
/// **テスト同士で排他が効かず T18b が直らない**。ユーザー単位で固定の一時ディレクトリを使う。
///
/// ## 既知の範囲
///
/// 対象は `rec` の SCK 起動だけで、`devices` / `doctor` / GUI のウィンドウ列挙は含まない。
/// 列挙との併走は固まりを起こさないが、別の失敗 (TCC -3801) を招くことがある — issue #90。
public enum SCKStartupLock {

    /// ロックの保持者。`release()` を呼ぶか deinit で解放される
    public final class Token {
        private let url: URL
        private let inode: ino_t
        private var released = false

        init(url: URL, inode: ino_t) {
            self.url = url
            self.inode = inode
        }

        /// ロックを解放する。**自分が作ったファイルのときだけ消す** —
        /// inode を照合しないと、孤児として掃除された後に別プロセスが取り直した
        /// ロックを消してしまう (OutputFileReservation.consume と同じ考え方)
        public func release() {
            guard !released else { return }
            released = true
            SCKStartupLock.removeIfInodeMatches(url: url, inode: inode)
        }

        deinit { release() }
    }

    /// ロックファイルの場所。ユーザー単位で固定 (`/var/folders/…/T/`)。
    /// `KILDE_CONFIG_DIR` の影響を受けないのが要件 (上のコメント参照)。
    ///
    /// **テストからは差し替える。** 実運用のパスを共有したまま単体テストを走らせると、
    /// 並行して動く別セッションの `swift test` や実録画とロックを取り合い、
    /// テストが**生きたロックを削除して排他を壊す** — この仕組みが防ぐはずの固まりを
    /// テスト自身が起こしてしまう (AGENTS.md §2 の並行 worktree 運用)
    static var fileURL: URL = defaultFileURL

    static var defaultFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kilde-sck-startup.lock")
    }

    /// 孤児とみなすまでの経過時間。危険区間は実測 0.31 秒なので、これを超えて
    /// 残っているロックは保持者が異常終了したとみなしてよい。PID の再利用で
    /// `kill(pid, 0)` が誤って「生存」と答える場合の保険も兼ねる
    static let staleAfter: TimeInterval = 30

    /// ロックを取る。取れるまで待ち、`timeout` を超えたら諦めて throw する。
    /// SCK を使わない構成 (マイクのみ) では呼ばないこと — 無関係な録画まで直列化してしまう。
    ///
    /// **async にしているのは待ちでスレッドを塞がないため** (issue #35 と同じ理由)。
    /// 同期 `Thread.sleep` で待つと協調プールのスレッドを最長 `timeout` 秒占有し、
    /// さらに待機中は停止要求を観測できないので Ctrl+C への応答が遅れる。
    /// `isCancelled` を渡せば、待っている間も停止要求で抜けられる
    public static func acquire(timeout: TimeInterval = 15,
                               isCancelled: @escaping () -> Bool = { false },
                               now: @escaping () -> Date = Date.init) async throws -> Token {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if let token = tryAcquire(now: now) { return token }
            // 保持者が異常終了して残っただけのロックなら片付けて取り直す
            reapIfStale(now: now)
            if isCancelled() {
                throw KilError.failed("録画は開始されませんでした (準備中に停止しました)")
            }
            if now() >= deadline {
                throw KilError.failed(
                    "他の kilde が録画の準備中のため開始できません "
                    + "(同時に SCK のキャプチャを開始するとどちらも復帰しないため待機しましたが、"
                    + "\(Int(timeout)) 秒以内に空きませんでした)。"
                    + "先の録画の開始を待ってから実行してください"
                )
            }
            // 危険区間は 0.3 秒程度なので、短い間隔で見に行けばほとんど待たない。
            // キャンセルされたら次の周回の isCancelled で抜ける (ここでは投げない)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 1 回だけ取得を試みる。取れなければ nil
    static func tryAcquire(now: @escaping () -> Date = Date.init) -> Token? {
        let url = fileURL
        return url.withUnsafeFileSystemRepresentation { path -> Token? in
            guard let path else { return nil }
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            // 保持者の身元を書く。孤児判定に使う
            let body = "\(getpid()) \(now().timeIntervalSince1970)\n"
            _ = body.withCString { write(fd, $0, strlen($0)) }
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return Token(url: url, inode: st.st_ino)
        }
    }

    /// 保持者が死んでいる、または古すぎるロックを片付ける。
    ///
    /// **読んだ物と消す物が同じかを inode で確かめてから消す。** 確かめないと、
    /// 「孤児」と判定した後・unlink する前に別プロセスが先に片付けて取り直した場合に、
    /// **その新しい (生きている) ロックを消してしまう**。そうなると 3 つ目のプロセスも
    /// 取得できてしまい、この仕組みが防ぐはずの同時起動が起きる。
    /// `Token.release()` が同じ競合を inode 照合で防いでいるのと揃える
    static func reapIfStale(now: @escaping () -> Date = Date.init) {
        let url = fileURL
        // 中身と inode を 1 回の open から読む — 別々に読むとその間に入れ替わりうる
        guard let (text, inode) = readWithInode(url) else { return }
        let parts = text.split(separator: " ")
        guard parts.count >= 2,
              let pid = pid_t(parts[0]),
              let started = TimeInterval(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            // 中身が壊れている = 書き込み途中で死んだ。経過が分からないので古さで判断する
            reapIfOlderThanStale(url: url, inode: inode, now: now)
            return
        }
        let age = now().timeIntervalSince1970 - started
        let holderGone = kill(pid, 0) != 0 && errno == ESRCH
        // PID が再利用されて「生存」に見えることがあるので、古さでも切る
        if holderGone || age > staleAfter {
            removeIfInodeMatches(url: url, inode: inode)
        }
    }

    private static func reapIfOlderThanStale(url: URL, inode: ino_t, now: () -> Date) {
        var st = stat()
        guard url.withUnsafeFileSystemRepresentation({ path -> Bool in
            guard let path else { return false }
            return stat(path, &st) == 0
        }), st.st_ino == inode else { return }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        guard now().timeIntervalSince(modified) > staleAfter else { return }
        removeIfInodeMatches(url: url, inode: inode)
    }

    /// 中身と inode を同じディスクリプタから読む (別々に読むと入れ替わりを見逃す)
    private static func readWithInode(_ url: URL) -> (String, ino_t)? {
        url.withUnsafeFileSystemRepresentation { path -> (String, ino_t)? in
            guard let path else { return nil }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, buf.count)
            guard n >= 0 else { return nil }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            return (text, st.st_ino)
        }
    }

    /// パスの先が期待した inode のときだけ消す。
    /// **`FileManager.removeItem` をそのまま呼ばない** — check-then-unlink の間に
    /// 入れ替わった別プロセスのロックを消してしまう。
    ///
    /// `reapIfStale` は「読む」と「消す」を連続して行うため、その隙間に外から割り込めない。
    /// 競合に対する防御を検証できるのはここだけなので `internal` にしてテストから直接呼ぶ
    static func removeIfInodeMatches(url: URL, inode: ino_t) {
        var st = stat()
        guard url.withUnsafeFileSystemRepresentation({ path -> Bool in
            guard let path else { return false }
            return stat(path, &st) == 0
        }), st.st_ino == inode else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
