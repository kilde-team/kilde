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
        ProcessInfo.processInfo.environment["KILDE_TRACE_STOP"] == "1"
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
        // 同時に呼ばれるので、行が混ざらないよう直列化する
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}
