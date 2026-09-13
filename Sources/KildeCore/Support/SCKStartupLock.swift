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
/// ## なぜ `flock` か (自前の孤児検出をやめた理由)
///
/// 最初は `O_CREAT|O_EXCL` でファイルを作り、PID の生存 (`kill(pid, 0)`) と経過時間で
/// 孤児を検出していた。`flock(LOCK_EX|LOCK_NB)` はそれをカーネルが提供する:
///
/// - **保持者が死ねば即座に解放される** — SIGKILL でも。孤児検出そのものが要らない
///   (実測: 保持者を SIGKILL した直後に別プロセスが取得できる)
/// - **同一プロセスの別 fd でも排他される** (実測: 2 つ目は `EWOULDBLOCK`)
/// - unlink を伴わないので、check-then-unlink の競合が原理的に無い
///
/// 自前実装には**壊れ方が 2 つ残っていた**:
///
/// 1. 保持者の 0.3 秒の起動中に 30 秒以上の時刻ジャンプやスリープが挟まると、
///    **生きている保持者のロックを孤児と誤判定して剥がす** — 防ぎたかった同時起動を
///    自分で起こす
/// 2. **ハングした保持者のロックを時間切れで剥がすと、後続が既にデッドロックした
///    replayd に突っ込む** — タイムアウトで綺麗に失敗する代わりにハングを連鎖させる
///
/// `flock` なら 2 は起きない。ハングした保持者はプロセスが生きている限りロックを持ち、
/// 後続は待機タイムアウトで安全に失敗する。**「剥がせない」ことがここでは正しい挙動。**
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

    /// ロックの保持者。`release()` を呼ぶか deinit で解放される。
    /// **プロセスが死んでも解放される** (カーネルが fd を閉じるため) ので、
    /// 異常終了しても後続を締め出さない
    public final class Token {
        private let descriptor: Int32
        private var released = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// ロックを解放する。close だけでも解放されるが、意図を示すため明示的に外す
        public func release() {
            guard !released else { return }
            released = true
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        deinit { release() }
    }

    /// ロックファイルの場所。ユーザー単位で固定。
    ///
    /// **テストからは差し替える。** 実運用のパスを共有したまま単体テストを走らせると、
    /// 並行して動く別セッションの `swift test` や実録画とロックを取り合う
    /// (AGENTS.md §2 の並行 worktree 運用)
    static var fileURL: URL = defaultFileURL

    static var defaultFileURL: URL {
        URL(fileURLWithPath: userTemporaryDirectory, isDirectory: true)
            .appendingPathComponent("kilde-sck-startup.lock")
    }

    /// ユーザー単位の一時ディレクトリ。**`NSTemporaryDirectory()` は使わない** —
    /// あれは `$TMPDIR` を見るので、`TMPDIR` を差し替えたラッパー経由で起動した
    /// kilde と通常の kilde が**別々のロックを見る**恐れがある。そうなると排他が
    /// 黙って無効になり、回復不能な二重固まりが再発する。
    ///
    /// 念のため実測したところ、macOS 26 では `TMPDIR=/tmp/fake` を渡しても
    /// `NSTemporaryDirectory()` は `confstr` と同じ値を返した (つまりこの環境では
    /// 両者に差が出ない)。**それでも `confstr` を使う** — 環境変数を見ないことが
    /// 仕様として保証されている方を選ぶ。「今の環境で同じだった」は根拠として弱い
    static var userTemporaryDirectory: String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 0, n <= buf.count else {
            // confstr が使えない環境 (サンドボックス等) では NSTemporaryDirectory に落ちる。
            // 排他が弱まる可能性はあるが、ロックを置けずに素通りするよりはよい
            return NSTemporaryDirectory()
        }
        return String(cString: buf)
    }

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
            if let token = tryAcquire() { return token }
            if isCancelled() {
                // 呼び出し元 (Recorder) が準備中キャンセルとして畳み直す。
                // ここで cancelledBeforeRecording を立てないと exit 1 になる
                throw KilError.failed("ロックの待機を中止しました")
            }
            if now() >= deadline {
                throw KilError.failed(
                    "他の kilde が録画の準備中のため開始できません "
                    + "(同時に SCK のキャプチャを開始するとどちらも復帰しないため待機しましたが、"
                    + "\(Int(timeout)) 秒以内に空きませんでした)。"
                    + "先の録画の開始を待ってから実行してください"
                )
            }
            // 危険区間は 0.3 秒程度なので、短い間隔で見に行けばほとんど待たない
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 1 回だけ取得を試みる。取れなければ nil。
    /// **ファイルは消さない** — `flock` はファイル名ではなく開いたファイル記述に対する
    /// ロックなので、残っていても無害。消すと unlink の競合を自分で作ることになる
    static func tryAcquire() -> Token? {
        let url = fileURL
        return url.withUnsafeFileSystemRepresentation { path -> Token? in
            guard let path else { return nil }
            let fd = open(path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return nil
            }
            // 保持者を診断できるようにしておく (排他そのものには使わない)。
            // 前の保持者の内容が残らないよう切り詰めてから書く
            ftruncate(fd, 0)
            let body = "\(getpid())\n"
            _ = body.withCString { write(fd, $0, strlen($0)) }
            return Token(descriptor: fd)
        }
    }
}
