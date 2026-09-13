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
    public static let isEnabled: Bool = {
        let on = ProcessInfo.processInfo.environment["KILDE_TRACE_STOP"] == "1"
        // **SIGPIPE を無視する (cubic の指摘)。** 下で生の `write(2)` を使うため、
        // stderr が**読み手の消えた pipe** (`kilde rec … 2>&1 | head` など) だと
        // SIGPIPE が飛び、既定の処理は**プロセス終了**。`mark()` はサンプルごとに
        // 呼ばれるので、録画中にファイナライズを飛ばして死ぬ — このファイル自身が
        // 掲げる「診断コードがプロダクトをクラッシュさせない」原則と、
        // 「Ctrl+C でも必ずファイナライズ」(DESIGN.md §5) の両方に反する。
        //
        // 旧実装の `FileHandle.standardError.write` は Foundation が SIGPIPE を
        // 無視する前提に乗っていた。`FileHandle` をやめた以上、自分で無視する
        if on { signal(SIGPIPE, SIG_IGN) }
        return on
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
        // **`write(2)` を直接使い、FileHandle を使わない (cubic の指摘)。**
        // `handleAudio` はサンプルごとに呼ばれる (実測 3 秒で約 160 回)。stderr が
        // **誰も読んでいない pipe** だと、満杯になった時点で書き込みがブロックし、
        // **キャプチャのコールバックがそこで止まる**。すると `suspendDelivery()` が
        // その完了を待ち続け、**ファイナライズまで止まる** — 診断コードが
        // issue #95 で直そうとしている症状そのものを作ってしまう。
        //
        // 戻り値は捨てる (部分書き込みで診断の 1 行が欠けても、録画を止めるよりは軽い)。
        // `FileHandle.write` は失敗時に ObjC 例外を投げる (Swift では捕まえられず落ちる)
        // という別の問題もあり、そちらも同時に避けられる。
        //
        // **満杯の pipe でブロックすること自体は避けられない (cubic の指摘)。**
        // ブロッキング fd では戻り値を捨ててもブロックし続ける (部分書き込みが起きるのは
        // 実質 EINTR のとき)。**誰も読まない pipe へ大量に出せば、ここで止まる** —
        // その場合キャプチャのコールバックが止まり、`suspendDelivery()` がその完了を
        // 待ってファイナライズまで止まる。診断を有効にするときは
        // **stderr をファイルへ向けるか、読み続けられる先へ繋ぐこと**
        lock.lock()
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer in
            write(STDERR_FILENO, buffer.baseAddress, buffer.count)
        }
        lock.unlock()
    }
}
