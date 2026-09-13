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
            .appendingPathComponent(lockFileName)
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
            // **`NSTemporaryDirectory()` へは落とさない。** あれは `$TMPDIR` を見るので、
            // フォールバックが「環境変数に依存しない」という要件を自分で破ってしまう
            // (2 プロセスが別々のロックを取り、防ぎたい二重起動が再発する)。
            // 代わりに uid で固定したパスを使う — 環境変数の影響を受けず、
            // ユーザー単位で共有される
            return "/tmp"
        }
        return String(cString: buf)
    }

    /// フォールバック時のファイル名に uid を混ぜる (`/tmp` は全ユーザー共有なので、
    /// 混ぜないと他ユーザーのロックと衝突して互いの録画を止め合う)
    private static var lockFileName: String {
        "kilde-sck-startup-\(getuid()).lock"
    }

    /// 録画の起動が待つ既定の上限。**録画は待てば成功する**ので長めに取る
    /// (危険区間は実測 0.31 秒なので、通常はほとんど待たない)
    public static let defaultTimeout: TimeInterval = 15

    /// 列挙 (`devices` / `doctor` / GUI のウィンドウ一覧) が待つ上限 (issue #90)。
    /// **録画より短くする** — 列挙は 0.2 秒で終わる操作 (実測: `devices` 0.16〜0.19 秒、
    /// `doctor` 0.20〜0.21 秒) で、待たせすぎると「一覧を見たいだけなのに固まった」に見える。
    /// 危険区間 0.31 秒に対して十分な余裕があり、かつ人が待てる長さとして 3 秒にしている
    public static let enumerationTimeout: TimeInterval = 3

    /// 取得できなかった理由。**呼び出し側が対処を変えられるように種別で分ける。**
    ///
    /// `KilError.failed` に畳んで投げていたが、それだと呼び出し側から区別できない。
    /// 列挙 (issue #90) は「他プロセスが録画開始中で待ち切れなかった」なら続行してよいが、
    /// 「ロックファイルが開けない」は**排他がまったく成立していない**状態で、
    /// 同じ文言で報告すると利用者を無関係な復旧手順 (先の録画を待つ) へ誘導してしまう。
    ///
    /// **文言は `KilError.failed` 時代のものを維持する** — 既存テストと利用者向けの
    /// メッセージを変える必要はなく、変えるのは「呼び出し側が種別を見分けられること」だけ
    public enum Failure: Error, CustomStringConvertible {
        /// 停止要求 (Ctrl+C / GUI の Stop / 構造化キャンセル) で待機をやめた
        case cancelled
        /// 他プロセスが保持したまま期限が来た。**待てば取れる見込みはある**。
        /// **`Int` ではなく `TimeInterval` で運ぶ** — 整数で持つと `lockTimeout: 0.5` が
        /// 0 に丸まり「0 秒以内に空きませんでした」という意味の通らない文言になる
        case timedOut(seconds: TimeInterval)
        /// ロックファイルを開けない。**待っても解決せず、排他が成立していない**
        case unavailable(path: String, errorNumber: Int32)
        /// `timeout` に NaN / 無限大 / 負値が渡された
        case invalidTimeout(TimeInterval)

        public var description: String {
            switch self {
            case .cancelled:
                return "ロックの待機を中止しました"
            case .timedOut(let seconds):
                return "他の kilde が録画の準備中のため開始できません "
                    + "(同時に SCK のキャプチャを開始するとどちらも復帰しないため待機しましたが、"
                    + "\(Self.formatSeconds(seconds)) 秒以内に空きませんでした)。"
                    + "先の録画の開始を待ってから実行してください"
            case .unavailable(let path, let errorNumber):
                return "録画の排他ロックを作成できません: \(path) "
                    + "(errno=\(errorNumber): \(String(cString: strerror(errorNumber))))"
            case .invalidTimeout(let timeout):
                return "ロックの待機時間が不正です: \(timeout)"
            }
        }

        // **`KilError` への変換は用意しない。** `Recorder.asKilError` が
        // 「`KilError` でなければ `.failed(String(describing:))`」で畳んでおり、
        // `description` を持つこの型はそれで正しい文言と終了コード 1 になる。
        // ここに専用の変換を足すと同じ写像が 2 つ並び、片方だけ変わって静かに食い違う

        /// 待機秒数の表示。**`Int(...)` で切り捨てない** — 0.5 秒が「0 秒」になると
        /// 意味が通らない。整数なら "3"、小数なら "0.5" にする。
        ///
        /// 表示だけのために変換で落ちないよう、`Int` に収まらない値は書式化に回す
        /// (`acquire` は NaN / 無限大を `invalidTimeout` で弾くのでここには来ないが、
        /// **エラーを報告している最中にトラップする**のが最悪の壊れ方なので念を入れる)
        static func formatSeconds(_ seconds: TimeInterval) -> String {
            guard seconds.isFinite,
                  seconds == seconds.rounded(),
                  seconds.magnitude < 1e15 else {
                return String(format: "%.1f", seconds)
            }
            return String(Int(seconds))
        }
    }

    /// ロックを取る。取れるまで待ち、`timeout` を超えたら諦めて throw する。
    /// **投げるのは `Failure`** — 呼び出し側が理由で対処を変えられるようにするため
    /// (issue #90 の列挙は `timedOut` なら続行し、`unavailable` は別の文言で報せる)。
    /// SCK を使わない構成 (マイクのみ) では呼ばないこと — 無関係な録画まで直列化してしまう。
    ///
    /// **async にしているのは待ちでスレッドを塞がないため** (issue #35 と同じ理由)。
    /// 同期 `Thread.sleep` で待つと協調プールのスレッドを最長 `timeout` 秒占有し、
    /// さらに待機中は停止要求を観測できないので Ctrl+C への応答が遅れる。
    /// `isCancelled` を渡せば、待っている間も停止要求で抜けられる
    public static func acquire(timeout: TimeInterval = defaultTimeout,
                               isCancelled: @escaping () -> Bool = { false }) async throws -> Token {
        // **単調時計で測る。** `Date` だとシステム時刻が後戻りしたときに期限も後戻りし、
        // ハングした保持者を相手に上限を超えて待ち続ける。
        //
        // 変換の前に値を検める — `Int(timeout * 1000)` は NaN や無限大で**トラップする**
        // (KilError にならずプロセスが落ちる)。呼び出し元が既定値を使う限り起きないが、
        // KildeCore はライブラリなので外から任意の値が来うる
        let milliseconds = timeout * 1000
        guard milliseconds.isFinite, milliseconds >= 0 else {
            throw Failure.invalidTimeout(timeout)
        }
        // 上限も切る — Int に収まっても DispatchTime の加算が飽和して
        // 「事実上無期限に待つ」状態になる。1 時間あれば起動区間 (0.31 秒) には十分。
        // **`min` を取ってから Int にする。** 先に `Int(timeout)` すると、有限でも
        // Int の表現範囲を超える値でトラップする (isFinite の検査だけでは防げない)
        let cappedMilliseconds = Int(min(milliseconds, 3_600_000))
        let deadline = DispatchTime.now() + .milliseconds(cappedMilliseconds)
        // エラー文にはこの**実効値**を使う。元の `timeout` を出すと、上限で丸めたときに
        // 「7200 秒以内に空きませんでした」と実際の待機 (1 時間) と違う値を伝えてしまう。
        // **整数除算にしない** — 0.5 秒の待機が 0 秒と表示される
        let effectiveSeconds = Double(cappedMilliseconds) / 1000
        // `Task.isCancelled` も見る — 見ないと、構造化キャンセルされたときに
        // `try?` が sleep のキャンセル例外を握り潰し、open + flock を無遅延で回す
        // busy-spin が期限まで続く (`Recorder.awaitOrStop` が同じ罠を避けているのと同じ)
        while !Task.isCancelled {
            switch tryAcquire() {
            case .acquired(let token):
                // **取れた直後にもキャンセルを見る。** 取得と停止要求が競合すると、
                // キャンセル済みなのにトークンを返して `SCShareableContent` の列挙や
                // `startCapture()` へ進んでしまい、Ctrl+C / Stop への応答が遅れる。
                // 握ったままにしないよう解放してから中止する
                if Task.isCancelled || isCancelled() {
                    token.release()
                    throw Failure.cancelled
                }
                return token
            case .unavailable(let errorNumber):
                // **待っても解決しない失敗を待たない。** 一時ディレクトリが書けない等を
                // 「他プロセスが保持中」と同じ扱いにすると、15 秒待たせた挙句に
                // 誤った原因を示し、利用者を無関係な復旧手順へ誘導する
                throw Failure.unavailable(path: fileURL.path, errorNumber: errorNumber)
            case .heldByOther:
                break   // 待つ
            }
            if isCancelled() {
                // 呼び出し元 (Recorder) が準備中キャンセルとして畳み直す。
                // ここで cancelledBeforeRecording を立てないと exit 1 になる
                throw Failure.cancelled
            }
            if DispatchTime.now() >= deadline {
                throw Failure.timedOut(seconds: effectiveSeconds)
            }
            // 危険区間は 0.3 秒程度なので、短い間隔で見に行けばほとんど待たない
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.cancelled
    }

    /// `tryAcquire` の結果。**「取れない」を 1 つに畳まない** —
    /// 「他が保持中 (待てば解決する)」と「そもそも開けない (待っても無駄)」は
    /// 対処が正反対なので、呼び出し側が区別できる形で返す
    enum Attempt {
        case acquired(Token)
        /// 他プロセスが保持中 (`flock` が `EWOULDBLOCK`)。待てば取れる見込み
        case heldByOther
        /// ロックファイルを開けない (書けないディレクトリ等)。待っても解決しない
        case unavailable(errno: Int32)
    }

    /// 1 回だけ取得を試みる。
    /// **ファイルは消さない** — `flock` はファイル名ではなく開いたファイル記述に対する
    /// ロックなので、残っていても無害。消すと unlink の競合を自分で作ることになる
    static func tryAcquire() -> Attempt {
        let url = fileURL
        return url.withUnsafeFileSystemRepresentation { path -> Attempt in
            guard let path else { return .unavailable(errno: EINVAL) }
            // **`O_NOFOLLOW` でシンボリックリンクを拒否する (CWE-59)。**
            // `confstr` 失敗時のフォールバック先 `/tmp` は全ユーザーから書けるうえ、
            // パスが `kilde-sck-startup-<uid>.lock` と予測可能なので、別 UID の
            // プロセスがファイル作成前に symlink を置ける。追従すると下の
            // `ftruncate` + `write` が**リンク先 (利用者の設定や録画ファイル) を破壊する**。
            // `open` の失敗は既存の `.unavailable` が拾うので ELOOP 専用の分岐は要らない
            let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return .unavailable(errno: errno) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(fd)
                // EWOULDBLOCK (= EAGAIN) だけが「他が持っている」。それ以外は環境側の問題
                return code == EWOULDBLOCK ? .heldByOther : .unavailable(errno: code)
            }
            // 保持者を診断できるようにしておく (排他そのものには使わない)。
            // 前の保持者の内容が残らないよう切り詰めてから書く
            ftruncate(fd, 0)
            let body = "\(getpid())\n"
            _ = body.withCString { write(fd, $0, strlen($0)) }
            return .acquired(Token(descriptor: fd))
        }
    }
}
