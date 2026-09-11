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

cleanup() {
    [ -n "$MARKER_PID" ] && kill "$MARKER_PID" 2>/dev/null
    echo ""
    echo "作業ディレクトリ (録画・ログ・解析結果): $WORK"
}
trap cleanup EXIT

case "$MODE" in separate|mixed|both) ;; *) echo "モードは separate / mixed / both"; exit 2 ;; esac

# 録画時間を秒にする (マーカーアプリの寿命に使う。kilde 側の解釈は parseDuration)
case "$DUR" in
    *h) SECS=$(( ${DUR%h} * 3600 )) ;;
    *m) SECS=$(( ${DUR%m} * 60 )) ;;
    *s) SECS=${DUR%s} ;;
    *)  SECS=$DUR ;;
esac

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
    "$WORK/drift-marker" "$INTERVAL" $(( SECS + 30 )) > "$WORK/marker-$tracks.log" 2>&1 &
    MARKER_PID=$!
    sleep 2   # ウィンドウが出てから --window で解決させる
    "$KILDE" rec --window KildeDriftMarker --audio system --audio "$MIC" --audio-tracks "$tracks" \
        --duration "$DUR" --output "$out" > "$WORK/rec-$tracks.log" 2>&1
    local rc=$?
    kill "$MARKER_PID" 2>/dev/null; wait "$MARKER_PID" 2>/dev/null; MARKER_PID=""
    if [ $rc -ne 0 ]; then
        echo "kilde rec が失敗しました (exit=$rc): $WORK/rec-$tracks.log"
        tail -5 "$WORK/rec-$tracks.log"
        return 1
    fi
    grep "first-PTS" "$WORK/rec-$tracks.log"
    "$WORK/drift-analyze" "$out" "$INTERVAL" | tee "$WORK/result-$tracks.txt"
    # separate の audio[1] (マイク) が完全に無音なら、計測以前に入力が取れていない
    if [ "$tracks" = "separate" ] && grep -q '^audio\[1\]: 最大ピーク 0\.000' "$WORK/result-$tracks.txt"; then
        echo ""
        echo "WARNING: マイクのトラックが完全に無音です。既定の入力デバイスが音を拾えていません"
        echo "         (クラムシェル時の内蔵マイク等)。MIC=\"device:<名前>\" で別のマイクを指定してください"
    fi
}

status=0
if [ "$MODE" = "separate" ] || [ "$MODE" = "both" ]; then run_one separate || status=1; fi
if [ "$MODE" = "mixed" ] || [ "$MODE" = "both" ]; then run_one mixed || status=1; fi
exit $status
