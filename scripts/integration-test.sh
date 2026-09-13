#!/bin/bash
# kilde 統合テスト (ローカル実行用)
#
# 使い方:
#   scripts/integration-test.sh
#
# 前提:
#   - 画面収録・マイクの権限が付与済みであること (未許可なら先に `kilde doctor`)
#   - 音量が 0 (ミュート) だと音声シナリオが失敗します
#
# 内容: kilde CLI の全コマンドを実際に録画しながら動かし、
#       出力ファイルのトラック構成と RMS を機械検証する。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KILDE="$ROOT/.build/debug/kilde"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kilde-it.XXXXXX")"
VOICE="$WORK/test-voice.aiff"
SOUNDAPP="$WORK/soundapp"
DUR=6          # 各録画の長さ (秒)
DELAY=2        # 録画開始から音声再生までの遅延 (秒)

PASS=0; FAIL=0; SKIP=0
MONITOR_SET_UP=0
SOUNDAPP_PID=""
GUI_PID=""
T21_PID=""
T23_HOLDER_PID=""
T23_RUN_PID=""
T24_DEVICES_PID=""
T25_PID=""

# ---- 停止ヘルパ (issue #101) --------------------------------------------------
# 「SIGINT を送り直す → SIGTERM → SIGKILL」の梯子は、このスクリプトの 8 箇所に
# コピーされていた。猶予の回数だけが違い、**理由のある違いと、単にコピー元が違った
# だけの違いが混ざっていた**ため、理由のあるほうを型にしてまとめる。
#
# 呼び出し側が決めるのは「その kilde が録画しているかどうか」だけにする:
#
#   recording — 録画中でありうる (#80 の縮退による即時録画も含む)。SIGKILL すると
#               安全停止とファイナライズを飛ばして**未完了ファイルを残す** —
#               「Ctrl+C でもファイルは必ずファイナライズされる」(DESIGN.md §5 の
#               最重要要件) に正面から反するので、INT の猶予を長く取る
#   waiting   — ホットキー待機など、まだ 1 バイトも書いていない。取りこぼして困るのは
#               ホットキーの排他登録を孤児が握り続けることだけなので、猶予は半分で足りる
#
# **2 つの関数に分けてあるのは意味がある。一方に寄せないこと:**
#
#   stop_kilde — INT を終了まで**送り直す**。停止は非同期なうえ、
#                installStopSignalHandler の設置前に届いた SIGINT は失われうるため。
#                判定に使われない後始末 (EXIT trap・異常路の回収) 専用
#   await_stop — INT を**送らない**。テスト自身が刺激として INT を 1 回だけ送った門
#                (T13 / T22) 用。ここで送り直すと、**「最初の SIGINT が失われる」
#                回帰 (issue #67) を 2 通目が救ってしまい、門が緑のまま素通りする**。
#                終了を待ち、猶予を超えたぶんだけ TERM → KILL で回収する
#
# **T10 は意図的に寄せていない (issue #101)。** あそこは梯子を持たず
# `kill -INT` + `wait` の 3 行で、そもそも重複の当事者ではない。ヘルパを当てると
# 現在安定している門に 10 秒の期限が新たに乗り、ファイナライズが伸びた回を
# KILL (137) で落とす — 直したい重複と引き換えに新種の flake を作ることになる
#
# どちらも `wait` まで済ませ、結果を STOP_EXIT / STOP_BY_INT に置く
# (bash 3.2 には連想配列も nameref も無いのでグローバルで返す)。
STOP_GRACE_RECORDING=20   # ×0.5 秒 = 10 秒。ファイナライズを待ち切るための猶予
STOP_GRACE_WAITING=10     # ×0.5 秒 = 5 秒
STOP_EXIT=-1              # 直前の停止で回収した終了コード
STOP_BY_INT=0             # TERM/KILL へ昇格せずに終わったか (門の判定に使う)

stop_grace_for() {  # stop_grace_for <recording|waiting>
    case "$1" in
        recording) echo "$STOP_GRACE_RECORDING" ;;
        waiting)   echo "$STOP_GRACE_WAITING" ;;
        # 役割名の打ち間違いを黙って「短いほう」に倒すと、録画中のプロセスを
        # 早すぎる KILL で潰して未完了ファイルを残す。長いほうへ倒して警告する
        *) echo "WARNING: stop: 未知の役割 '$1' — recording として扱います" >&2
           echo "$STOP_GRACE_RECORDING" ;;
    esac
}

force_stop() {  # force_stop <pid> — INT で終わらなかったものを TERM → KILL で回収
    local pid="${1:-}"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    return 0
}

stop_kilde() {  # stop_kilde <pid> <recording|waiting> — INT を送り直して確実に止める
    local pid="${1:-}" role="${2:-recording}" tries i
    STOP_EXIT=-1
    STOP_BY_INT=0
    [ -n "$pid" ] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        tries=$(stop_grace_for "$role")
        for i in $(seq 1 "$tries"); do
            kill -INT "$pid" 2>/dev/null
            if ! kill -0 "$pid" 2>/dev/null; then STOP_BY_INT=1; break; fi
            sleep 0.5
        done
        force_stop "$pid"
    else
        STOP_BY_INT=1
    fi
    # 既に死んでいても必ず `wait` する。**送っただけでは終了を確認できず、孤児 (PPID=1)
    # として残る。** 開発中に実際に踏んだ — 孤児の `devices` が `flock` を 8 分間握り、
    # その間の計測 25 回がすべてロック待ちで詰まって無意味になった
    wait "$pid" 2>/dev/null
    STOP_EXIT=$?
    return 0
}

await_stop() {  # await_stop <pid> <recording|waiting> — 自分で送った INT の結果を待つ
    local pid="${1:-}" role="${2:-recording}" tries i
    STOP_EXIT=-1
    STOP_BY_INT=0
    [ -n "$pid" ] || return 0
    tries=$(stop_grace_for "$role")
    for i in $(seq 1 "$tries"); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        force_stop "$pid"
    else
        STOP_BY_INT=1
    fi
    wait "$pid" 2>/dev/null
    STOP_EXIT=$?
    return 0
}

cleanup() {
    if [ "$MONITOR_SET_UP" = "1" ]; then
        "$KILDE" audio monitor teardown >/dev/null 2>&1 && echo "[cleanup] 既定出力を復元しました"
    fi
    [ -n "$SOUNDAPP_PID" ] && kill "$SOUNDAPP_PID" 2>/dev/null
    # T17 の .app 版 soundapp も同じくどの分岐で失敗しても残さない
    [ -n "${EXCL_PID:-}" ] && kill "$EXCL_PID" 2>/dev/null
    if [ -n "${CONFIG:-}" ]; then
        rm -f "$CONFIG"
    fi
    # T11 の GUI プロセスもどの分岐で失敗しても残さない
    [ -n "$GUI_PID" ] && kill "$GUI_PID" 2>/dev/null
    # T22 の録画プロセスも同様に残さない。**録画中でありうる** — 準備中の SIGINT が
    # 間に合わなければ T10 と同じ通常録画に解けるので、ファイナライズを待つ側で止める
    # (以前はここだけ INT を挟まず TERM から始めていた。同じ安全停止ハンドラに繋がる
    #  ので結果は同じだが、猶予 1 秒ではファイナライズを待ち切れなかった)
    stop_kilde "${T22_PID:-}" recording
    T22_PID=""
    # T21 の self-test はバックグラウンド起動なので、スイートを途中で止めたときに
    # KildeGUI が残る。録画はしていないので安全停止の待ちは要らない
    [ -n "$T21_PID" ] && kill "$T21_PID" 2>/dev/null
    # T24 の併走役 (devices の列挙) も残さない。**kill して終わりにせず `wait` する** —
    # 送っただけでは終了を確認できず、孤児 (PPID=1) として残る。孤児の devices は
    # `flock` を保持し続けるので、以後の `rec` がすべて「15 秒以内に空きませんでした」で
    # 失敗する。**開発中に実際に踏んだ** — 孤児が 8 分間ロックを握り、その間の計測
    # 25 回がすべてロック待ちで詰まって無意味になった。
    # 録画はしていないので安全停止の猶予は要らず、KILL してから回収する。
    #
    # **ここは stop_kilde に寄せない (issue #101)。** ヘルパは「録画しているか」で
    # 猶予を選ぶが、`devices` は録画もシグナル処理もしない — 安全停止ハンドラを
    # 持たないので INT を送り直すだけ無駄に 5〜10 秒待つことになる。
    # 失うものが無いぶん、即 KILL が正しい
    if [ -n "${T24_DEVICES_PID:-}" ]; then
        kill -KILL "$T24_DEVICES_PID" 2>/dev/null
        wait "$T24_DEVICES_PID" 2>/dev/null
    fi
    T24_DEVICES_PID=""
    # T25 の待機役も残さない。**ホットキーを握ったまま残ると次回以降のスイートが壊れる** —
    # T23 の占有役と同じ理由 (排他登録なので孤児が同じキーを持つと登録できない)。
    #
    # **KILL で済ませてはいけない。** 他プロセスが f8 を握っていると #80 の縮退で
    # **即時録画に入る**ので、この PID が AVAssetWriter を書いている最中でありうる。
    # そこへ SIGKILL を送ると安全停止とファイナライズを飛ばし、**未完了ファイルを残す**
    # (「Ctrl+C でも必ずファイナライズ」= DESIGN.md §5 の最重要要件に反する)。
    # 終了を確認するまで SIGINT を送り直してから強制する。
    # **役割は waiting ではなく recording。** 名前のうえでは「待機役」だが、
    # 上のとおり縮退して**録画している**可能性があり、ファイナライズには時間がかかる。
    # waiting の猶予 (5 秒) で TERM/KILL に進むと、このコメントが防ぐと言っている
    # 未完了ファイルがまさに残る
    stop_kilde "${T25_PID:-}" recording
    T25_PID=""
    # T23 の占有役 (rec --hotkey の待機) も残さない。**残すと次回以降のスイートが壊れる** —
    # ホットキーは排他登録なので、孤児が同じキーを握ったままだと T23 の占有役が登録できず、
    # 以後ずっと「占有役が待機に入れませんでした」で落ち続ける (開発中に実際に踏んだ)。
    # **SIGINT を 1 回送って待たずに抜けない** — 停止は非同期なうえ、
    # installStopSignalHandler の設置前に届いた SIGINT は失われうるので、
    # 終了を確認するまで送り直し、期限を超えたら TERM/KILL で強制する。
    # **こちらは waiting でよい** — 占有役はキーを握って待つだけで、何も書いていない
    stop_kilde "${T23_HOLDER_PID:-}" waiting
    T23_HOLDER_PID=""
    # T23 のサブ実行 (rec 本体) も回収する。待機回帰なら同じキーを、録画中なら
    # 録画デバイスと未完了ファイルを残すため、占有役だけ止めても足りない
    # **占有役と同じく SIGINT を終了まで送り直す。** こちらは実際に録画しているので、
    # installStopSignalHandler の設置前に届いた SIGINT を取りこぼしたまま KILL すると
    # Recorder.stop() が走らず未完了ファイルが残る (「Ctrl+C でも必ずファイナライズ」に反する)
    stop_kilde "${T23_RUN_PID:-}" recording
    T23_RUN_PID=""
    # T15 の録画は 12 秒走る。スイートを途中で止めたときに録画だけ残さない
    # (安全停止を送ってファイナライズを待つ)。**以前はここだけ INT を 1 回送って
    # 無期限に `wait` していた** — 停止しない回帰があると後始末そのものが固まり、
    # スイートが無言で止まる。ヘルパなら猶予を超えた時点で TERM/KILL へ進む
    stop_kilde "${T15_PID:-}" recording
    T15_PID=""
    # ディスプレイのスリープ抑止を解除する
    [ -n "${CAFFEINATE_PID:-}" ] && kill "$CAFFEINATE_PID" 2>/dev/null
    echo ""
    echo "作業ディレクトリ (失敗時の調査用に残します): $WORK"
}
trap cleanup EXIT

# テスト中にディスプレイが消灯すると SCK が映像を出さず、T3〜T8 が全滅する
# (2026-09-12 に 2 回観測 — doctor は権限「あり」なのに [sck] displays=0)。
# すでに消えている画面は -dims では起こせないため、-u で 1 度起こしてから
# -dims で保持する二段構えにする (ロック画面は人手で解除してもらう前提)。
# -w $$ で親 (このスクリプト) の終了を caffeinate 自身にも監視させる —
# trap が走らない kill -9 などで死んでも抑止が孤児として残らない
# (scripts/drift-test.sh と同じ形)
caffeinate -u -t 1 2>/dev/null
caffeinate -dims -w $$ >/dev/null 2>&1 &
CAFFEINATE_PID=$!

# T3 / T4b / T5 などは「既定 = system / mixed」を前提にするため、出力先の環境変数は外す。
# 設定と monitor state は作業ディレクトリへ分離し、ユーザーの ~/.kilde には触れない。
unset KILDE_OUTPUT_DIR
export KILDE_CONFIG_DIR="$WORK/config"
CONFIG="$KILDE_CONFIG_DIR/config.json"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '\033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '\033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '\033[33mSKIP\033[0m  %s\n' "$*"; }

# ---- 検証ヘルパ -----------------------------------------------------------

inspect() { "$KILDE" inspect "$1" 2>/dev/null; }

rms_of() {  # 最初のオーディオトラックの RMS
    inspect "$1" | grep -o 'rms=[0-9.]*' | head -1 | cut -d= -f2
}

rms_above() { # rms_above <file> <threshold> — RMS が閾値超か (小数対応)
    awk -v v="$(rms_of "$1")" -v t="$2" 'BEGIN{exit !(v > t)}'
}

video_duration_of() {
    inspect "$1" | grep '^video:' | grep -o 'duration=[0-9.]*' | cut -d= -f2
}

num_between() { # num_between <値> <下限> <上限>
    awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v >= lo && v <= hi)}'
}

# 録画を bg で開始し、音声を鳴らして終了を待つ。出力はログへ。
record_with_voice() { # record_with_voice <ログ名> <kilde rec の引数...>
    local logname="$1"; shift
    "$KILDE" rec --duration "$DUR" "$@" > "$WORK/$logname" 2>&1 &
    REC_PID=$!
    sleep "$DELAY"
    afplay "$VOICE" >/dev/null 2>&1
    wait "$REC_PID"
}

start_soundapp() {
    "$SOUNDAPP" "$VOICE" >/dev/null 2>&1 &
    SOUNDAPP_PID=$!
    sleep 2
}
stop_soundapp() {
    [ -n "$SOUNDAPP_PID" ] && kill "$SOUNDAPP_PID" 2>/dev/null
    wait "$SOUNDAPP_PID" 2>/dev/null
    SOUNDAPP_PID=""
}

# ---- 事前準備 --------------------------------------------------------------

log "ビルド"
if ! (cd "$ROOT" && swift build > "$WORK/build.log" 2>&1); then
    grep "error:" "$WORK/build.log" | head -5
    echo "ビルド失敗 (詳細: $WORK/build.log)"; exit 1
fi
[ -x "$KILDE" ] || { echo "kilde バイナリなし"; exit 1; }

log "テスト音声とテストアプリの準備"
say -o "$VOICE" "これはきるでのとうごうてすとようおんせいです。" \
    || { echo "say で音声生成に失敗"; exit 1; }
swiftc "$ROOT/scripts/soundapp.swift" -o "$SOUNDAPP" 2>/dev/null \
    || { echo "soundapp のコンパイルに失敗"; exit 1; }

# ---- T1: doctor -----------------------------------------------------------

log "T1: doctor (権限・環境診断)"
if "$KILDE" doctor > "$WORK/doctor.txt" 2>&1 \
    && grep -q "画面収録権限: あり" "$WORK/doctor.txt" \
    && grep -q "displays=" "$WORK/doctor.txt"; then
    ok "T1 doctor: 画面権限あり・SCK 列挙成功"
else
    bad "T1 doctor: 失敗 (権限不足?) — $WORK/doctor.txt を参照"
fi

# ---- T2: devices ----------------------------------------------------------

log "T2: devices (機器列挙)"
if "$KILDE" devices > "$WORK/devices.txt" 2>&1 \
    && grep -q "== displays ==" "$WORK/devices.txt" \
    && grep -q "== audio devices ==" "$WORK/devices.txt" \
    && [ "$(grep -c 'id=' "$WORK/devices.txt")" -gt 0 ]; then
    ok "T2 devices: ディスプレイ/ウィンドウ/オーディオ列挙"
else
    bad "T2 devices: 失敗"
fi

# ---- T3: 既定の録画 (画面 + システム音声) ------------------------------------

log "T3: kilde rec (既定) — 画面 + システム音声 (${DUR}s)"
F="$WORK/t3-default.mov"
if record_with_voice t3.log --output "$F"; then
    if grep -q "video: present" <(inspect "$F") && rms_above "$F" 0.005; then
        ok "T3 rec 既定: 映像あり・音声あり (rms=$(rms_of "$F"))"
    else
        bad "T3 rec 既定: ファイル内容が不正 (rms=$(rms_of "$F"))"
    fi
else
    bad "T3 rec 既定: コマンド失敗 — $WORK/t3.log"
fi

# ---- T4: トラック分離 (system + mic の 2 トラック) ----------------------------

log "T4: rec --audio system --audio mic --audio-tracks separate (${DUR}s)"
F="$WORK/t4-separate.mov"
if record_with_voice t4.log --audio system --audio mic --audio-tracks separate --output "$F"; then
    N=$(inspect "$F" | grep -c '^audio\[')
    if [ "$N" -eq 2 ] && grep -q "video: present" <(inspect "$F"); then
        ok "T4 separate: システム/マイクの 2 トラック"
    else
        bad "T4 separate: トラック数=$N (2 が必要)"
    fi
else
    bad "T4 separate: コマンド失敗 — $WORK/t4.log"
fi

# ---- T4b: ミックス (既定) — 1 トラック ---------------------------------------

log "T4b: rec --audio system --audio mic (mixed 既定) (${DUR}s)"
F="$WORK/t4b-mixed.mov"
if record_with_voice t4b.log --audio system --audio mic --output "$F"; then
    N=$(inspect "$F" | grep -c '^audio\[')
    if [ "$N" -eq 1 ] && rms_above "$F" 0.005; then
        ok "T4b mixed: 1 トラックに合成 (rms=$(rms_of "$F"))"
    else
        bad "T4b mixed: トラック数=$N・rms=$(rms_of "$F")"
    fi
else
    bad "T4b mixed: コマンド失敗 — $WORK/t4b.log"
fi

# ---- T5: 録音 (音声のみ) ------------------------------------------------------

log "T5: rec --no-video — SCK 音声のみ (${DUR}s)"
F="$WORK/t5-audio-only.m4a"
if record_with_voice t5.log --no-video --output "$F"; then
    if grep -q "video: absent" <(inspect "$F") && rms_above "$F" 0.005; then
        ok "T5 no-video: 映像なし・音声あり (rms=$(rms_of "$F"))"
    else
        bad "T5 no-video: 内容不正 (rms=$(rms_of "$F"))"
    fi
else
    bad "T5 no-video: コマンド失敗 — $WORK/t5.log"
fi

# ---- T6/T7/T8: ウィンドウ音声スコープ ----------------------------------------

log "T6: rec --window — 収録対象ウィンドウの音は入る (${DUR}s)"
F="$WORK/t6-window-positive.mov"
start_soundapp
if "$KILDE" rec --window SpikeSoundWindow --duration "$DUR" --output "$F" > "$WORK/t6.log" 2>&1; then
    if rms_above "$F" 0.005; then
        ok "T6 window 包含: 対象の音が入る (rms=$(rms_of "$F"))"
    else
        bad "T6 window 包含: 無音 (rms=$(rms_of "$F"))"
    fi
else
    bad "T6 window 包含: コマンド失敗 — $WORK/t6.log"
fi

log "T7: rec --window — 他アプリの音は入らない (${DUR}s)"
# 音を出しているのは soundapp。無関係なウィンドウ (Wallpaper / ゴミ箱) を収録する
UNRELATED=""
if "$KILDE" devices 2>/dev/null | grep -q "Wallpaper"; then
    UNRELATED="Wallpaper"
elif "$KILDE" devices 2>/dev/null | grep -q "ゴミ箱"; then
    UNRELATED="ゴミ箱"
fi
F="$WORK/t7-window-negative.mov"
if [ -n "$UNRELATED" ]; then
    if "$KILDE" rec --window "$UNRELATED" --duration "$DUR" --output "$F" > "$WORK/t7.log" 2>&1; then
        RMS=$(rms_of "$F")
        if awk -v v="${RMS:-1}" 'BEGIN{exit !(v < 0.00005)}'; then
            ok "T7 window 除外: 他アプリの音が完全除外 (rms=$RMS)"
        else
            bad "T7 window 除外: 音が混入した (rms=$RMS)"
        fi
    else
        bad "T7 window 除外: コマンド失敗 — $WORK/t7.log"
    fi
else
    skip "T7 window 除外: 無関係ウィンドウが見つからない"
fi
stop_soundapp

log "T8: rec --no-video --window — 特定アプリの音声のみ (${DUR}s)"
F="$WORK/t8-audio-window.m4a"
start_soundapp
if "$KILDE" rec --no-video --window SpikeSoundWindow --duration "$DUR" --output "$F" > "$WORK/t8.log" 2>&1; then
    if grep -q "video: absent" <(inspect "$F") && rms_above "$F" 0.005; then
        ok "T8 audio+window: アプリスコープ音声のみ (rms=$(rms_of "$F"))"
    else
        bad "T8 audio+window: 内容不正 (rms=$(rms_of "$F"))"
    fi
else
    bad "T8 audio+window: コマンド失敗 — $WORK/t8.log"
fi
stop_soundapp

# ---- T9: BlackHole ループバック ----------------------------------------------

log "T9: audio monitor + device 録音 — マルチ出力経由 (${DUR}s)"
# 導入されている BlackHole の実名を取り出す (16ch 等のvariantでも壊れないように)
BH_NAME=$("$KILDE" devices 2>/dev/null | grep '←BlackHole' | head -1 | sed -n 's/.*"\([^"]*\)".*/\1/p')
if [ -n "$BH_NAME" ]; then
    if "$KILDE" audio monitor setup > "$WORK/t9-setup.txt" 2>&1; then
        MONITOR_SET_UP=1
        if "$KILDE" audio monitor status 2>/dev/null | grep -q "←kilde Monitor"; then
            ok "T9 monitor setup: kilde Monitor が既定出力に"
        else
            bad "T9 monitor setup: 既定出力になっていない"
        fi
        F="$WORK/t9-blackhole.m4a"
        # 名前解決 (device:<検出名>) も兼ねる
        "$KILDE" rec --no-video --audio "device:$BH_NAME" --duration "$DUR" --output "$F" > "$WORK/t9.log" 2>&1 &
        REC_PID=$!
        sleep "$DELAY"
        afplay "$VOICE" >/dev/null 2>&1
        wait "$REC_PID"
        if rms_above "$F" 0.005; then
            ok "T9 BlackHole ループバック: 録音成功 (rms=$(rms_of "$F"))"
        else
            bad "T9 BlackHole ループバック: 無音 (rms=$(rms_of "$F"))"
        fi
        if "$KILDE" audio monitor teardown > "$WORK/t9-teardown.txt" 2>&1; then
            MONITOR_SET_UP=0
            if "$KILDE" audio monitor status 2>/dev/null | grep "default output:" | grep -qv "kilde"; then
                ok "T9 monitor teardown: 既定出力を復元"
            else
                bad "T9 monitor teardown: 既定出力が復元されていない"
            fi
        else
            bad "T9 monitor teardown: 失敗"
        fi
    else
        bad "T9 monitor setup: 失敗 — $WORK/t9-setup.txt"
    fi
else
    skip "T9 BlackHole ループバック: BlackHole 未導入"
fi

# ---- T10: SIGINT での安全停止 -------------------------------------------------

log "T10: SIGINT — Ctrl+C 相当での安全なファイナライズ"
F="$WORK/t10-sigint.mov"
"$KILDE" rec --duration 60s --output "$F" > "$WORK/t10.log" 2>&1 &
REC_PID=$!
sleep 4
kill -INT "$REC_PID"
wait "$REC_PID"
EXIT_CODE=$?
VD=$(video_duration_of "$F")
if [ "$EXIT_CODE" = "0" ] && num_between "${VD:-0}" 2.5 8; then
    ok "T10 SIGINT: exit=0・再生可能なファイル (duration=${VD}s)"
else
    bad "T10 SIGINT: exit=$EXIT_CODE duration=${VD:-N/A}s — $WORK/t10.log"
fi

# ---- T11: GUI (メニューバーアプリ) のビルドと起動 ------------------------------
# .xcodeproj はコミットされていないため xcodegen で生成する (未導入なら SKIP)。
# メニューバーのアイコン表示そのものは目視確認になるため、ここでは
# 「ビルドできる・起動する・正常終了する」を機械検証する

if command -v xcodegen >/dev/null 2>&1; then
    log "T11: GUI — KildeGUI のビルドと起動/終了"
    # project.yml は kilde-dev 証明書での手動署名のため、証明書が無い環境では
    # codesign が失敗する。作成手順は docs/DEVELOPMENT.md §3。
    # find-identity は自己署名証明書が「信頼」設定でないと一覧に出ない
    # (codesign 自体は動く) ため、存在確認は find-certificate で行う
    if ! security find-certificate -c "kilde-dev" >/dev/null 2>&1; then
        skip "T11 GUI: 署名用証明書 kilde-dev なし (docs/DEVELOPMENT.md §3 の手順で作成可)"
    # 既に起動している KildeGUI は open が再利用してしまう (検証にも利用中アプリの
    # 終了にも使えない) ので、その場合は検証しない
    elif pgrep -x KildeGUI >/dev/null 2>&1; then
        skip "T11 GUI: KildeGUI が既に起動中のためスキップ (終了してから再実行)"
    elif (cd "$ROOT/gui" && xcodegen -q > "$WORK/t11-xcodegen.log" 2>&1 \
        && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI -configuration Debug build \
           >> "$WORK/t11-xcodegen.log" 2>&1); then
        GUI_APP=$(cd "$ROOT/gui" && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI \
            -configuration Debug -showBuildSettings 2>/dev/null \
            | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')/KildeGUI.app
        # open は LaunchServices 経由で起動するためシェルの環境変数を伝えない。
        # --env で明示的に渡さないと GUI は ~/.kilde を参照し、分離の前提が崩れる
        # (#18 以降で GUI が ConfigStore を使い始めた時点で必須)
        if open --env KILDE_CONFIG_DIR="$KILDE_CONFIG_DIR" "$GUI_APP" && sleep 3 && GUI_PID=$(pgrep -x KildeGUI); then
            if osascript -e 'tell application "KildeGUI" to quit' >/dev/null 2>&1 && sleep 1 \
                && ! pgrep -x KildeGUI >/dev/null; then
                GUI_PID=""
                ok "T11 GUI: ビルド・起動・正常終了 (メニューバー表示は目視確認)"
            else
                bad "T11 GUI: 終了に失敗 — cleanup trap が kill します"
            fi
        else
            bad "T11 GUI: 起動に失敗 — $WORK/t11-xcodegen.log"
        fi
    else
        bad "T11 GUI: ビルドに失敗 — $WORK/t11-xcodegen.log"
    fi
else
    skip "T11 GUI: xcodegen 未導入 (brew install xcodegen で実行可)"
fi

# ---- T12: 設定ファイル (issue #14) ----------------------------------------------
# テスト用に分離した設定を書き、終わったら消す

log "T12: 設定ファイル — outputDirectory が既定の保存先になる / 存在しない保存先は録画前に失敗"
CFG_OUT="$WORK/t12-out"
# テスト用の設定は tmp に書き切ってから置き換え、途中の内容を読ませない。
write_test_config() {
    printf "$@" > "$WORK/t12-config.tmp" || return 1
    mv "$WORK/t12-config.tmp" "$CONFIG" || return 1
}
mkdir -p "$CFG_OUT" "$(dirname "$CONFIG")"
if ! write_test_config '{"outputDirectory": "%s", "defaultAudioSources": ["system"]}\n' "$CFG_OUT"; then
    bad "T12a outputDirectory: テスト設定の書き込みに失敗 — $WORK/t12-config.tmp"
elif (cd "$WORK" && "$KILDE" rec --no-video --duration 3s > "$WORK/t12a.log" 2>&1) \
    && [ "$(ls "$CFG_OUT"/kilde-*.m4a 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "T12a outputDirectory: 設定した保存先に既定名で保存"
else
    bad "T12a outputDirectory: 保存先に出力がない — $WORK/t12a.log"
fi
if write_test_config '{"outputDirectory": "%s/no-such-dir"}\n' "$WORK"; then
    START=$(date +%s)
    # 誤って録画が始まっても 30 秒で止まる。録画前に失敗すれば数秒で返る
    (cd "$WORK" && "$KILDE" rec --no-video --duration 30s > "$WORK/t12b.log" 2>&1)
    EXIT_CODE=$?
    ELAPSED=$(( $(date +%s) - START ))
    if [ "$EXIT_CODE" = "1" ] && [ "$ELAPSED" -lt 5 ] && grep -q "出力先ディレクトリが存在しません" "$WORK/t12b.log"; then
        ok "T12b 存在しない保存先: 録画前に exit=1 (${ELAPSED}s)"
    else
        bad "T12b 存在しない保存先: exit=$EXIT_CODE elapsed=${ELAPSED}s — $WORK/t12b.log"
    fi
else
    bad "T12b 存在しない保存先: テスト設定の書き込みに失敗 — $WORK/t12-config.tmp"
fi
rm -f "$CONFIG"

# ---- T13: ホットキー待機 — 待機中の SIGINT は録画を始めず exit 0 ----------------
# ホットキーの実際の押下は人間の確認が必要だが、「待機中の Ctrl+C はファイルを
# 作らず終了 0」の契約はここで機械検証する

log "T13: rec --hotkey — 待機中の SIGINT は録画を始めず exit 0"
T13_DIR="$WORK/t13"
mkdir -p "$T13_DIR"
# exec でサブシェル自身を kilde に置き換える — 置き換えないと $! はサブシェルの PID に
# なり、kill -INT が kilde に届かず wait がハングする
(cd "$T13_DIR" && exec "$KILDE" rec --no-video --hotkey cmd+opt+ctrl+shift+f11 \
    > "$WORK/t13.log" 2>&1) &
T13_PID=$!
# 「待機中」の表示 (登録完了) を待つ — 出ないままなら start に失敗している
T13_READY=0
for _ in $(seq 1 20); do
    if grep -q "待機中" "$WORK/t13.log" 2>/dev/null; then T13_READY=1; break; fi
    sleep 0.5
done
sleep 1
kill -INT $T13_PID 2>/dev/null
# wait にタイムアウトがないと、待機中 SIGINT で終了しない回帰があったときに
# スイート全体が無言でハングする — SIGINT 後 5 秒生きていたら段階的に強制する。
# **INT を送り直す stop_kilde ではなく await_stop を使う (issue #101)。** ここで
# 送り直すと、上の 1 通目が失われる回帰 (issue #67) を 2 通目が救ってしまい、
# 「待機中の SIGINT で止まる」というこのテストの門が緑のまま素通りする
await_stop "$T13_PID" waiting
T13_EXIT=$STOP_EXIT
T13_FILES=$(ls "$T13_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T13_READY" = "1" ] && [ "$T13_EXIT" = "0" ] && [ "$T13_FILES" = "0" ]; then
    ok "T13 hotkey 待機中止: exit=0・出力ファイルなし"
else
    bad "T13 hotkey 待機中止: ready=$T13_READY exit=$T13_EXIT files=$T13_FILES — $WORK/t13.log"
fi

# ---- T23: ホットキーの排他と縮退 (issue #80) -------------------------------------
# 同じキーは 2 プロセスが同時に持てない (kEventHotKeyExclusive)。常駐した GUI が
# キーを握っている状況を、占有役の `rec --hotkey` で再現する — GUI をビルドせずに
# 同じ衝突を作れるので、この契約は CLI だけで機械検証できる。
#   * 設定ファイル由来のキーが取れない → 警告を出して即時録画へ縮退 (exit 0・ファイルあり)
#   * --hotkey 明示で取れない → 縮退せず失敗 (exit 1・ファイルなし)
# T13 とはキーを分ける — 取り違えで「実は誰も握っていない」状態を緑と誤認しないため

log "T23: ホットキー排他 — 設定由来は縮退し、--hotkey 明示は失敗する"
T23_KEY="cmd+opt+ctrl+shift+f10"
T23_DIR="$WORK/t23"
T23_CFG_DIR="$WORK/t23-config"
# 明示指定のログは最終判定で必ず grep する。占有役が待機に入れず (2) を実行しなかった
# ときのために空で用意しておく — **実行の後に置くと実行が書いた内容を消してしまう**
: > "$WORK/t23-explicit.log"
mkdir -p "$T23_DIR" "$T23_CFG_DIR"
printf '{"hotkey": "%s"}\n' "$T23_KEY" > "$T23_CFG_DIR/config.json"
# 占有役。T13 と同じ理由で exec を使う (kill を kilde 本体に届かせる)
(cd "$WORK" && exec "$KILDE" rec --no-video --hotkey "$T23_KEY" \
    > "$WORK/t23-holder.log" 2>&1) &
T23_HOLDER_PID=$!
T23_HELD=0
for _ in $(seq 1 20); do
    if grep -q "待機中" "$WORK/t23-holder.log" 2>/dev/null; then T23_HELD=1; break; fi
    sleep 0.5
done

if [ "$T23_HELD" != "1" ]; then
    # 占有できていないなら以降の判定は無意味 (握られていないキーは当然登録できる)。
    # ここでは bad を呼ばず、下の最終判定に一本化する — 2 箇所で呼ぶと 1 つの失敗で
    # FAIL が 2 増え、スイート末尾の PASS=…/FAIL=… の集計がずれる
    T23_CFG_EXIT=-1; T23_CFG_FILES=-1; T23_CFG_WARN=0; T23_EXP_EXIT=-1; T23_EXP_FILES=-1
else
    # 期限付きで rec を 1 本走らせ、終了コードを T23_RUN_EXIT に入れる。
    # **--duration は待機モードでは効かない** (録画開始後の長さしか縛らない) ので、
    # 縮退が壊れて待機に入る回帰が起きると前景実行はスイートごと無限に止まる。
    # ここを FAIL として回収するために、T13 と同じ段階的強制で期限を切る。
    # 期限超過は T23_RUN_EXIT=-2 として区別する (「待機に入ってしまった」の印)
    t23_run() {  # $1 = 作業ディレクトリ, $2 = ログ, $3.. = kilde の引数
        local dir="$1" log="$2"; shift 2
        # 占有役が先に死んでいたら前提が崩れる (キーが空くので待機に入るのが正常)。
        # ハングを待つ前にここで落とす
        if ! kill -0 "$T23_HOLDER_PID" 2>/dev/null; then
            T23_RUN_EXIT=-3
            return
        fi
        # PID はグローバルに持つ — スイートを中断したとき EXIT trap から回収するため。
        # local にすると trap から見えず、待機回帰なら同じキーを、録画中なら録画デバイスと
        # 未完了ファイルを掴んだ子が残る
        ( cd "$dir" && exec env KILDE_CONFIG_DIR="$T23_CFG_DIR" "$KILDE" "$@" > "$log" 2>&1 ) &
        T23_RUN_PID=$!
        local i
        for i in $(seq 1 30); do
            kill -0 "$T23_RUN_PID" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$T23_RUN_PID" 2>/dev/null; then
            # 15 秒で終わらなかった時点でこの回は失敗 (-2) と決まっているので、
            # ここは判定ではなく回収。INT を送り直してよい
            stop_kilde "$T23_RUN_PID" recording
            T23_RUN_PID=""
            T23_RUN_EXIT=-2
            return
        fi
        wait "$T23_RUN_PID" 2>/dev/null
        T23_RUN_EXIT=$?
        # 回収済みの PID を trap に残さない (T22 / 占有役と同じ理由 — PID の再利用で
        # 無関係なプロセスに signal を送りうる)
        T23_RUN_PID=""
    }

    # (1) 設定由来 — 縮退して録画できるはず
    t23_run "$T23_DIR" "$WORK/t23-config.log" rec --no-video --duration 1
    T23_CFG_EXIT=$T23_RUN_EXIT
    T23_CFG_FILES=$(ls "$T23_DIR" 2>/dev/null | wc -l | tr -d ' ')
    # 黙って縮退していないこと (理由が読めること) も契約のうち。
    # grep -c は不一致でも "0" を出しつつ終了コード 1 を返すので `|| echo 0` を足すと
    # "0\n0" を掴んで数値比較が壊れる — -q で真偽だけ取る
    if grep -q "WARNING: ホットキー" "$WORK/t23-config.log" 2>/dev/null; then
        T23_CFG_WARN=1
    else
        T23_CFG_WARN=0
    fi

    # (2) --hotkey 明示 — 縮退せず失敗するはず
    T23_EXP_DIR="$WORK/t23-explicit"
    mkdir -p "$T23_EXP_DIR"
    t23_run "$T23_EXP_DIR" "$WORK/t23-explicit.log" \
        rec --no-video --duration 1 --hotkey "$T23_KEY"
    T23_EXP_EXIT=$T23_RUN_EXIT
    T23_EXP_FILES=$(ls "$T23_EXP_DIR" 2>/dev/null | wc -l | tr -d ' ')
fi

# 占有役を畳む。**待機しているだけなので waiting。** ここは判定に使わない回収なので
# (占有役の終了コードは見ない)、確実さを優先して INT を送り直す stop_kilde でよい。
# **引用符を外さない** — 占有に失敗した分岐 (T23_HELD != 1) を通ると空文字列になり、
# 素で渡すと引数が消えて waiting が PID の位置にずれ込む
stop_kilde "${T23_HOLDER_PID:-}" waiting
# 回収済みの PID を trap に残さない — スイートの残りで数百のプロセスが起動するため、
# PID が一周して再利用されると無関係なプロセスに SIGINT を送りうる (T22 が同じ理由で
# kill 後に空へ戻している)
T23_HOLDER_PID=""

if grep -Eq "ホットキー .*を登録できません" "$WORK/t23-explicit.log" 2>/dev/null; then
    T23_EXP_REASON=1
else
    T23_EXP_REASON=0
fi

# 明示指定は「exit 1」だけでなく**理由が競合であること**まで見る — 権限エラーや
# 引数エラーでも exit 1 になるので、それらを PASS と取り違えないため
if [ "$T23_HELD" = "1" ] && [ "$T23_CFG_EXIT" = "0" ] && [ "$T23_CFG_FILES" = "1" ] \
    && [ "$T23_CFG_WARN" -ge 1 ] \
    && [ "$T23_EXP_EXIT" = "1" ] && [ "$T23_EXP_FILES" = "0" ] \
    && [ "$T23_EXP_REASON" = "1" ]; then
    ok "T23 ホットキー排他: 設定由来は縮退 (exit=0・警告あり)・明示は exit=1"
elif [ "$T23_HELD" != "1" ]; then
    # 占有役が待機に入れない = 残留プロセスが同じキーを握っている可能性が高い
    bad "T23 ホットキー排他: 占有役が待機に入れませんでした (他のプロセスが $T23_KEY を握っていないか確認してください) — $WORK/t23-holder.log"
else
    # exit=-2 は期限超過 (待機モードに入ったまま帰ってこない = 縮退の回帰)、
    # -3 は占有役が先に死んだ (前提が崩れており判定は無意味)
    bad "T23 ホットキー排他: cfg_exit=$T23_CFG_EXIT cfg_files=$T23_CFG_FILES cfg_warn=$T23_CFG_WARN exp_exit=$T23_EXP_EXIT exp_files=$T23_EXP_FILES exp_reason=$T23_EXP_REASON (exit=-2 は待機のまま期限超過 / -3 は占有役が先に終了 / exp_reason=0 は exit 1 だが競合が理由でない) — $WORK/t23-config.log / $WORK/t23-explicit.log"
fi

# ---- T14: 矩形領域の収録 (issue #9) ---------------------------------------------
# 指定した領域の大きさで録れること。H.264 の制約で偶数に切り捨てられる点も確認する

log "T14: rec --region — 指定した矩形の解像度で録れる (${DUR}s)"
F="$WORK/t14-region.mov"
if "$KILDE" rec --region 0,0,640,360 --duration "$DUR" --output "$F" > "$WORK/t14.log" 2>&1; then
    SIZE=$(inspect "$F" | grep '^video:' | grep -oE '[0-9]+x[0-9]+' | head -1)
    if [ "$SIZE" = "640x360" ]; then
        ok "T14 region: 出力解像度が指定どおり ($SIZE)"
    else
        bad "T14 region: 解像度=$SIZE (640x360 が必要) — $WORK/t14.log"
    fi
else
    bad "T14 region: コマンド失敗 — $WORK/t14.log"
fi

log "T14b: rec --region — 奇数サイズは偶数へ切り捨て"
F="$WORK/t14b-region-odd.mov"
if "$KILDE" rec --region 10,10,641,361 --duration 3s --output "$F" > "$WORK/t14b.log" 2>&1; then
    SIZE=$(inspect "$F" | grep '^video:' | grep -oE '[0-9]+x[0-9]+' | head -1)
    if [ "$SIZE" = "640x360" ]; then
        ok "T14b region 偶数丸め: 641x361 → $SIZE"
    else
        bad "T14b region 偶数丸め: 解像度=$SIZE (640x360 が必要) — $WORK/t14b.log"
    fi
else
    bad "T14b region 偶数丸め: コマンド失敗 — $WORK/t14b.log"
fi

log "T14c: rec --region — 範囲外は録画前に exit 1"
"$KILDE" rec --region 0,0,99999,99999 --duration 30s --output "$WORK/t14c.mov" > "$WORK/t14c.log" 2>&1
EXIT_CODE=$?
if [ "$EXIT_CODE" = "1" ] && grep -q "範囲外" "$WORK/t14c.log" && [ ! -f "$WORK/t14c.mov" ]; then
    ok "T14c region 範囲外: exit=1・ファイルを作らない"
else
    bad "T14c region 範囲外: exit=$EXIT_CODE (1 が必要) — $WORK/t14c.log"
fi
# 形式不正・小さすぎる指定・併用不可の組合せは引数検証なので 64 (DESIGN.md §6)。
# 併用の排他が消えても「録画は成功する」ため、ここで検証しないと回帰に気づけない
T14D_FAIL=0
check_rejected() {  # check_rejected <ログ名> <説明> <kilde rec の引数...>
    local logname="$1" desc="$2"; shift 2
    "$KILDE" rec "$@" --duration 3s --output "$WORK/$logname.mov" > "$WORK/$logname.log" 2>&1
    local code=$?
    if [ "$code" != "64" ] || [ -f "$WORK/$logname.mov" ]; then
        echo "  $desc: exit=$code (64 が必要) file=$([ -f "$WORK/$logname.mov" ] && echo あり || echo なし)"
        T14D_FAIL=1
    fi
}
log "T14d: rec --region — 形式不正・小さすぎる指定・併用不可は exit 64 でファイルを作らない"
check_rejected t14d "形式不正 (要素不足)" --region 0,0,640
check_rejected t14d2 "幅・高さが 2 未満" --region 0,0,1,360
check_rejected t14d3 "--window との併用" --region 0,0,640,360 --window Finder
check_rejected t14d4 "--no-video との併用" --region 0,0,640,360 --no-video
check_rejected t14d5 "--preset meeting との併用" --region 0,0,640,360 --preset meeting
if [ "$T14D_FAIL" = "0" ]; then
    ok "T14d region 引数検証: 5 パターンすべて exit=64・ファイルなし"
else
    bad "T14d region 引数検証: 上記の組合せが想定どおりに弾かれていない"
fi

# ---- T15: 一時停止 / 再開 (issue #11) -------------------------------------------
# SIGUSR1 でトグルする ('p' キーは端末が要るので機械検証しない)。
# 12 秒の録画の途中で 4 秒止めると、出力は一時停止を除いた約 8 秒になる

log "T15: rec 一時停止 / 再開 — 一時停止区間は出力に含まれない"
F="$WORK/t15-pause.mov"
# exec でサブシェル自身を kilde に置き換える (置き換えないと $! に kill -USR1 が届かない)
(exec "$KILDE" rec --duration 12s --output "$F" > "$WORK/t15.log" 2>&1) &
T15_PID=$!
# 固定の sleep で送ると、起動が遅い環境では録画開始前に SIGUSR1 が届いて素通りする。
# 「● 録画」は run() の前に出るので readiness にならない — ステータス行 (REC mm:ss) は
# 録画が始まって progress() が返るようになってから出るので、こちらを待つ
T15_READY=0
for _ in $(seq 1 40); do
    if grep -q "REC " "$WORK/t15.log" 2>/dev/null; then T15_READY=1; break; fi
    sleep 0.5
done
sleep 2                            # 数秒ぶんは録ってから止める
kill -USR1 $T15_PID 2>/dev/null    # 一時停止
# PAUSED 表示で一時停止が受理されたことを確かめてから再開する
T15_PAUSED=0
for _ in $(seq 1 20); do
    if grep -q "PAUSED" "$WORK/t15.log" 2>/dev/null; then T15_PAUSED=1; break; fi
    sleep 0.5
done
sleep 4
kill -USR1 $T15_PID 2>/dev/null    # 再開
wait $T15_PID
T15_EXIT=$?
T15_PID=""
VD=$(video_duration_of "$F")
# 音声にも一時停止区間が残っていないこと (映像だけ詰めて音声が伸びる回帰を捕まえる)。
# inspect の audio[0] の duration と映像の差を見る
AD=$(inspect "$F" | grep '^audio\[0\]' | grep -o 'duration=[0-9.]*' | cut -d= -f2)
if [ "$T15_READY" = "1" ] && [ "$T15_PAUSED" = "1" ] && [ "$T15_EXIT" = "0" ] \
    && num_between "${VD:-0}" 5 10 && num_between "${AD:-0}" 5 10 \
    && awk -v v="${VD:-0}" -v a="${AD:-0}" 'BEGIN{exit !((v-a < 1) && (a-v < 1))}' \
    && grep -q "一時停止: 合計" "$WORK/t15.log"; then
    ok "T15 一時停止: 映像 ${VD}s / 音声 ${AD}s (12s のうち 4s 停止)・A/V の差 1s 未満"
else
    bad "T15 一時停止: ready=$T15_READY paused=$T15_PAUSED exit=$T15_EXIT video=${VD:-N/A}s audio=${AD:-N/A}s — $WORK/t15.log"
fi

# ---- T16: 出力コンテナ (issue #12) ---------------------------------------------
# MP4 で録れること、拡張子からの自動判定、入れられない組合せが録画前に弾かれること

# 拡張子を変えただけの回帰 (中身が MOV のまま) を捕まえるため、コンテナを直接見る
is_iso_mp4() { file -b "$1" 2>/dev/null | grep -qi 'ISO Media'; }

log "T16: rec --format mp4 — MP4 コンテナで録れる"
F="$WORK/t16-format.mp4"
if "$KILDE" rec --format mp4 --duration 3s --output "$F" > "$WORK/t16.log" 2>&1; then
    VD=$(video_duration_of "$F")
    if grep -q "video: present" <(inspect "$F") && num_between "${VD:-0}" 2 5 && is_iso_mp4 "$F"; then
        ok "T16 format mp4: ISO Media コンテナ・映像あり (${VD}s)"
    else
        bad "T16 format mp4: duration=${VD:-N/A}s container=$(file -b "$F" 2>/dev/null | head -c 40) — $WORK/t16.log"
    fi
else
    bad "T16 format mp4: コマンド失敗 — $WORK/t16.log"
fi

log "T16b: rec <出力>.mp4 — 拡張子から自動で MP4 になる"
F="$WORK/t16b-auto.mp4"
if "$KILDE" rec --duration 3s --output "$F" > "$WORK/t16b.log" 2>&1; then
    VD=$(video_duration_of "$F")
    if grep -q "video: present" <(inspect "$F") && num_between "${VD:-0}" 2 5 && is_iso_mp4 "$F"; then
        ok "T16b format 自動判定: .mp4 の指定で ISO Media コンテナ (${VD}s)"
    else
        bad "T16b format 自動判定: duration=${VD:-N/A}s container=$(file -b "$F" 2>/dev/null | head -c 40) — $WORK/t16b.log"
    fi
else
    bad "T16b format 自動判定: コマンド失敗 — $WORK/t16b.log"
fi

log "T16b2: rec <出力>.mov — 既定は MOV のまま (回帰確認)"
F="$WORK/t16b2-mov.mov"
if "$KILDE" rec --duration 3s --output "$F" > "$WORK/t16b2.log" 2>&1 \
    && file -b "$F" 2>/dev/null | grep -qi 'QuickTime'; then
    ok "T16b2 既定 mov: QuickTime コンテナのまま"
else
    bad "T16b2 既定 mov: container=$(file -b "$F" 2>/dev/null | head -c 40) — $WORK/t16b2.log"
fi

log "T16c: rec --format — 入れられない組合せは録画前に exit 64"
T16C_FAIL=0
check_format_rejected() {  # check_format_rejected <ログ名> <出力パス> <説明> <引数...>
    local logname="$1" out="$2" desc="$3"; shift 3
    local start=$(date +%s)
    # --duration 30s にしておくと、録画が始まってしまった実装では 30 秒かかる。
    # 5 秒未満で返ったことをもって「録画前に弾いた」と判定する (T12b と同じ考え方)。
    # 出力パスは呼び出し側から受け取る — ここで --output を足すと、拡張子で
    # コンテナを推定するケースの指定を後勝ちで上書きしてしまう
    "$KILDE" rec "$@" --duration 30s --output "$out" > "$WORK/$logname.log" 2>&1
    local code=$? elapsed=$(( $(date +%s) - start ))
    if [ "$code" != "64" ] || [ -f "$out" ] || [ "$elapsed" -ge 5 ]; then
        echo "  $desc: exit=$code (64 が必要) elapsed=${elapsed}s file=$([ -f "$out" ] && echo あり || echo なし)"
        T16C_FAIL=1
    fi
}
check_format_rejected t16c "$WORK/t16c.mov" "MP4 + ProRes (--format 明示)" --format mp4 --codec prores
check_format_rejected t16c2 "$WORK/t16c2.m4a" "--no-video との併用" --format mp4 --no-video
check_format_rejected t16c3 "$WORK/t16c3.mov" "不正な値" --format mkv
# 拡張子からの推定でも同じ契約 (CLI 由来は 64)
check_format_rejected t16c4 "$WORK/t16c4.mp4" "MP4 + ProRes (拡張子で推定)" --codec prores
if [ "$T16C_FAIL" = "0" ]; then
    ok "T16c format 引数検証: 4 パターンすべて録画前に exit=64・ファイルなし"
else
    bad "T16c format 引数検証: 上記の組合せが想定どおりに弾かれていない"
fi

log "T16d: 設定ファイル由来の codec との組合せは録画前に exit 1"
# CLI 引数由来は 64、設定ファイル由来は 1 という公開契約 (DESIGN.md §6) を守る
if write_test_config '{"codec": "prores"}\n'; then
    START=$(date +%s)
    (cd "$WORK" && "$KILDE" rec --format mp4 --duration 30s --output "$WORK/t16d.mp4" > "$WORK/t16d.log" 2>&1)
    EXIT_CODE=$?
    ELAPSED=$(( $(date +%s) - START ))
    if [ "$EXIT_CODE" = "1" ] && [ "$ELAPSED" -lt 5 ] && [ ! -f "$WORK/t16d.mp4" ]; then
        ok "T16d 設定由来 codec: 録画前に exit=1 (${ELAPSED}s)"
    else
        bad "T16d 設定由来 codec: exit=$EXIT_CODE elapsed=${ELAPSED}s — $WORK/t16d.log"
    fi
    rm -f "$CONFIG"
else
    bad "T16d 設定由来 codec: テスト設定の書き込みに失敗"
fi

# ---- T19: コーデック別の収録経路 (issue #15) -------------------------------------
# pixelFormat をコーデックのクロマに合わせて出し分けている (h264/hevc → 420v、
# prores → BGRA)。SCStreamConfiguration は単体テストから触れないので、
# 両方の経路で実際に録れることをここで通す。
#
# 注意: **pixelFormat そのものは検証していない** — 出力ファイルからは観測できず、
# inspect はコーデックも出さない (解像度と duration のみ)。ここで捕まえられるのは「片方の経路が
# 録画すらできなくなる」退行までで、「ProRes が静かに 420v になる」品質劣化は
# 捕まらない。クロマの検証が要るなら別途 ffprobe 等で pix_fmt を見ること

log "T19: rec --codec prores — BGRA 経路で録れる"
F="$WORK/t19-prores.mov"
if "$KILDE" rec --codec prores --duration 3s --output "$F" > "$WORK/t19.log" 2>&1; then
    VD=$(video_duration_of "$F")
    if grep -q "video: present" <(inspect "$F") && num_between "${VD:-0}" 2 5; then
        ok "T19 codec prores: 映像あり (${VD}s)"
    else
        bad "T19 codec prores: duration=${VD:-N/A}s — $WORK/t19.log"
    fi
else
    bad "T19 codec prores: コマンド失敗 — $WORK/t19.log"
fi

log "T19b: rec --codec hevc — 420v 経路で録れる"
F="$WORK/t19b-hevc.mov"
if "$KILDE" rec --codec hevc --duration 3s --output "$F" > "$WORK/t19b.log" 2>&1; then
    VD=$(video_duration_of "$F")
    if grep -q "video: present" <(inspect "$F") && num_between "${VD:-0}" 2 5; then
        ok "T19b codec hevc: 映像あり (${VD}s)"
    else
        bad "T19b codec hevc: duration=${VD:-N/A}s — $WORK/t19b.log"
    fi
else
    bad "T19b codec hevc: コマンド失敗 — $WORK/t19b.log"
fi
# ---- T18: 既定出力名の原子的な予約 -------------------------------------------

log "T18: 既定出力名 — 同名ファイルがあれば -2 に逃がす"
T18_DIR="$WORK/t18"
mkdir -p "$T18_DIR"
# コマンド起動中に秒境界をまたいでも衝突候補が必ずあるよう、直近数秒ぶんを予約しておく。
# 既存の 0 バイトファイルも他人の所有物として残すことを同時に検証する。
# 起動 (権限・設定の解決を含む) に時間がかかると予約のタイムスタンプが
# ダミーの範囲外にずれて -2 に退避しなくなるため、十分な幅を持たせる
for OFFSET in 0 1 2 3 4 5 6 7 8 9; do
    STAMP=$(date -v+"${OFFSET}"S +%Y%m%d-%H%M%S)
    touch "$T18_DIR/kilde-$STAMP.m4a"
done
if (cd "$T18_DIR" && KILDE_OUTPUT_DIR="$T18_DIR" "$KILDE" rec --no-video --duration 3s \
    > "$WORK/t18.log" 2>&1); then
    T18_OUTPUT=$(find "$T18_DIR" -type f -name 'kilde-*-2.m4a' -size +0c | head -1)
    if [ -n "$T18_OUTPUT" ]; then
        T18_BASE="${T18_OUTPUT%-2.m4a}.m4a"
        if [ -f "$T18_BASE" ] && [ ! -s "$T18_BASE" ]; then
            ok "T18 既定名予約: ダミーを保持し、$(basename "$T18_OUTPUT") に退避"
        else
            bad "T18 既定名予約: 対応するダミーが保持されていない — $WORK/t18.log"
        fi
    else
        bad "T18 既定名予約: -2 の録画ファイルがない — $WORK/t18.log"
    fi
else
    bad "T18 既定名予約: コマンド失敗 — $WORK/t18.log"
fi

# ---- T18b: 同じ秒に 2 本起動しても互いのファイルを消さない (issue #59 の主シナリオ)
# 秒境界の直後に 2 つの kilde rec を同時起動し、既定名の取り合いでどちらかのファイルが
# 「削除されて」いないことを検証する。
# **exit コードも検証する (issue #70 の受け入れ条件)。** 以前は 2 プロセスが同時に
# SCK を開始するとセッションが固まったため exit を見ていなかったが、SCKStartupLock で
# 起動区間を直列化して直した。**ここを緩めたままにすると回帰を検出できない** —
# 固まれば下のタイムアウトで KILL され exit が 0 以外になるので、この判定が門になる。
# 期限つきの待ちは残す (回帰したときスイートが無言で止まらないように)

log "T18b: 既定名 — 同秒の 2 本同時起動で互いのファイルを消さない"
# 秒境界の計算に python3 を使う (BSD date に +%N が無いため)。無い環境では
# 同期を諦めてスキップする — 失敗にすると python3 の無い環境で常に赤になる
if ! command -v python3 >/dev/null 2>&1; then
    skip "T18b 同時起動: python3 が無いため秒境界の同期ができません"
else
# **1 組では足りないので反復する。** issue #95 の残存ハングは秒境界を揃えた同時起動で
# 約 10% の頻度なので、**1 組が通っても #70 の回帰が無い証拠にはならない**。
#
# 判定は 2 系統に分ける:
#   - **#59 の条件 (名前が 2 つ残る)** は排他とは独立に常に成立すべきなので `bad`
#   - **#70 の条件 (両者 exit 0・ファイル非空)** は #95 が残る間 `skip` にする。
#     約 10% で落ちるものを必須にすると、**#70 と無関係な PR まで恒常的に赤くなる**。
#     #95 が閉じたらここを `bad` に上げること
T18B_ROUNDS=3
T18B_NAME_NG=0      # #59 側で崩れた組
T18B_LIVE_NG=0      # #70 側で崩れた組
T18B_DETAIL=""
for T18B_ROUND in $(seq 1 "$T18B_ROUNDS"); do
    T18B_DIR="$WORK/t18b-$T18B_ROUND"
    mkdir -p "$T18B_DIR"
    # 次の秒の先頭まで待ってから同時に出す (date +%N は BSD date に無いため python3 で)
    T18B_WAIT=$(python3 -c 'import time; print(max(0.05, 1.02 - (time.time() % 1.0)))')
    sleep "$T18B_WAIT"
    (cd "$T18B_DIR" && exec "$KILDE" rec --no-video --duration 3s > "$WORK/t18b-$T18B_ROUND-1.log" 2>&1) &
    T18B_PID1=$!
    (cd "$T18B_DIR" && exec "$KILDE" rec --no-video --duration 3s > "$WORK/t18b-$T18B_ROUND-2.log" 2>&1) &
    T18B_PID2=$!
    # 固まり (issue #95) でもスイートが無言で止まらないよう、期限つきで待つ
    T18B_GRACE=25  # duration 3s + 余裕
    T18B_DEADLINE=$(( $(date +%s) + T18B_GRACE ))
    while [ "$(date +%s)" -lt "$T18B_DEADLINE" ] \
          && { kill -0 $T18B_PID1 2>/dev/null || kill -0 $T18B_PID2 2>/dev/null; }; do
        sleep 1
    done
    for pid in $T18B_PID1 $T18B_PID2; do
        if kill -0 $pid 2>/dev/null; then
            # **ここは stop_kilde / await_stop に寄せない (issue #101)。**
            # 両ヘルパは「確実に止めて回収する」ためのもので、必ず TERM を経由する。
            # この回は逆に**止まらなかったこと自体が所見**なので、TERM で綺麗に
            # 終わらせてはいけない (下記)。猶予 25 秒も役割ではなく duration 3s に
            # 由来する値で、ヘルパの猶予表とは意味が違う。
            #
            # **SIGTERM を挟まず直接 SIGKILL する。** 期限まで終わらなかった時点で異常だが、
            # TERM を送ると「準備中の停止は exit 0」の契約 (DESIGN.md §6) に沿って
            # graceful に 0 で終わりうる — つまり**ハングしたのに exit 0 になり、
            # 下の判定がすり抜ける**。KILL なら 137 で残るので回帰を捕まえられる
            kill -KILL $pid 2>/dev/null
        fi
    done
    wait $T18B_PID1 2>/dev/null; T18B_EXIT1=$?
    wait $T18B_PID2 2>/dev/null; T18B_EXIT2=$?

    T18B_N=$(ls "$T18B_DIR" 2>/dev/null | wc -l | tr -d ' ')
    # 1KB 未満は「開いただけで中身が無い」とみなす (正常な 3 秒の録音は数十 KB になる)
    T18B_EMPTY_R=$(find "$T18B_DIR" -name '*.m4a' -size -1k 2>/dev/null | wc -l | tr -d ' ')
    if [ "$T18B_N" != "2" ]; then
        T18B_NAME_NG=$((T18B_NAME_NG+1))
        T18B_DETAIL="$T18B_DETAIL [組$T18B_ROUND 名前数=$T18B_N]"
    fi
    if [ "$T18B_EXIT1" != "0" ] || [ "$T18B_EXIT2" != "0" ] || [ "$T18B_EMPTY_R" != "0" ]; then
        T18B_LIVE_NG=$((T18B_LIVE_NG+1))
        # **書き込み量も残す。** issue #95 の残存ハングは「片方が完走し、片方が途中で
        # 止まる」形なので、サイズの非対称 (例: 2810 と 1425) が機序を絞る手がかりになる。
        # skip で終わる回も観測として #95 に積み上がるよう、毎回この値を出す
        T18B_SIZES=$(ls -la "$T18B_DIR"/*.m4a 2>/dev/null | awk '{printf "%s ", $5}')
        T18B_DETAIL="$T18B_DETAIL [組$T18B_ROUND exit=$T18B_EXIT1/$T18B_EXIT2 空=$T18B_EMPTY_R サイズ=${T18B_SIZES:-なし}]"
    fi
done
# 同一秒での -2 退避は最後の組で確認する (名前の衝突が起きた組でしか判定できないため)
T18B_DIR="$WORK/t18b-$T18B_ROUNDS"
T18B_NAMES=$(ls "$T18B_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T18B_NAME_NG" != "0" ]; then
    bad "T18b 同時起動: ${T18B_ROUNDS} 組中 $T18B_NAME_NG 組で名前が 2 つ残らなかった (予約の保護が壊れている。issue #59)$T18B_DETAIL"
elif [ "$T18B_LIVE_NG" = "$T18B_ROUNDS" ]; then
    # **全組が落ちたらロック自体の回帰。** #95 の残存は約 10% なので、3 組連続で
    # 引く確率は 0.1% 未満。全滅は「たまたま」では説明できず、SCKStartupLock が
    # 効いていない (= issue #70 の回帰) と見るべきなので、ここは skip にしない
    bad "T18b 同時起動: ${T18B_ROUNDS}/${T18B_ROUNDS} 組すべてで両者が完走しなかった (SCK 起動ロックの回帰を疑う。issue #70)$T18B_DETAIL"
elif [ "$T18B_LIVE_NG" != "0" ]; then
    # 一部だけなら #95 の残存。ここで落とさない (約 10% で起きるため無関係な PR まで赤くなる)
    skip "T18b 同時起動: 名前の保護は ${T18B_ROUNDS}/${T18B_ROUNDS} 組で成立。ただし $T18B_LIVE_NG 組で両者が完走しなかった (issue #95 の残存ハング。#95 が閉じたらこの分岐を bad に上げること)$T18B_DETAIL"
elif [ "$T18B_NAMES" = "2" ]; then
    # 両者のタイムスタンプが同じ秒なら、片方が必ず -2 に退避しているはず。異なる秒に
    # 落ちた場合は起動の揺らぎで、名前の衝突自体が起きていない (同一秒の決定的検証は T18 が担う)
    T18B_SAME=$(cd "$T18B_DIR" && ls | sed -E 's/kilde-([0-9]{8}-[0-9]{6})(-2)?\..*/\1/' | sort -u | wc -l | tr -d ' ')
    if [ "$T18B_SAME" = "1" ]; then
        if ls "$T18B_DIR" | grep -q -- "-2\."; then
            ok "T18b 同時起動: ${T18B_ROUNDS}/${T18B_ROUNDS} 組で共存・両方 exit=0 (最終組は同一秒で -2 に退避)"
        else
            bad "T18b 同時起動: 同一秒なのに -2 が無い (ls: $(cd "$T18B_DIR" && ls | tr '\n' ' '))"
        fi
    else
        ok "T18b 同時起動: ${T18B_ROUNDS}/${T18B_ROUNDS} 組で共存・両方 exit=0 (最終組は別秒に分岐)"
    fi
else
    bad "T18b 同時起動: 最終組の名前数=$T18B_NAMES (2 が必要)$T18B_DETAIL"
fi
fi  # python3 ありのときのみ T18b を実行

# ---- T17: アプリ除外と複数ウィンドウ (issue #13) ---------------------------------
# 除外したアプリの音が出力に入らないこと、--window の複数指定でまとめて録れること、
# 指定ミスが録画前に弾かれること

# soundapp は swiftc の直コンパイルなので bundleID を持たず、--exclude-app の対象にできない
# (kilde devices でも「bundleID なし」に入る)。最小の .app に包んで CFBundleIdentifier を与える
# — 実測でこれだけで SCRunningApplication に載ることを確認している
EXCL_ID="com.kilde.spikesound"
EXCL_APP="$WORK/SpikeSound.app"
mkdir -p "$EXCL_APP/Contents/MacOS"
cp "$SOUNDAPP" "$EXCL_APP/Contents/MacOS/SpikeSound"
cat > "$EXCL_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SpikeSound</string>
  <key>CFBundleIdentifier</key><string>$EXCL_ID</string>
  <key>CFBundleName</key><string>SpikeSound</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST

start_excl_app() {
    "$EXCL_APP/Contents/MacOS/SpikeSound" "$VOICE" >/dev/null 2>&1 &
    EXCL_PID=$!
    sleep 2
}
stop_excl_app() {
    [ -n "$EXCL_PID" ] && kill "$EXCL_PID" 2>/dev/null
    wait "$EXCL_PID" 2>/dev/null
    EXCL_PID=""
}

log "T17: rec --exclude-app — 除外したアプリの音が出力に入らない (${DUR}s)"
start_excl_app
F="$WORK/t17-exclude.mov"
if "$KILDE" rec --exclude-app "$EXCL_ID" --duration "$DUR" --output "$F" > "$WORK/t17.log" 2>&1; then
    RMS=$(rms_of "$F")
    # T7 (ウィンドウ収録の陰性確認) と同じしきい値
    if awk -v v="${RMS:-1}" 'BEGIN{exit !(v < 0.00005)}'; then
        ok "T17 exclude-app: 除外アプリの音が完全除外 (rms=$RMS)"
    else
        bad "T17 exclude-app: 除外したアプリの音が混入 (rms=$RMS) — SCK の除外が映像だけになった可能性。docs/SPIKE-NOTES.md F-F を参照"
    fi
else
    bad "T17 exclude-app: コマンド失敗 — $WORK/t17.log"
fi
stop_excl_app

log "T17b: rec --window 複数指定 — ウィンドウ群をまとめて 1 本に録れる"
start_excl_app
SECOND=""
if "$KILDE" devices 2>/dev/null | grep -q "Wallpaper"; then
    SECOND="Wallpaper"
elif "$KILDE" devices 2>/dev/null | grep -q "ゴミ箱"; then
    SECOND="ゴミ箱"
fi
# 複数ディスプレイ環境では 2 つ目のウィンドウが別ディスプレイにある可能性がある。
# その場合 Recorder が録画前に拒否するのは正しい挙動なので、テストとしては SKIP にする
DISP_COUNT=$("$KILDE" devices --no-windows 2>/dev/null | grep -c 'display\[')
F="$WORK/t17b-multi.mov"
if [ -n "$SECOND" ] && [ "$DISP_COUNT" = "1" ]; then
    if "$KILDE" rec --window SpikeSoundWindow --window "$SECOND" --duration 3s --output "$F" > "$WORK/t17b.log" 2>&1; then
        SIZE=$(inspect "$F" | grep '^video:' | grep -oE '[0-9]+x[0-9]+' | head -1)
        # 複数ウィンドウはディスプレイ座標系のまま合成されるので、出力はディスプレイ全体の大きさ
        DISP=$("$KILDE" devices --no-windows 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | head -1)
        # 音声スコープが複数指定でも効くこと (含めた音源アプリの音が入る)
        RMS=$(rms_of "$F")
        if [ -n "$SIZE" ] && [ "$SIZE" = "$DISP" ] && rms_above "$F" 0.005; then
            ok "T17b window 複数: ディスプレイ全体の大きさで録れ、対象アプリの音も入る ($SIZE rms=$RMS)"
        else
            bad "T17b window 複数: 解像度=$SIZE (ディスプレイの $DISP が必要) rms=$RMS — $WORK/t17b.log"
        fi
    else
        bad "T17b window 複数: コマンド失敗 — $WORK/t17b.log"
    fi
else
    skip "T17b window 複数: 2 つ目に使える無関係ウィンドウが無い / ディスプレイが複数 (同一ディスプレイを保証できない)"
fi

# 陽性だけだと「常に音が入る」実装でも通ってしまうので、音源を外した指定で無音を確かめる
log "T17b2: rec --window 複数指定 — 含めなかったアプリの音は入らない (陰性確認)"
F="$WORK/t17b2-multi-negative.mov"
# 2 つ目も存在を確かめる — resolveWindows はどれか 1 つでも解決できないと exit 3 になるので、
# 決め打ちのままだと「見つからない環境」で SKIP ではなく FAIL になってしまう
THIRD=""
"$KILDE" devices 2>/dev/null | grep -q "Menubar" && THIRD="Menubar"
if [ -n "$SECOND" ] && [ -n "$THIRD" ] && [ "$DISP_COUNT" = "1" ]; then
    if "$KILDE" rec --window "$SECOND" --window "$THIRD" --duration 3s --output "$F" > "$WORK/t17b2.log" 2>&1; then
        RMS=$(rms_of "$F")
        if awk -v v="${RMS:-1}" 'BEGIN{exit !(v < 0.00005)}'; then
            ok "T17b2 window 複数 陰性: 含めなかったアプリの音は入らない (rms=$RMS)"
        else
            bad "T17b2 window 複数 陰性: 音が混入した (rms=$RMS) — 音声スコープが複数指定で効いていない"
        fi
    else
        bad "T17b2 window 複数 陰性: コマンド失敗 — $WORK/t17b2.log"
    fi
else
    skip "T17b2 window 複数 陰性: 2 つ目に使える無関係ウィンドウが見つからない"
fi
stop_excl_app

log "T17c: rec --exclude-app — 実行中でない bundleID は録画前に exit 3"
# --duration 30s にしておくと、録画が始まってしまった実装では 30 秒かかる。
# 5 秒未満で返ったことをもって「録画前に弾いた」と判定する (T12b / T16c と同じ考え方)
START=$(date +%s)
"$KILDE" rec --exclude-app com.kilde.definitely-not-running --duration 30s \
    --output "$WORK/t17c.mov" > "$WORK/t17c.log" 2>&1
EXIT_CODE=$?
ELAPSED=$(( $(date +%s) - START ))
if [ "$EXIT_CODE" = "3" ] && [ "$ELAPSED" -lt 5 ] && [ ! -f "$WORK/t17c.mov" ]; then
    ok "T17c exclude-app 不明 bundleID: 録画前に exit=3 (${ELAPSED}s)・ファイルを作らない"
else
    bad "T17c exclude-app 不明 bundleID: exit=$EXIT_CODE elapsed=${ELAPSED}s (3 が必要) — $WORK/t17c.log"
fi

log "T17d: rec --exclude-app — 併用不可の組合せは録画前に exit 64"
# 除外が黙って無視されると「隠したはずのアプリが写っている」ことになり、
# 録画を見返すまで気づけない。排他が消えたら必ずここで落ちるようにする
T17D_FAIL=0
check_excl_rejected() {  # check_excl_rejected <ログ名> <説明> <kilde rec の引数...>
    local logname="$1" desc="$2"; shift 2
    "$KILDE" rec "$@" --duration 3s --output "$WORK/$logname.mov" > "$WORK/$logname.log" 2>&1
    local code=$?
    if [ "$code" != "64" ] || [ -f "$WORK/$logname.mov" ]; then
        echo "  $desc: exit=$code (64 が必要) file=$([ -f "$WORK/$logname.mov" ] && echo あり || echo なし)"
        T17D_FAIL=1
    fi
}
check_excl_rejected t17d "--window との併用" --exclude-app com.apple.finder --window Finder
check_excl_rejected t17d2 "--no-video との併用" --exclude-app com.apple.finder --no-video
check_excl_rejected t17d3 "--preset meeting との併用" --exclude-app com.apple.finder --preset meeting
check_excl_rejected t17d4 "空の bundleID" --exclude-app ""
if [ "$T17D_FAIL" = "0" ]; then
    ok "T17d exclude-app 引数検証: 4 パターンすべて exit=64・ファイルなし"
else
    bad "T17d exclude-app 引数検証: 上記の組合せが想定どおりに弾かれていない"
fi

# ---- T20: HDR の SDR フォールバックと引数検証 (issue #16) ------------------------
# HDR として録れることは HDR ディスプレイが要るので確かめられない (SPIKE-NOTES F-H)。
# だが **SDR 機でこそ通る経路** = 「HDR を求められたが応えられなかったときの振る舞い」は
# ここで検証できる。とくに重要なのは終了コードで、フォールバックの理由を
# cleanupWarnings に載せてしまうと CLI がそれを exit 1 に変換する (DESIGN.md §6)。
# 録画は成功しているので 0 でなければならない

log "T20: rec --hdr --codec hevc — 録画は成功し終了コードは 0 (SDR 機ではフォールバックの理由つき)"
F="$WORK/t20-hdr-fallback.mov"
if "$KILDE" rec --hdr --codec hevc --duration 3s --output "$F" > "$WORK/t20.log" 2>&1; then
    VD=$(video_duration_of "$F")
    # HDR 対応ディスプレイでは警告が出ない (それが正しい挙動) ので、警告の有無では判定しない。
    # 出た場合だけ「理由が書かれているか」を見る — SDR 機ではこちらを通る
    if grep -q "⚠ HDR:" "$WORK/t20.log"; then
        T20_MODE="SDR フォールバック ($(grep -o '⚠ HDR:.*' "$WORK/t20.log" | head -1 | cut -c1-40)…)"
    else
        T20_MODE="HDR 経路 (このディスプレイは HDR 対応。方式は OS 依存: 26=HDR10 / 15=Stream Local Display)"
    fi
    if num_between "${VD:-0}" 2 5; then
        ok "T20 hdr: exit=0・映像あり (${VD}s) — $T20_MODE"
    else
        bad "T20 hdr: duration=${VD:-N/A}s — $WORK/t20.log"
    fi
else
    bad "T20 hdr: exit=$? (0 が必要 — フォールバックを cleanupWarnings に載せると 1 になる) — $WORK/t20.log"
fi

log "T20a: rec --hdr (--codec 省略) — 解決後 h264 なので警告つき SDR で録り、exit 0"
# CLI の引数検証は明示指定しか見られないため、省略時は exit 64 ではなく Recorder 側の
# フォールバックに落ちる。ここを通さないと「解決後の値で契約を強制する」実装の退行を
# 統合テストが捕まえられない (T20b は明示指定しか叩いていない)
F="$WORK/t20a-hdr-default-codec.mov"
if "$KILDE" rec --hdr --duration 3s --output "$F" > "$WORK/t20a.log" 2>&1; then
    VD=$(video_duration_of "$F")
    if grep -q "⚠ HDR:.*HEVC" "$WORK/t20a.log" && num_between "${VD:-0}" 2 5; then
        ok "T20a hdr 既定コーデック: HEVC でない旨を出して SDR で録れ、exit=0 (${VD}s)"
    else
        bad "T20a hdr 既定コーデック: 警告=$(grep -o '⚠ HDR:.*' "$WORK/t20a.log" | head -1) duration=${VD:-N/A}s — $WORK/t20a.log"
    fi
else
    bad "T20a hdr 既定コーデック: exit=$? (0 が必要) — $WORK/t20a.log"
fi

log "T20b: rec --hdr — 併用できない組合せは録画前に exit 64"
T20B_FAIL=0
check_hdr_rejected() {  # check_hdr_rejected <ログ名> <説明> <kilde rec の引数...>
    local logname="$1" desc="$2"; shift 2
    local start=$(date +%s)
    "$KILDE" rec "$@" --duration 30s --output "$WORK/$logname.mov" > "$WORK/$logname.log" 2>&1
    local code=$? elapsed=$(( $(date +%s) - start ))
    if [ "$code" != "64" ] || [ -f "$WORK/$logname.mov" ] || [ "$elapsed" -ge 5 ]; then
        echo "  $desc: exit=$code (64 が必要) elapsed=${elapsed}s file=$([ -f "$WORK/$logname.mov" ] && echo あり || echo なし)"
        T20B_FAIL=1
    fi
}
check_hdr_rejected t20b "--codec prores との併用" --hdr --codec prores
check_hdr_rejected t20b2 "--codec h264 との併用" --hdr --codec h264
check_hdr_rejected t20b3 "--no-video との併用" --hdr --no-video
if [ "$T20B_FAIL" = "0" ]; then
    ok "T20b hdr 引数検証: 3 パターンすべて録画前に exit=64・ファイルなし"
else
    bad "T20b hdr 引数検証: 上記の組合せが想定どおりに弾かれていない"
fi

# ---- T21: GUI 通知・Finder 表示・最近の録画・ホットキー (issue #20) --------------
# 通知バナーの表示とクリック、他アプリ前面でのキー押下は自動化できない (Notification
# Center と TCC の状態に依存する)。ここで確かめるのは **kilde 側の責任範囲** —
# 一覧の走査が正しいか、Finder に渡す URL が正しいか、ホットキーを登録できるか。
# 残りは PR の手順で人が確認する
if ! command -v xcodegen >/dev/null 2>&1; then
    skip "T21 GUI 通知/一覧: xcodegen 未導入 (brew install xcodegen で実行可)"
elif ! security find-certificate -c "kilde-dev" >/dev/null 2>&1; then
    skip "T21 GUI 通知/一覧: 署名用証明書 kilde-dev なし (docs/DEVELOPMENT.md §3)"
elif pgrep -x KildeGUI >/dev/null 2>&1; then
    skip "T21 GUI 通知/一覧: KildeGUI が既に起動中のためスキップ"
else
    T21_DIR="$WORK/t21-out"
    mkdir -p "$T21_DIR"
    # 拾うべき 7 件 (上限 5 で切られる)。更新時刻を変えて「新しい順」も確かめる。
    # 名前の日付順とは **わざと逆** にした 1 件を最新にしておく — 名前でソートして
    # いたら先頭が変わるので、更新時刻で並べていることを検出できる
    # touch の失敗は検出する。以前ここに分 99 (不正値) を書いていて touch が失敗し、
    # set -e が無いためファイルは作成時刻のまま残り、**「更新時刻順に並ぶ」ことを
    # 検証できていなかった**。値を直すだけでは同じ穴が残るので、失敗したら落とす
    T21_FIXTURE_OK=1
    for i in 1 2 3 4 5 6; do
        : > "$T21_DIR/kilde-2026091$i-120000.m4a"
        touch -t "20260912120$i" "$T21_DIR/kilde-2026091$i-120000.m4a" || T21_FIXTURE_OK=0
    done
    : > "$T21_DIR/kilde-20260912-999999.mov"
    # 分は 00-59。ここが一覧の先頭に来ることを期待している
    touch -t "202609121259" "$T21_DIR/kilde-20260912-999999.mov" || T21_FIXTURE_OK=0
    # 除外すべきもの: 接頭辞違い / 拡張子違い / 同名のディレクトリ / 隠しファイル。
    # **有効ファイルより新しい固定時刻**にする — 実行時刻のままだと、上限 5 件で
    # 切られた «圏外» に落ちただけでも «除外された» ように見えてしまい、
    # 接頭辞・拡張子・隠しファイル・ディレクトリのフィルタ退行を見逃す
    : > "$T21_DIR/other-20260912-120000.m4a"
    : > "$T21_DIR/kilde-20260912-120000.txt"
    : > "$T21_DIR/.kilde-20260912-120000.m4a"
    mkdir -p "$T21_DIR/kilde-20260912-120000.mov"
    for f in "other-20260912-120000.m4a" "kilde-20260912-120000.txt" \
             ".kilde-20260912-120000.m4a" "kilde-20260912-120000.mov"; do
        touch -t "202609121300" "$T21_DIR/$f" || T21_FIXTURE_OK=0
    done

    if [ "$T21_FIXTURE_OK" != "1" ]; then
        bad "T21 GUI 通知/一覧: フィクスチャの更新時刻を設定できません (touch が失敗)"
    elif (cd "$ROOT/gui" && xcodegen -q > "$WORK/t21-build.log" 2>&1 \
        && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI -configuration Debug build \
           >> "$WORK/t21-build.log" 2>&1); then
        T21_APP=$(cd "$ROOT/gui" && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI \
            -configuration Debug -showBuildSettings 2>/dev/null \
            | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')/KildeGUI.app
        # 実行ファイルを直接起動する (open ではない) — T11 のコメントと同じ理由で、
        # TCC はターミナル側の権限が使われる。この経路は録画しないので権限も不要
        # 設定ファイル経由の解決 (HotkeySettings.resolve) を通す。環境変数で直接
        # キーを渡すと設定の読み込みが検証されず、そこが壊れても緑になる
        T21_CFG_DIR="$WORK/t21-config"
        mkdir -p "$T21_CFG_DIR"
        printf '{"hotkey": "cmd+opt+ctrl+shift+f9"}\n' > "$T21_CFG_DIR/config.json"
        # self-test がハングしても統合テスト全体を止めないよう、バックグラウンドで
        # 起動して制限時間付きで待ち、残っていれば回収する
        KILDE_CONFIG_DIR="$T21_CFG_DIR" KILDE_GUI_SELFTEST_NOTIFY=1 \
            KILDE_GUI_SELFTEST_OUTPUT="$T21_DIR" \
            "$T21_APP/Contents/MacOS/KildeGUI" > "$WORK/t21.log" 2>&1 &
        T21_PID=$!
        T21_EXIT=""
        for _ in $(seq 1 40); do
            if ! kill -0 "$T21_PID" 2>/dev/null; then
                wait "$T21_PID"; T21_EXIT=$?; break
            fi
            sleep 1
        done
        if [ -z "$T21_EXIT" ]; then
            kill -9 "$T21_PID" 2>/dev/null
            wait "$T21_PID" 2>/dev/null
            T21_EXIT="timeout"
        fi
        T21_PID=""
        T21_SCAN=$(grep -m1 "^selftest: scanFinished=" "$WORK/t21.log" | sed 's/.*=//')
        T21_COUNT=$(grep -m1 "^selftest: recentCount=" "$WORK/t21.log" | sed 's/.*=//')
        # 先頭だけでなく 5 件すべての並びを確かめる。先頭しか見ないと、
        # 2 件目以降の順序が崩れる退行を見逃す
        T21_ORDER=$(grep "^selftest: recent=" "$WORK/t21.log" | sed 's/.*=//' | tr '\n' ',')
        T21_ORDER_WANT="kilde-20260912-999999.mov,kilde-20260916-120000.m4a,kilde-20260915-120000.m4a,kilde-20260914-120000.m4a,kilde-20260913-120000.m4a,"
        # revealTarget / revealFallback は **実装本体 (RecordingNotifier.revealTarget)**
        # が決めた値。テスト側で分岐を書き写すと実装の退行を見逃す
        T21_REVEAL=$(grep -m1 "^selftest: revealTarget=" "$WORK/t21.log" | sed 's/^selftest: revealTarget=\(.*\) select=.*/\1/')
        T21_REVEAL_SEL=$(grep -m1 "^selftest: revealTarget=" "$WORK/t21.log" | sed 's/.* select=//')
        T21_FALLBACK=$(grep -m1 "^selftest: revealFallback=" "$WORK/t21.log" | sed 's/^selftest: revealFallback=\(.*\) select=.*/\1/')
        T21_FALLBACK_SEL=$(grep -m1 "^selftest: revealFallback=" "$WORK/t21.log" | sed 's/.* select=//')
        T21_RESOLVED=$(grep -m1 "^selftest: hotkeyResolved=" "$WORK/t21.log" | sed 's/.*=//')
        # Swift 側は /private/var/... を返し、シェルの $WORK は /var/... (シンボリック
        # リンク) なので、**文字列のままでは同じディレクトリでも一致しない**。
        # 比較する前に実体パスへ正規化する
        T21_DIR_REAL=$(cd "$T21_DIR" && pwd -P)
        T21_HOTKEY=$(grep -m1 "^selftest: hotkeyRegistered=" "$WORK/t21.log" | sed 's/.*hotkeyRegistered=\([a-z]*\).*/\1/')
        # 登録できたかだけでなく **どのキーを登録したか** も見る。true しか見ないと、
        # 解決した値と違うキーを登録していても T21 は通ってしまう
        T21_HOTKEY_SOURCE=$(grep -m1 "^selftest: hotkeyRegistered=true" "$WORK/t21.log" | sed 's/.* source=//')
        T21_EXCLUDED=$(grep -c "^selftest: recent=\(other-\|\.kilde\)" "$WORK/t21.log")
        T21_TXT=$(grep -c "^selftest: recent=.*\.txt" "$WORK/t21.log")
        # scanFinished を見るのは «0 件だから空» と «走査が終わっていないから空» を
        # 取り違えないため。件数だけ見ていると、走査が固まっても 0 件として通りうる
        if [ "$T21_EXIT" = "0" ] \
            && [ "$T21_SCAN" = "true" ] \
            && [ "$T21_COUNT" = "5" ] \
            && [ "$T21_ORDER" = "$T21_ORDER_WANT" ] \
            && [ "$T21_REVEAL" = "$T21_DIR_REAL/kilde-20260912-999999.mov" ] \
            && [ "$T21_REVEAL_SEL" = "true" ] \
            && [ "$T21_FALLBACK" = "$T21_DIR_REAL" ] \
            && [ "$T21_FALLBACK_SEL" = "false" ] \
            && [ "$T21_RESOLVED" = "cmd+opt+ctrl+shift+f9" ] \
            && [ "$T21_HOTKEY" = "true" ] \
            && [ "$T21_HOTKEY_SOURCE" = "cmd+opt+ctrl+shift+f9" ] \
            && [ "$T21_EXCLUDED" = "0" ] && [ "$T21_TXT" = "0" ]; then
            ok "T21 GUI 通知/一覧: 上限 5 件・更新時刻の新しい順・混ぜ物 4 件を除外・Finder の対象は実装本体が決定 (実在=選択/欠損=親ディレクトリ)・設定ファイル経由でホットキー登録"
        else
            bad "T21 GUI 通知/一覧: exit=$T21_EXIT scan=$T21_SCAN count=$T21_COUNT hotkey=$T21_HOTKEY/$T21_HOTKEY_SOURCE excluded=$T21_EXCLUDED txt=$T21_TXT resolved=$T21_RESOLVED
  reveal   = [$T21_REVEAL] select=$T21_REVEAL_SEL
  fallback = [$T21_FALLBACK] select=$T21_FALLBACK_SEL
  dir      = [$T21_DIR_REAL]
  hotkey err: $(grep -m1 '^selftest: hotkeyRegistered=false' "$WORK/t21.log" || echo '(なし)')
  order  = $T21_ORDER
  expect = $T21_ORDER_WANT
  — $WORK/t21.log"
        fi
    else
        bad "T21 GUI 通知/一覧: ビルドに失敗 — $WORK/t21-build.log"
    fi
fi

# ---- T22: 準備中の SIGINT はセッションを中断して exit 0 (issue #56) --------------
# 起動直後 (マイク初期化 ~370ms の途中) に SIGINT を送る。#67 の修正により起動直後の
# シグナルは確実に届く。準備中に止まれば出力ファイルは作られず、録画開始後に間に合った
# 場合は T10 と同じ安全停止 (ファイルあり) — どちらも正しい挙動なので exit 0 を検証し、
# ファイルの有無はどちらに解けたかの記録として出力する

log "T22: rec --audio mic — 起動直後の SIGINT でも exit 0 でファイナライズ"
T22_DIR="$WORK/t22"
mkdir -p "$T22_DIR"
(cd "$T22_DIR" && exec "$KILDE" rec --no-video --audio mic --duration 30s \
    > "$WORK/t22.log" 2>&1) &
T22_PID=$!
sleep 0.15
kill -INT $T22_PID 2>/dev/null
# 固まって残ってもスイートを止めないよう期限つきで待つ (T13 と同じ段階的強制)。
# **await_stop であって stop_kilde ではない (issue #101)。** このテストの刺激は
# 「起動直後の SIGINT を 1 通だけ」であり、#67 が保証するのはその 1 通が届くこと。
# 回収の側で INT を送り直すと、1 通目が失われる回帰をこのテストが救ってしまう。
# 役割は recording — 準備中に間に合わなければ通常録画に解け、ファイナライズを待つ
await_stop "$T22_PID" recording
T22_EXIT=$STOP_EXIT
# **回収済みの PID を trap に残さない。** スイートの残りで数百のプロセスが起動するため、
# PID が一周して再利用されると無関係なプロセスに signal を送る。しかもヘルパ化で
# 後始末は「TERM+KILL を 1 発ずつ」から「最大 20 発の SIGINT を 10 秒 + TERM/KILL」に
# 変わっており、取り違えたときの被害が増えている (T23 / T25 と同じ理由・同じ作法)
T22_PID=""
T22_FILES=$(ls "$T22_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T22_EXIT" = "0" ]; then
    if [ "$T22_FILES" = "0" ]; then
        ok "T22 準備中 SIGINT: exit=0・出力ファイルなし (準備フェーズを中断)"
    else
        T22_OUT=$(ls "$T22_DIR" | head -1)
        # ファイルがある経路は「開始後の安全停止に解けた」— 再生可能なファイルが
        # 残っていることまで確認する (空・不完全ファイルを残す回帰を通さない)
        if grep -q "video: absent" <(inspect "$T22_DIR/$T22_OUT") \
            || [ "$(stat -f%z "$T22_DIR/$T22_OUT")" -gt 1024 ]; then
            ok "T22 準備中 SIGINT: exit=0・再生可能なファイル (開始後の安全停止に解けた)"
        else
            bad "T22 準備中 SIGINT: ファイルが空/不完全 — $WORK/t22.log"
        fi
    fi
else
    bad "T22 準備中 SIGINT: exit=$T22_EXIT — $WORK/t22.log"
fi

# ---- T24: devices を併走させても rec が失敗しない (issue #90)
# `SCShareableContent` の列挙と SCK の起動が重なると、**起動側が
# `SCStream.startCapture()` で -3801 (TCC 拒否) を受けて即座に失敗する**。
# **権限拒否ではない** — Recorder は startCapture() の手前で
# Permissions.hasScreenCapture を確認済みで、権限が無ければそこで終了コード 2 になる。
# 修正前の実測 (条件を交互に各 10 回): **devices 併走で 7/10 失敗、単独では 0/10**。
#
# **1 組では足りない。** 修正前でも 3/10 は成功するので、1 回通っても回帰が無い証拠に
# ならない。5 組なら修正前を見逃す確率は 0.3^5 ≈ 0.2% で、門として機能する。
# #70 (T18b) と違って**固まらない**ので、期限つきの待ちは要らない (失敗は即座に返る)。

log "T24: devices 併走 — 列挙と SCK 起動が重なっても rec が失敗しない"
T24_ROUNDS=5
T24_NG=0
T24_TCC=0
T24_DETAIL=""
T24_DIR="$WORK/t24"
mkdir -p "$T24_DIR"
for T24_ROUND in $(seq 1 "$T24_ROUNDS"); do
    T24_DEV_LOG="$WORK/t24-devices-$T24_ROUND.log"
    : > "$T24_DEV_LOG"
    # 列挙を先に出してから録画を始める — 危険なのは列挙と**起動**が重なる瞬間なので、
    # devices (実測 0.2 秒) が rec の起動区間 (実測 0.31 秒) に被る順序にする
    "$KILDE" devices > "$T24_DEV_LOG" 2>&1 &
    T24_DEVICES_PID=$!
    # **同期信号は入れない (CodeRabbit の指摘を実測のうえ一部見送り)。**
    #
    # 「devices が rec の起動前に終わる経路を防げない」という指摘は理屈としては正しい。
    # だが実装できる同期が無く、無理に入れると門が弱くなる:
    #
    #   - `devices` は**列挙が終わってから** "== displays ==" を出す
    #     (実測: 全体 0.17 秒 / 起動のみ 0.02 秒 → 列挙は約 0.15 秒)。
    #     この行を待ってから rec を起動すると devices は終了間際で、**重なりが減る**
    #   - `devices` を回し続けて確実に重ねる案は、**rec がハングした** (issue #95。
    #     修正前バイナリで 1 回目から `Recorder.swift:494` の completionCondition 待ちで
    #     65 秒停止)。スイートが無言で止まるので採れない
    #
    # **同期なしで門になることを実測で確認した**: #90 修正前のバイナリ (5b22465) に
    # この形で 5 回当てて **4/5 が -3801 で失敗**。回帰は捕まる
    "$KILDE" rec --no-video --duration 2 --output "$T24_DIR/t24-$T24_ROUND.m4a" \
        > "$WORK/t24-rec-$T24_ROUND.log" 2>&1
    T24_EXIT=$?
    # **devices の終了コードも見る。** 捨てると、列挙側が落ちても rec さえ成功すれば
    # T24 が通ってしまう (このテストは両者が併走して**双方無事**であることを見る)。
    #
    # **期限つきで待つ。** 無期限の `wait` だと、`devices` が固まったときに
    # スイート全体が無言で止まる。列挙は実測 0.2 秒、ロック待ちを含めても
    # 3 秒 (enumerationTimeout) なので、10 秒あれば正常時は必ず終わる。
    #
    # **ここは stop_kilde / await_stop に寄せない (issue #101)。** 理由は 2 つ:
    #   - `devices` は録画もシグナル処理もしないので、INT も TERM も意味がない
    #     (安全停止ハンドラを持たない = ヘルパの「録画しているか」という軸に乗らない)
    #   - 終わらなかったことを **137 として記録して失敗に数える**のがここの目的で、
    #     TERM で綺麗に終わらせると所見が消える (T18b と同じ考え方)
    T24_DEV_DEADLINE=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$T24_DEV_DEADLINE" ] && kill -0 "$T24_DEVICES_PID" 2>/dev/null; do
        sleep 0.2
    done
    if kill -0 "$T24_DEVICES_PID" 2>/dev/null; then
        kill -KILL "$T24_DEVICES_PID" 2>/dev/null
        wait "$T24_DEVICES_PID" 2>/dev/null
        T24_DEV_EXIT=137
        T24_DETAIL="$T24_DETAIL [組$T24_ROUND devices が 10 秒で終わらず KILL]"
    else
        wait "$T24_DEVICES_PID" 2>/dev/null
        T24_DEV_EXIT=$?
    fi
    T24_DEVICES_PID=""
    # -3801 かどうかを分けて数える。他の理由の失敗 (環境起因の -3818 など) と
    # 混ぜると、#90 の回帰なのか環境なのかが判定から読み取れなくなる
    if grep -q "Code=-3801" "$WORK/t24-rec-$T24_ROUND.log" 2>/dev/null; then
        T24_TCC=$((T24_TCC+1))
    fi
    if [ "$T24_EXIT" != "0" ]; then
        T24_NG=$((T24_NG+1))
        T24_DETAIL="$T24_DETAIL [組$T24_ROUND rec exit=$T24_EXIT]"
    fi
    if [ "$T24_DEV_EXIT" != "0" ]; then
        T24_NG=$((T24_NG+1))
        T24_DETAIL="$T24_DETAIL [組$T24_ROUND devices exit=$T24_DEV_EXIT — $T24_DEV_LOG]"
    fi
done
# **判定を 3 つに分ける (T18b が #95 に対して取っている形と同じ)。**
#
# 列挙を直列化しても **約 1.8% が -3801 で残る** (issue #99。修正後 110 試行中 2 件)。
# 全組を必須にすると、5 組がすべて通る確率は 91.3% なので **約 8.7% の頻度で
# 無関係な PR まで赤くなる**。一方で緩めすぎると回帰を見逃す。そこで:
#
#   - **2 組以上で -3801** → #90 の回帰。`bad`
#   - **1 組だけ -3801** → #99 の残存。`skip` (#99 が閉じたらこの分岐を bad に上げること)
#   - **-3801 以外の失敗** → 環境かコードの別の問題。従来どおり `bad`
#
# **閾値を「全組」ではなく「2 組以上」に置く。** 全組だけを bad にすると、
# **修正前バイナリで実測した 4/5 の回帰が skip になって素通りします** (CodeRabbit の指摘)。
# 一方 2 組以上なら:
#   - 残存 1.8% で 5 組中 2 件以上が出る確率は **約 0.31%** (320 回に 1 回) — 誤検知は許容範囲
#     (二項分布で P(0)=91.32%, P(1)=8.37% なので P(>=2)=0.31%。実測の 2/110=1.82% でも 0.32%)
#   - 修正前 (実測 70〜80%) なら 2 件以上はほぼ確実 — 回帰は捕まる
if [ "$T24_TCC" -ge 2 ]; then
    bad "T24 devices 併走: ${T24_ROUNDS} 組中 $T24_TCC 組で -3801 (列挙が SCK 起動ロックの外に出ている。issue #90 の回帰を疑う。残存 #99 なら 5 組中 2 件以上は約 0.31% でしか起きない)$T24_DETAIL"
elif [ "$T24_NG" != "$T24_TCC" ]; then
    # -3801 以外の理由でも落ちている (NG が TCC を上回る = devices 側の失敗を含む)
    bad "T24 devices 併走: ${T24_ROUNDS} 組中 $T24_NG 件が失敗 (うち -3801 は $T24_TCC 件)。-3801 以外の原因を調べること — $WORK/t24-rec-*.log$T24_DETAIL"
elif [ "$T24_TCC" != "0" ]; then
    skip "T24 devices 併走: ${T24_ROUNDS} 組中 1 組で -3801 (issue #99 の残存。約 1.8% で起きる。#99 が閉じたらこの分岐を bad に上げること)$T24_DETAIL"
else
    ok "T24 devices 併走: ${T24_ROUNDS}/${T24_ROUNDS} 組で rec が exit=0 (-3801 なし)"
fi

# ---- T25: 設定 hotkey + --duration は待機に入り、警告を出す (issue #97)
# `--duration` は**待機の解除後**から数えるので、設定に hotkey があると
# 「N 秒で終わるはずのコマンドが帰ってこない」ことになる。これは仕様だが、
# **黙って待たれると無人実行が詰まる** (#90 の計測中に 8 分間ハングと誤認した)。
# 設定由来のときだけ WARNING を出すことにしたので、それを固定する。
#
# **このテストが固定するのは「待ち続けること」**。#97 の受け入れ条件は
# 「非対話実行で無期限に待ち続けることがない」だったが、**決めた挙動は
# 「待機は維持し、WARNING で気づけるようにする」**なので、ここで assert するのは
# **`< /dev/null` でも待機が終わらないこと**になる (DESIGN.md「`--duration` と待機モード」)。
# 待機は RunLoop で待ち stdin を見ないため、`meeting` の対話選択が EOF で終了コード 1 に
# なるのとは事情が違う (あちらは入力を要求している)。
#
# T23 と同じくキーを分ける — 取り違えると「実は誰も握っていない」状態を緑と誤認する

log "T25: 設定 hotkey + --duration — 待機に入り警告を出す (非対話でも待ち続ける)"
T25_KEY="cmd+opt+ctrl+shift+f8"
T25_DIR="$WORK/t25"
T25_CFG_DIR="$WORK/t25-config"
mkdir -p "$T25_DIR" "$T25_CFG_DIR"
printf '{"hotkey": "%s"}\n' "$T25_KEY" > "$T25_CFG_DIR/config.json"
# **stdin を /dev/null にする** — 端末が無くても待機が終わらないことを見るため。
# exec で置き換えるのは kill を kilde 本体に届かせるため (T13 と同じ)
# **stdout と stderr を分けて取る。** 結合すると「WARNING が stderr に出ている」ことを
# 検証できず、stdout に出ても緑になる。実装と DESIGN.md は WARNING を stderr、
# 「待機中」を stdout と定めているので、テストもその区別を見る (CodeRabbit の指摘)
( cd "$T25_DIR" && exec env KILDE_CONFIG_DIR="$T25_CFG_DIR" "$KILDE" \
    rec --no-video --duration 2 > "$WORK/t25-out.log" 2> "$WORK/t25-err.log" < /dev/null ) &
T25_PID=$!
# **猶予は T23 と揃えて 15 秒**。待機に入らず即時録画へ縮退した場合の所要は
# 実測 4 秒前後 (SCK 起動 + 2 秒録画 + ファイナライズ) だが、**起動には
# SCKStartupLock の待機が最大 15 秒乗りうる** (#70 / #90)。6 秒では、
# 並行する録画とロックを取り合っただけで「待機に入っていない」と誤判定する
T25_WAITED=0
for _ in $(seq 1 30); do
    kill -0 "$T25_PID" 2>/dev/null || break
    T25_WAITED=$((T25_WAITED + 1))
    sleep 0.5
done
if kill -0 "$T25_PID" 2>/dev/null; then
    T25_STILL_WAITING=1
else
    T25_STILL_WAITING=0
fi
# **SIGINT を 1 回送って 1 秒で TERM へ進めない。** 下で exit=0 を必須にしている以上、
# ここの猶予が判定の土台になる。stop_kilde は終了を確認するまで INT を送り直す —
# installStopSignalHandler の設置前に届いた SIGINT は失われうるため。
#
# **役割は recording** — 待機中なら何も書いていないが、#80 の縮退で即時録画に入って
# いる可能性があり、そちらだとファイナライズに時間がかかる (EXIT trap 側と同じ理由)。
# waiting の 5 秒では、縮退していた回に未完了ファイルを残しかねない。
#
# **INT だけで終わったかを記録する (T25_STOPPED_BY_INT ← STOP_BY_INT)。** 終了コード
# だけでは SIGINT の回帰を検出できない — **SIGTERM も SIGINT と同じ安全停止ハンドラに
# 繋がる**ので (KildeCommand.installStopSignalHandler)、INT だけが壊れても TERM への
# 昇格で exit 0 になり、`T25_EXIT != 0` のゲートを素通りしてしまう。終了コードで
# 捕まるのはシグナル経路が丸ごと死んだ場合 (KILL → 137) だけ
stop_kilde "$T25_PID" recording
T25_STOPPED_BY_INT=$STOP_BY_INT
T25_EXIT=$STOP_EXIT
T25_PID=""
T25_FILES=$(ls "$T25_DIR" 2>/dev/null | wc -l | tr -d ' ')
T25_WARN=0
# WARNING は **stderr** から見る (実装が FileHandle.standardError に書く契約)
grep -q "WARNING:.*待機モード" "$WORK/t25-err.log" 2>/dev/null && T25_WARN=1
T25_WAITING_SHOWN=0
# 「待機中」は **stdout** から見る (print で出る。T13 も stdout のこの行を待っている)
grep -q "待機中" "$WORK/t25-out.log" 2>/dev/null && T25_WAITING_SHOWN=1
# **縮退したかを先に見る。** 他プロセスが f8 を握っていると #80 の縮退で即時録画になり、
# そのとき #97 の WARNING は (待機しないので) 正しく出ない。これを「警告が失われている」と
# 診断すると原因を取り違える — 実際はキーの取り合いで、このテストの前提が崩れている
T25_DEGRADED=0
# 縮退の警告 (#80) も stderr
grep -q "WARNING: ホットキー" "$WORK/t25-err.log" 2>/dev/null && T25_DEGRADED=1

if [ "$T25_DEGRADED" = "1" ]; then
    bad "T25 hotkey+duration: ホットキー $T25_KEY を他プロセスが握っており縮退した (このテストの前提が崩れている。孤児が残っていないか確認すること) — $WORK/t25-out.log と $WORK/t25-err.log"
elif [ "$T25_STILL_WAITING" != "1" ]; then
    # --duration で終わってしまった = 待機に入っていない。仕様が変わったか縮退した
    bad "T25 hotkey+duration: 待機に入らず $((T25_WAITED / 2)) 秒で終了した (exit=$T25_EXIT)。設定の hotkey が効いていないか、待機の判定が変わった — $WORK/t25-out.log と $WORK/t25-err.log"
elif [ "$T25_WARN" != "1" ]; then
    bad "T25 hotkey+duration: 待機には入ったが WARNING が出ていない (issue #97 の警告が失われている) — $WORK/t25-out.log と $WORK/t25-err.log"
elif [ "$T25_WAITING_SHOWN" != "1" ]; then
    bad "T25 hotkey+duration: WARNING は出たが「待機中」の表示がない (登録に失敗している) — $WORK/t25-out.log と $WORK/t25-err.log"
elif [ "$T25_FILES" != "0" ]; then
    bad "T25 hotkey+duration: 待機中なのに出力ファイルが $T25_FILES 個ある — $T25_DIR"
elif [ "$T25_STOPPED_BY_INT" != "1" ]; then
    # **終了コードだけでは SIGINT の回帰を捕まえられない。** `installStopSignalHandler` は
    # SIGINT / SIGTERM / SIGHUP を**同じ handler** に繋ぐので、INT だけが壊れても
    # TERM への昇格で exit 0 になり、`$T25_EXIT` を見るだけでは緑になってしまう。
    # **INT のループ内で終了したか**を見て初めて、T13 が守る契約の回帰を検出できる
    bad "T25 hotkey+duration: 待機中の SIGINT で終了しなかった (TERM/KILL への昇格が必要だった。exit=$T25_EXIT)。待機中 Ctrl+C = exit 0 の契約 (DESIGN.md §6) の回帰を疑う — $WORK/t25-out.log と $WORK/t25-err.log"
elif [ "$T25_EXIT" != "0" ]; then
    # INT で終わったのに非ゼロ = ファイナライズや後始末の失敗
    bad "T25 hotkey+duration: SIGINT で終了したが exit=$T25_EXIT (0 が契約) — $WORK/t25-out.log と $WORK/t25-err.log"
else
    ok "T25 hotkey+duration: 非対話でも待機に入り、WARNING を出し、ファイルを作らず、SIGINT で exit=0"
fi

# ---- サマリ -------------------------------------------------------------------

echo ""
echo "======================================"

echo " 統合テスト結果:  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "======================================"
[ "$FAIL" = "0" ]
