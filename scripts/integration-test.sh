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

cleanup() {
    if [ "$MONITOR_SET_UP" = "1" ]; then
        "$KILDE" audio monitor teardown >/dev/null 2>&1 && echo "[cleanup] 既定出力を復元しました"
    fi
    [ -n "$SOUNDAPP_PID" ] && kill "$SOUNDAPP_PID" 2>/dev/null
    if [ -n "${CONFIG:-}" ]; then
        rm -f "$CONFIG"
    fi
    # T11 の GUI プロセスもどの分岐で失敗しても残さない
    [ -n "$GUI_PID" ] && kill "$GUI_PID" 2>/dev/null
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
# スイート全体が無言でハングする — SIGINT 後 5 秒生きていたら段階的に強制する
T13_EXIT=-1
for _ in $(seq 1 10); do
    if ! kill -0 $T13_PID 2>/dev/null; then break; fi
    sleep 0.5
done
if kill -0 $T13_PID 2>/dev/null; then
    kill -TERM $T13_PID 2>/dev/null
    sleep 1
    kill -0 $T13_PID 2>/dev/null && kill -KILL $T13_PID 2>/dev/null
fi
wait $T13_PID
T13_EXIT=$?
T13_FILES=$(ls "$T13_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T13_READY" = "1" ] && [ "$T13_EXIT" = "0" ] && [ "$T13_FILES" = "0" ]; then
    ok "T13 hotkey 待機中止: exit=0・出力ファイルなし"
else
    bad "T13 hotkey 待機中止: ready=$T13_READY exit=$T13_EXIT files=$T13_FILES — $WORK/t13.log"
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

# ---- T18: 既定出力名の原子的な予約 -------------------------------------------

log "T18: 既定出力名 — 同名ファイルがあれば -2 に逃がす"
T18_DIR="$WORK/t18"
mkdir -p "$T18_DIR"
# コマンド起動中に秒境界をまたいでも衝突候補が必ずあるよう、直近数秒ぶんを予約しておく。
# 既存の 0 バイトファイルも他人の所有物として残すことを同時に検証する。
for OFFSET in 0 1 2 3 4; do
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
# 注意: 2 プロセスが同時に SCK のシステム音声を開始するとセッションが固まる
# 既知の問題がある (issue #70 — duration を過ぎても停止しない/開始が完了しない)。
# そのため exit コードは検証せず、「予約の取り合いで元ファイルが消えない」ことと、
# 固まった場合でもテストが進むことを保証するタイムアウトを主眼に置く

log "T18b: 既定名 — 同秒の 2 本同時起動で互いのファイルを消さない"
T18B_DIR="$WORK/t18b"
mkdir -p "$T18B_DIR"
# 次の秒の先頭まで待ってから同時に出す (date +%N は BSD date に無いため python3 で)
T18B_WAIT=$(python3 -c 'import time; print(max(0.05, 1.02 - (time.time() % 1.0)))')
sleep "$T18B_WAIT"
(cd "$T18B_DIR" && "$KILDE" rec --no-video --duration 3s > "$WORK/t18b-1.log" 2>&1) &
T18B_PID1=$!
(cd "$T18B_DIR" && "$KILDE" rec --no-video --duration 3s > "$WORK/t18b-2.log" 2>&1) &
T18B_PID2=$!
# 固まり (issue #70) でもスイートが無言で止まらないよう、期限つきで待つ
T18B_GRACE=25  # duration 3s + 余裕
T18B_DEADLINE=$(( $(date +%s) + T18B_GRACE ))
while [ "$(date +%s)" -lt "$T18B_DEADLINE" ] \
      && { kill -0 $T18B_PID1 2>/dev/null || kill -0 $T18B_PID2 2>/dev/null; }; do
    sleep 1
done
for pid in $T18B_PID1 $T18B_PID2; do
    if kill -0 $pid 2>/dev/null; then
        kill -TERM $pid 2>/dev/null
        sleep 1
        kill -0 $pid 2>/dev/null && kill -KILL $pid 2>/dev/null
    fi
done
wait $T18B_PID1 2>/dev/null; T18B_EXIT1=$?
wait $T18B_PID2 2>/dev/null; T18B_EXIT2=$?
# 検証の主眼: 予約の取り合いで「先に確保した名前のファイルが他方に削除されない」こと。
# 片方が固まって 0 バイトのままでも、名前が片寄らず両方残っていれば保護は機能している
T18B_NAMES=$(ls "$T18B_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T18B_NAMES" = "2" ]; then
    ok "T18b 同時起動: 2 つの名前が共存 (exit=$T18B_EXIT1/$T18B_EXIT2, ls: $(cd "$T18B_DIR" && ls | tr '\n' ' '))"
else
    bad "T18b 同時起動: 名前数=$T18B_NAMES (2 が必要) exit=$T18B_EXIT1/$T18B_EXIT2 — $WORK/t18b-1.log $WORK/t18b-2.log"
fi

# ---- サマリ -------------------------------------------------------------------

echo ""
echo "======================================"
echo " 統合テスト結果:  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "======================================"
[ "$FAIL" = "0" ]
