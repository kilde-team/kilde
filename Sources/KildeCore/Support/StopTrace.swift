import Foundation

/// 停止シーケンスの通過点を時刻つきで stderr に出す診断トレース (issue #95)。
///
/// **なぜ必要か**: 残存ハングは `Recorder.run()` の `completionCondition` 待ちで止まる
/// ことが 4 例すべてで確認されているが、**その手前のどこで詰まったかは `sample` では
/// 分からない**。`sample(1)` は中断中の async 関数を観測できず、停止シーケンス
/// (`waitForStopOrDuration` → `sck.stop()` → `mixer.flush()` → `writer.finish()`) は
/// ほぼ全体が async のため、スタックには待ち合わせの最終地点しか出ない。
/// 通過点を自前で刻むしかない。
///
/// **既定では何も出さない。** `KILDE_TRACE_STOP=1` のときだけ有効にする —
/// 常時有効にすると `rec` の stderr に診断が混ざり、WARNING を grep している
/// 統合テスト (T23 / T25) の判定を汚す。
///
/// 出力は 1 行 1 通過点で、`[stop-trace] <単調秒> <ラベル>` の形。**単調時計を使う**
/// のは、計測中にシステム時刻が動いても区間の長さが狂わないようにするため。
public enum StopTrace {

    /// 有効かどうかは 1 度だけ決める。コールバック経路 (handleAudio) からも
    /// 呼ばれるため、毎回 environment を引くと録画中のホットパスに辞書引きが乗る
    public static let isEnabled: Bool = { descriptor >= 0 }()

    /// 診断専用の出力先。**`/dev/stderr` を開き直し、`F_SETNOSIGPIPE` だけを立てた fd**。
    ///
    /// ここに辿り着くまでに 3 つ外したので、**実測した事実**を残す
    /// (macOS 26 / Apple Silicon で `fcntl` の戻り値を直接確認):
    ///
    /// 1. **`signal(SIGPIPE, SIG_IGN)` は使えない。** プロセス全体のシグナル処理を
    ///    書き換えてしまう。`KildeCore` はライブラリで、GUI や将来の埋め込み先の
    ///    シグナル状態を勝手に触ってよい立場にない (cubic の指摘)
    /// 2. **`O_NONBLOCK` は使えない。** `dup` でも `/dev/stderr` の開き直しでも、
    ///    **開いたファイル記述は fd 2 と共有される** — 実測で再オープンした fd と
    ///    元の stderr が**どちらも `flags=0xd`** になった。つまり非ブロッキングを
    ///    立てると**プロセスの stderr そのもの**が非ブロッキングになり、
    ///    `FileHandle.standardError.write` が `EAGAIN` で ObjC 例外を投げて
    ///    **録画が 0 バイトで壊れる** (実際に壊した)
    /// 3. **`O_NONBLOCK` は SIGPIPE を抑えない。** 読み手が消えた pipe では
    ///    フラグに関係なく SIGPIPE が飛ぶ。fd 単位の抑止は **`F_SETNOSIGPIPE`**
    ///
    /// 残った手は `F_SETNOSIGPIPE`。実測: 読み手を閉じた pipe への `write` が
    /// SIGPIPE を飛ばさず `EPIPE` (errno 32) を返した。
    ///
    /// **これも記述を共有するので、元の stderr にも及ぶ** — 実測で診断 fd を開いた後、
    /// 元 stderr の `F_GETNOSIGPIPE` が 0 から 1 に変わった。ただし影響の向きは
    /// **安全側**で (SIGPIPE で落ちにくくなるだけ)、`O_NONBLOCK` のように
    /// `write` が `EAGAIN` で失敗して ObjC 例外を投げる類の害は無い。
    /// **診断が有効なときだけ**の変化であり、既定では `open` 自体を行わない。
    ///
    /// **満杯の pipe でブロックしうることは解消できていない。** 非ブロッキングにする
    /// 手段が上記 2 の理由で使えないため。診断を有効にするときは
    /// **stderr をファイルへ向けるか、読み続けられる先へ繋ぐこと** — 詰まると
    /// SCK のコールバックが止まり、`suspendDelivery()` の完了待ちごと
    /// ファイナライズが止まる (CodeRabbit の指摘。issue #95 が直している症状そのもの)。
    ///
    /// 開き直しに失敗したら診断を諦める (`-1` = 無効)
    private static let descriptor: Int32 = {
        guard ProcessInfo.processInfo.environment["KILDE_TRACE_STOP"] == "1" else { return -1 }
        // **`O_NONBLOCK` を立てない** (上記 2)。記述を共有するので元の stderr を壊す
        let fd = open("/dev/stderr", O_WRONLY | O_APPEND)
        guard fd >= 0 else { return -1 }
        // **SIGPIPE はこの fd でだけ抑止する** (上記 3)。失敗しても診断は続ける —
        // その場合 `2>&1 | head` のような使い方で死にうるが、既定では無効なので
        // 通常の録画には影響しない
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return fd
    }()

    /// 最初の `mark()` を基準にした相対秒。`Date` ではなく単調時計を使う。
    ///
    /// **「プロセス起動からの経過」にはできない。** Swift の型プロパティは遅延初期化
    /// されるため、`static let origin = DispatchTime.now()` と書くと **初回の `mark()` が
    /// 呼ばれた瞬間**に初期化される。その結果 `origin` が直前に読んだ `now()` より後に
    /// なり、`UInt64` の減算がアンダーフローして `Swift runtime failure: arithmetic
    /// overflow` で trap する (実測: 初回呼び出しで必ず SIGTRAP。しかも trap は
    /// `Recorder.run()` の catch も defer も飛ばすので、**0 バイトの未完了ファイルが
    /// 残った** — DESIGN.md §5 の最重要要件が破れる)。
    ///
    /// 基準が「最初の通過点」でも目的は果たせる。見たいのは通過点**どうし**の間隔で、
    /// プロセス起動からの絶対経過ではないため。
    private static let origin = DispatchTime.now()

    private static let lock = NSLock()

    /// 通過点を刻む。無効時は即座に返る (文字列の組み立てもしない)
    public static func mark(_ label: @autoclosure () -> String) {
        guard isEnabled else { return }
        // **減算の向きを問わない形にする。** 上記のとおり now < origin になりうるうえ、
        // 仮に origin を先に確定させても、符号なし減算を素で書けば同じ罠が将来また出る。
        // 診断コードがプロダクトをクラッシュさせることは、どんな理由があっても許容しない
        let now = DispatchTime.now().uptimeNanoseconds
        let base = origin.uptimeNanoseconds
        let elapsedNanos = now >= base ? now - base : 0
        let seconds = Double(elapsedNanos) / 1_000_000_000
        let line = String(format: "[stop-trace] %8.3f %@\n", seconds, label())
        // 複数のキュー (SCK の outQueue / マイクの queue / セッション Task) から
        // 同時に呼ばれるので、行が混ざらないよう直列化する。
        //
        // **書き込み先はブロッキングな fd** (`descriptor` の doc 参照 —
        // `O_NONBLOCK` は記述を共有するせいで使えず、立てると元の stderr まで
        // 非ブロッキングになって録画を壊す)。したがって **`EAGAIN` は起きない**。
        //
        // `handleAudio` はサンプルごとに呼ばれるため、**stderr が詰まればここで
        // ブロックし、SCK のコールバックごとファイナライズが止まる** — 診断を
        // 有効にするときは stderr をファイルへ向けること。読み手が消えた場合だけは
        // `F_SETNOSIGPIPE` により `EPIPE` が返るので、死なずに 1 行落とすだけで済む。
        //
        // `FileHandle.write` を使わないのは、失敗時に ObjC 例外を投げるため
        // (Swift では捕まえられず落ちる)
        lock.lock()
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        lock.unlock()
    }
}
