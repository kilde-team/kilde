#!/bin/bash
# A/V ドリフト計測 (issue #3)
#
# 長時間の録画で、映像 / system 音声 / マイクのずれが累積しないかを測る。
# drift-marker (点滅 + ビープを一定間隔で出すウィンドウ) を収録し、drift-analyze で
# マーカーごとのずれと経時変化 (ドリフト) を出す。手順と結果の記録は SPIKE-NOTES F-E。
#
# 使い方:
#   scripts/drift-test.sh [録画時間 (既定 15m)] [マーカー間隔秒 (既定 30)] [separate|mixed|both (既定 both)]
#   例: scripts/drift-test.sh            # 15 分 × separate と mixed の 2 回 (計 ~31 分)
#       scripts/drift-test.sh 1m 5 separate   # 手順の確認用 (短時間)
#       MIC="device:EMEET" scripts/drift-test.sh   # マイクを明示する (kilde rec --audio の値)
#
# 前提:
#   - 画面収録・マイクの権限 (先に `kilde doctor`)、スピーカー音量が 0 / ミュートでないこと
#     (マイクはスピーカーから回り込んだビープを拾う。イヤホン・ヘッドホンでは計測できない)
#   - MacBook を閉じて外部ディスプレイで使っている (クラムシェル) と内蔵マイクは無音になる。
#     その場合は MIC="device:<Webカメラ等のマイク名>" で聞こえるマイクを指定する (kilde devices で確認)
#   - 計測中は KildeDriftMarker ウィンドウを他のウィンドウで隠さない。静かな環境で行う
#   - 1 回の録画は最大で録画時間 + 30 秒ほどかかる。途中で Mac をスリープさせない

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KILDE="$ROOT/.build/debug/kilde"
DUR="${1:-15m}"
INTERVAL="${2:-30}"
MODE="${3:-both}"
MIC="${MIC:-mic}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kilde-drift.XXXXXX")"
MARKER_PID=""
REC_PID=""
INTERRUPTED=0

cleanup() {
    # 想定外の終了経路でも録画を放置しない (安全停止を依頼してファイナライズを待つ)
    if [ -n "$REC_PID" ]; then kill -INT "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null; fi
    [ -n "$MARKER_PID" ] && kill "$MARKER_PID" 2>/dev/null
    echo ""
    echo "作業ディレクトリ (録画・ログ・解析結果): $WORK"
}
trap cleanup EXIT

# Ctrl+C / SIGTERM / SIGHUP は録画中の kilde rec に SIGINT として転送し、ファイナライズを待ってから終わる
# (転送しないと、ラッパーだけが止まって録画が孤児として走り続ける)。
# kilde は停止シグナルで正常終了 (exit 0) するので、フラグを立てておかないと中断した録画を解析し、
# both では次のモードの録画まで始めてしまう。Ctrl+C では端末からも kilde に SIGINT が届くが、
# Recorder.stop() は 2 回目以降を無視するので二重に届いても問題ない
stop_rec() {
    INTERRUPTED=1
    [ -n "$REC_PID" ] && kill -INT "$REC_PID" 2>/dev/null
}
trap stop_rec INT TERM HUP

# プロセスが生きているか。終了してまだ回収されていないゾンビにも kill -0 は成功するので、ps で状態を見る
alive() {
    [ -n "$1" ] && [ -n "$(ps -o stat= -p "$1" 2>/dev/null | grep -v Z)" ]
}

case "$MODE" in separate|mixed|both) ;; *) echo "モードは separate / mixed / both"; exit 2 ;; esac

# マーカー間隔は drift-analyze の探索窓 (−0.5〜+1.0 秒、幅 1.5 秒) より長くないと、
# 欠落したマーカーの代わりに隣のマーカーのビープを拾ってしまう。
# 上限は有限性の確認 (桁の多い数字は awk で inf になる。macOS の awk は nan / inf の比較が
# 当てにならないので、上限との大小で弾く)
if ! awk -v v="$INTERVAL" 'BEGIN { exit !(v ~ /^([0-9]+[.]?[0-9]*|[.][0-9]+)$/ && v + 0 > 1.5 && v + 0 < 1e9) }'; then
    echo "マーカー間隔は 1.5 秒より大きい数値で指定してください: $INTERVAL"
    exit 2
fi

# 録画時間を秒にする (マーカーアプリの寿命に使う)。kilde の parseDuration と同じく末尾 s/m/h と
# 小数 (例: 1.5m) を受け付ける。bash の $(( )) は整数しか扱えないので awk で計算する
SECS="$(awk -v d="$DUR" 'BEGIN {
    m = 1; u = substr(d, length(d), 1)
    if (u == "s" || u == "m" || u == "h") { d = substr(d, 1, length(d) - 1); m = (u == "h") ? 3600 : (u == "m") ? 60 : 1 }
    if (d !~ /^([0-9]+[.]?[0-9]*|[.][0-9]+)$/ || d + 0 <= 0 || d * m >= 1e9) exit 1
    print d * m
}')" || { echo "録画時間は 15m / 90s / 1.5m のように指定してください: $DUR"; exit 2; }
# マーカーは録画より 30 秒長く生かしておく (録画の途中で消えると --window の収録が止まる)
LIFETIME="$(awk -v s="$SECS" 'BEGIN { print s + 30 }')"
# 解析にはマーカーが 2 個以上要る。録画時間が間隔の 2 倍未満だと、録画を終えてから解析で失敗するので先に止める
if ! awk -v s="$SECS" -v i="$INTERVAL" 'BEGIN { exit !(s >= 2 * i) }'; then
    echo "録画時間 ($DUR) はマーカー間隔 (${INTERVAL}s) の 2 倍以上にしてください (解析にマーカーが 2 個以上必要)"
    exit 2
fi

[ -x "$KILDE" ] || { echo "先に swift build を実行してください ($KILDE がありません)"; exit 1; }
# 保存先の既定値は -o で明示するので影響しないが、音声ソース等は引数で固定している
unset KILDE_OUTPUT_DIR

echo "コンパイル中..."
swiftc -O "$ROOT/scripts/drift-marker.swift" -o "$WORK/drift-marker" 2>"$WORK/build.log" \
    && swiftc -O "$ROOT/scripts/drift-analyze.swift" -o "$WORK/drift-analyze" 2>>"$WORK/build.log" \
    || { echo "コンパイルに失敗: $WORK/build.log"; exit 1; }

run_one() { # run_one <separate|mixed>
    local tracks="$1"
    local out="$WORK/drift-$tracks.mov"
    echo ""
    echo "== $tracks: ${DUR} 録画 (マーカー ${INTERVAL}s 間隔、マイク: $MIC) =="
    "$WORK/drift-marker" "$INTERVAL" "$LIFETIME" > "$WORK/marker-$tracks.log" 2>&1 &
    MARKER_PID=$!
    # ウィンドウが表示されてから --window で解決させる。固定の sleep だと起動が遅いときに解決に失敗するので、
    # drift-marker の "ready" を最大 15 秒待つ (マーカーの寿命の余裕 30 秒の内側に収める)
    local waited=0
    until grep -q '^ready' "$WORK/marker-$tracks.log" 2>/dev/null; do
        if ! alive "$MARKER_PID"; then
            echo "drift-marker が起動直後に終了しました: $WORK/marker-$tracks.log"
            tail -5 "$WORK/marker-$tracks.log"
            wait "$MARKER_PID" 2>/dev/null; MARKER_PID=""
            return 1
        fi
        [ $INTERRUPTED -eq 1 ] && return 130
        [ $waited -ge 30 ] && { echo "drift-marker のウィンドウが 15 秒以内に表示されませんでした"; return 1; }
        sleep 0.5; waited=$((waited + 1))
    done
    sleep 1   # 表示の直後は画面収録の一覧 (SCShareableContent) への反映が遅れうるので少し余裕を置く
    [ $INTERRUPTED -eq 1 ] && return 130
    # kilde rec はバックグラウンドで起動し、終わるまで 1 秒ごとに見張る。フォアグラウンドで実行すると、
    # ラッパーが受けたシグナルを録画終了まで処理できず、kilde に転送できないため。見張りの間にやること:
    # - 中断中は SIGINT を送り続ける。kilde がシグナルハンドラを登録する前 (起動直後) に届いた SIGINT は
    #   失われる (バックグラウンドのジョブは SIGINT を無視した状態で起動する) ので、1 回では足りない。
    #   Recorder.stop() は 2 回目以降を無視するので送り続けても問題ない
    # - マーカーが落ちたら (ビープの再生失敗など) その録画はマーカーが欠けるので、録画を止めて失敗にする。
    #   録画を最後まで (最大 15 分) 続けてから捨てることになるのを避けるため
    "$KILDE" rec --window KildeDriftMarker --audio system --audio "$MIC" --audio-tracks "$tracks" \
        --duration "$DUR" --output "$out" > "$WORK/rec-$tracks.log" 2>&1 &
    REC_PID=$!
    local marker_died=0
    while alive "$REC_PID"; do
        alive "$MARKER_PID" || marker_died=1
        if [ $INTERRUPTED -eq 1 ] || [ $marker_died -eq 1 ]; then kill -INT "$REC_PID" 2>/dev/null; fi
        sleep 1
    done
    local rc=0
    wait "$REC_PID"; rc=$?
    REC_PID=""
    # 見張りの隙間で落ちた場合も含め、録画終了時点でマーカーが居なければ失敗にする
    alive "$MARKER_PID" || marker_died=1
    kill "$MARKER_PID" 2>/dev/null; wait "$MARKER_PID" 2>/dev/null; MARKER_PID=""
    if [ $INTERRUPTED -eq 1 ]; then
        echo "中断しました (kilde rec exit=$rc)。途中までの録画の解析と、以降のモードは行いません"
        echo "途中までを解析する場合: $WORK/drift-analyze \"$out\" $INTERVAL"
        return 130
    fi
    if [ $marker_died -eq 1 ]; then
        echo "drift-marker が録画中に終了したため、録画を止めました (kilde rec exit=$rc): $WORK/marker-$tracks.log"
        tail -5 "$WORK/marker-$tracks.log"
        return 1
    fi
    if [ $rc -ne 0 ]; then
        echo "kilde rec が失敗しました (exit=$rc): $WORK/rec-$tracks.log"
        tail -5 "$WORK/rec-$tracks.log"
        return 1
    fi
    grep "first-PTS" "$WORK/rec-$tracks.log"
    "$WORK/drift-analyze" "$out" "$INTERVAL" | tee "$WORK/result-$tracks.txt"
    # パイプラインの終了コードは tee のものになるので、解析の失敗 (マーカー 2 個未満・読み取り失敗) を
    # PIPESTATUS で拾う。拾わないと失敗した計測が成功扱いになる
    local -a analyze_status=("${PIPESTATUS[@]}")
    if [ "${analyze_status[0]}" -ne 0 ] || [ "${analyze_status[1]}" -ne 0 ]; then
        echo "解析または解析結果の保存に失敗しました (drift-analyze=${analyze_status[0]}, tee=${analyze_status[1]})"
        return 1
    fi
    # separate の audio[1] (マイク) が完全に無音なら、計測以前に入力が取れていない
    if [ "$tracks" = "separate" ] && grep -q '^audio\[1\]: 最大ピーク 0\.000' "$WORK/result-$tracks.txt"; then
        echo ""
        echo "WARNING: マイクのトラックが完全に無音です。既定の入力デバイスが音を拾えていません"
        echo "         (クラムシェル時の内蔵マイク等)。MIC=\"device:<名前>\" で別のマイクを指定してください"
    fi
}

status=0
for tracks in separate mixed; do
    [ "$MODE" = "$tracks" ] || [ "$MODE" = "both" ] || continue
    run_one "$tracks" || status=1
    # 中断されたら以降のモードは行わない
    [ $INTERRUPTED -eq 1 ] && exit 130
done
exit $status
