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

cleanup() {
    if [ "$MONITOR_SET_UP" = "1" ]; then
        "$KILDE" audio monitor teardown >/dev/null 2>&1 && echo "[cleanup] 既定出力を復元しました"
    fi
    [ -n "$SOUNDAPP_PID" ] && kill "$SOUNDAPP_PID" 2>/dev/null
    echo ""
    echo "作業ディレクトリ (失敗時の調査用に残します): $WORK"
}
trap cleanup EXIT

# 設定ファイル (~/.kilde/config.json) と KILDE_OUTPUT_DIR は rec の既定値を変える (issue #14)。
# T3 / T4b / T5 などは「既定 = system / mixed」を前提にしているため、環境変数は外し、
# 設定ファイルがある場合は失敗の原因として気付けるよう警告する (ユーザーの設定は書き換えない)
unset KILDE_OUTPUT_DIR
if [ -f "$HOME/.kilde/config.json" ]; then
    printf '\033[33mWARNING\033[0m  %s が存在します。rec の既定値が変わるため既定値を前提とするテストが失敗しえます (`kilde config show` で確認)\n' "$HOME/.kilde/config.json"
fi

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

# ---- サマリ -------------------------------------------------------------------

echo ""
echo "======================================"
echo " 統合テスト結果:  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "======================================"
[ "$FAIL" = "0" ]
