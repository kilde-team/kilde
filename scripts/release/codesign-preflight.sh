#!/bin/bash
#
# codesign-preflight.sh — MAS アーカイブ前の署名鍵アクセス確認 (bounded / fail-fast)
#
# issue #470 / #633: m1 ランナーの mas.yml upload が «CodeSign の鍵使用時
# (ACL / partition-list の対話認証待ち) で codesign が沈黙 → watchdog が無出力
# 12 分で打ち切り → job 上限級の停滞» を 0.42.0 以降繰り返した。0.48.0 (issue #623)
# の観測性改善で «鍵は見える (find-identity -v)・キーチェーンは no-timeout» まで
# 確定しており、沈黙は «署名で鍵を使うとき» に起きる。そこで Archive and upload の
# **前** に、キーチェーンの有効な codesigning identity で実際に 1 件ずつ
# bounded に署名を試す:
#   - 正常系: 署名が数秒で完了 → «鍵は使える» としてアーカイブに進む
#   - 異常系 (沈黙): 上限秒で打ち切り → «鍵アクセス起因» と分かる診断を出して即失敗。
#     12 分の沈黙と 70 分級の停滞を数分以内の合否に縮め、即時フォールバック
#     (docs/RELEASE.md §7 «停滞時の即時フォールバック») への切り替えを早める
#
# 秘密情報の扱いを変えない (原則): ここで行うのは読み取り系の診断
# (security find-identity / show-keychain-info / ps) と、**一時ディレクトリに置いた
# probe ファイルへの署名 1 回のみ**。証明書の失効・新規作成、鍵素材や
# partition-list の変更はしない (m1 実機での恒久対処はオーナー判断事項 — #470)。
# probe ファイルは mktemp -d の一時ディレクトリに作り、終了時に必ず消す。
#
# 終了コード:
#   0  正常 (少なくとも 1 個の identity で署名が完了)
#   1  失敗 (有効な identity が無い / すべての identity で即時エラー — アーカイブも
#      失敗するため早めに落とす)
#   2  失敗 (署名が沈黙し上限で打ち切り — issue #470 の ACL 待ちの兆候。
#      アーカイブに進めても同位置で沈黙するため fail-fast する)
#
# 使い方:
#   scripts/release/codesign-preflight.sh
#   PREFLIGHT_PROBE_SEC=60 scripts/release/codesign-preflight.sh
#   scripts/release/codesign-preflight.sh --self-test   # bounded 機構の単体確認
#
# 環境変数:
#   PREFLIGHT_PROBE_SEC    1 identity あたりの署名試行の上限秒 (既定 90。
#                          «数分以内» の合否に収めるための値 — 5 identity でも
#                          全部沈黙すれば 7.5 分で確定する)
#   PREFLIGHT_SECURITY_SEC 診断コマンド 1 回の上限秒 (既定 15 — mas.yml の
#                          watchdog 打ち切り診断と同じ。ロック状態のキーチェーンで
#                          security 系が沈黙しても診断自体が停滞しないため)

set -u

PROBE_SEC="${PREFLIGHT_PROBE_SEC:-90}"
SEC_SEC="${PREFLIGHT_SECURITY_SEC:-15}"

# --- bounded 実行ヘルパ -------------------------------------------------------
# mas.yml の watchdog 打ち切り診断 (run_bounded) と同じ方針: コマンドを子プロセスで
# 出し、上限秒で kill する。タイムアウト時は 124 を返す (timeout(1) の規約に合わせる)。
# SIGKILL (137) で死んだものは打ち切りとみなす — «kill -9 された» 以外の 137 は
# codesign の通常の終了コードに無い (実害は打ち切り誤認のみ)
bounded() {
  local limit="$1" out="$2" p w rc
  shift 2
  "$@" >"$out" 2>&1 &
  p=$!
  ( sleep "$limit"; kill -9 "$p" 2>/dev/null ) &
  w=$!
  wait "$p" 2>/dev/null
  rc=$?
  kill "$w" 2>/dev/null
  # タイマーの子シェルだけを kill するとその子の sleep が残るため、子も殺してから
  # 待ち合わせる (mas.yml の実装と同じ — 孤児を残さない)
  pkill -P "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  [ "$rc" -eq 137 ] && rc=124
  cat "$out"
  return "$rc"
}

# --- self-test (bounded 機構の確認 — m1 を触らずに異常系を検証する) -----------
self_test() {
  local tmp rc t0 t1 fail=0
  tmp="$(mktemp)"
  echo "[self-test] bounded: 正常系 (true) を確認します"
  if bounded "$SEC_SEC" "$tmp" true >/dev/null 2>&1; then
    echo "[self-test] PASS: 正常系は即時の rc=0"
  else
    echo "[self-test] FAIL: 正常系が失敗した"
    fail=1
  fi
  echo "[self-test] bounded: 異常系 (sleep 300 → 上限 3 秒で打ち切り) を確認します"
  t0=$SECONDS
  bounded 3 "$tmp" sleep 300 >/dev/null 2>&1
  rc=$?
  t1=$((SECONDS - t0))
  if [ "$rc" -eq 124 ] && [ "$t1" -le 6 ]; then
    echo "[self-test] PASS: 異常系は rc=124 / 実時間 ${t1} 秒で bounded に打ち切られた"
  else
    echo "[self-test] FAIL: rc=$rc / 実時間 ${t1} 秒 (rc=124 かつ 6 秒以内が期待値)"
    fail=1
  fi
  rm -f "$tmp"
  if [ "$fail" -eq 0 ]; then
    echo "[self-test] 結果: PASS"
    return 0
  fi
  echo "[self-test] 結果: FAIL"
  return 1
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") ;;
  *) echo "使い方: codesign-preflight.sh [--self-test]" >&2; exit 64 ;;
esac

# --- 対象 identity の列挙 -----------------------------------------------------
# 有効な codesigning identity (-v = private key 付きのみ)。security 自体が
# 沈黙する可能性 (ロック状態のキーチェーン) に備え、こちらも bounded で出す
ID_TMP="$(mktemp)"
if ! bounded "$SEC_SEC" "$ID_TMP" security find-identity -v -p codesigning; then
  RC=$?
  if [ "$RC" -eq 124 ]; then
    echo "[preflight] 失敗: security find-identity が ${SEC_SEC} 秒で応答せず (キーチェーンアクセスの沈黙)"
    echo "[preflight] この状態ではアーカイブの署名も沈黙するため、Archive に進めず失敗させます"
    rm -f "$ID_TMP"
    exit 1
  fi
  echo "[preflight] 失敗: security find-identity がエラー終了 (rc=$RC)"
  rm -f "$ID_TMP"
  exit 1
fi
IDENT_RAW="$(cat "$ID_TMP")"
rm -f "$ID_TMP"
echo "[preflight] 有効な codesigning identity の一覧:"
echo "$IDENT_RAW" | sed 's/^/[preflight]   /'

# ハッシュ (40 桁の 16 進) を抽出する。find-identity の集計行 («N valid identities
# found») にはハッシュが無いため自然に除外される
IDENTS="$(echo "$IDENT_RAW" | grep -Eo '[0-9A-F]{40}' | sort -u || true)"
if [ -z "$IDENTS" ]; then
  echo "[preflight] 失敗: private key 付きの有効な codesigning identity が 1 件も無い"
  echo "[preflight] アーカイブのクラウド署名 (ASC API キー) が identity を作る可能性はあるが、"
  echo "[preflight] 既存鍵が見えない状態は #470 の別系統の異常として続行しない"
  exit 1
fi

# --- probe ファイルの準備 ------------------------------------------------------
# 署名対象はリポジトリ・鍵と無関係な一時コピー (/bin/echo の Mach-O)。
# アーカイブ本体がネスト署名で使うのと同じオプション
# (--generate-entitlement-der --strip-disallowed-xattrs) を付けて、
# «鍵の使用» の経路を実アーカイブに揃える
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codesign-preflight.XXXXXX")"
PROBE_FILE="$PROBE_DIR/probe-macho"
cleanup() {
  # 一時ディレクトリは必ず消す («中止時は確定ファイルを書かない» 契約の準拠 —
  # このスクリプトは確定ファイルを一切書かない)
  rm -rf "$PROBE_DIR" 2>/dev/null
  # 沈黙した probe の codesign は必ず殺す (打ち切り漏れの孤児を作らない —
  # 0.48.0 の [proc] 診断で «PPID 1 の孤児が蓄積» が実測されている)。
  # スコープはこのスクリプトの probe ファイルのみ — ランナー上の他の
  # codesign (eyechecker ランナー由来の孤児など) には触れない
  pkill -f "codesign .*$PROBE_FILE" 2>/dev/null
  return 0
}
trap cleanup EXIT
cp /bin/echo "$PROBE_FILE" 2>/dev/null || {
  echo "[preflight] 失敗: probe ファイル (/bin/echo のコピー) を作れません"
  exit 1
}

# --- 各 identity を bounded に署名してみる ------------------------------------
OVERALL_START=$SECONDS
OK_COUNT=0
TIMEOUT_HASHES=""
ERR_HASHES=""

for HASH in $IDENTS; do
  echo "[preflight] probe: codesign --force --sign $HASH --generate-entitlement-der --strip-disallowed-xattrs <probe> (上限 ${PROBE_SEC} 秒)"
  OUT_TMP="$(mktemp)"
  bounded "$PROBE_SEC" "$OUT_TMP" \
    codesign --force --sign "$HASH" --generate-entitlement-der \
    --strip-disallowed-xattrs "$PROBE_FILE"
  RC=$?
  cat "$OUT_TMP" | sed 's/^/[preflight]   /'
  rm -f "$OUT_TMP"
  case "$RC" in
    0)
      echo "[preflight] → OK (identity $HASH はこのセッションから非対話で使える)"
      OK_COUNT=$((OK_COUNT + 1))
      ;;
    124)
      echo "[preflight] → 沈黙: 上限 ${PROBE_SEC} 秒で応答が無く打ち切り (rc=124)"
      TIMEOUT_HASHES="$TIMEOUT_HASHES $HASH"
      ;;
    *)
      echo "[preflight] → エラー終了 (rc=$RC) — 沈黙ではなく即時の失敗 (失効・不一致など)"
      ERR_HASHES="$ERR_HASHES $HASH"
      ;;
  esac
done

# --- 判定 ---------------------------------------------------------------------
# «沈黙» が 1 件でもあれば fail-fast する: アーカイブの xcodebuild は identity を
# 自動選択するため、沈黙する鍵がキーチェーンに 1 個でも残っていると
# «それを拾ったときに» 同位置で沈黙する (0.47.0/0.49.0 の実跡 — 選択は毎回同じ
# F6283AA3… に落ちている)。逆にすべての鍵が非対話で使えるならアーカイブも進む
if [ -n "$TIMEOUT_HASHES" ]; then
  echo "[preflight] 判定: **失敗 (fail-fast)** — 署名が沈黙した identity:$TIMEOUT_HASHES"
  echo "[preflight] 原因: codesign が署名鍵の使用時に securityd の対話認証待ちで止まっている"
  echo "[preflight] (issue #470 の残仮説: 鍵使用時の ACL / partition-list 認証。0.48.0 の診断で"
  echo "[preflight]  «鍵の可視性 OK・キーチェーン no-timeout» 済み — 沈黙は鍵の «使用時» に起きる)"
  echo "[preflight] この状態で Archive and upload に進むと同位置で沈黙し、watchdog の無出力"
  echo "[preflight] ${MAS_UPLOAD_IDLE_LIMIT_MIN:-12} 分を消してから失敗になるため、ここで即失敗させる"
  # --- 診断 (読み取りのみ・それぞれ bounded) — «鍵アクセス起因» をログだけで追えるように
  KC_TMP="$(mktemp)"
  for kc in "$HOME/Library/Keychains/login.keychain-db" "$HOME/Library/Keychains/login.keychain"; do
    [ -f "$kc" ] || continue
    bounded "$SEC_SEC" "$KC_TMP" security show-keychain-info "$kc" >/dev/null 2>&1
    sed "s/^/[preflight] [keychain] /" "$KC_TMP"
    break
  done
  bounded "$SEC_SEC" "$KC_TMP" security find-identity -v -p codesigning >/dev/null 2>&1
  sed "s/^/[preflight] [identity] /" "$KC_TMP"
  rm -f "$KC_TMP"
  echo "[preflight] [proc] 沈黙中の codesign (probe 分は終了済み。PPID 1 の古い孤児が居れば併記):"
  ps -o pid,ppid,stat,etime,command -ax 2>/dev/null \
    | grep -E "[c]odesign" | cut -c1-200 | sed 's/^/[preflight] [proc] /' \
    || echo "[preflight] [proc] codesign プロセスは見つかりません"
  echo "[preflight] 対処 (オーナー操作 — m1 実機): 鍵への非対話アクセスを許可する"
  echo "[preflight]   security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <ログインパスワード> ~/Library/Keychains/login.keychain-db"
  echo "[preflight]   (または GUI セッションで 1 回署名を承認。鍵素材・証明書の変更はしない)"
  echo "[preflight] 提出の継続 (即時フォールバック — docs/RELEASE.md §7):"
  echo "[preflight]   scripts/release/appstore-archive.sh --version <VERSION> --build <BUILD> --upload  (macmini-m4、Admin 鍵のクラウド署名)"
  exit 2
fi

if [ "$OK_COUNT" -eq 0 ]; then
  echo "[preflight] 判定: 失敗 — 有効な identity がすべて即時エラーで使えない:$ERR_HASHES"
  echo "[preflight] (沈黙は無く、鍵アクセス待ちの兆候は無い。アーカイブも同理由で失敗するため"
  echo "[preflight]  ここで落とす。エラー内容は上の probe 出力を参照)"
  exit 1
fi

echo "[preflight] 判定: OK — ${OK_COUNT} 個の identity が非対話で使える (経過 $((SECONDS - OVERALL_START)) 秒)。"
echo "[preflight] エラー終了した identity (アーカイブが自動選択しない可能性あり):${ERR_HASHES:- なし}"
echo "[preflight] Archive and upload に進みます"
exit 0
