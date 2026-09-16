#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUI_DIR="$ROOT_DIR/gui"
SCHEME="KildeGUI-AppStore"

# App Store Connect API キー (Apple Developer サイトの「ユーザとアクセス → 統合」で
# 発行する .p8)。xcodebuild -allowProvisioningUpdates が証明書・プロファイルの
# 自動作成に、-exportArchive のアップロードに使う。sign.sh と同じ変数名にしてある
KEY_PATH="${AC_API_KEY:-}"
KEY_ID="${AC_API_KEY_ID:-}"
ISSUER="${AC_API_ISSUER:-}"
TEAM_ID="${KILDE_TEAM_ID:-4B873Q67MK}"
OUTPUT_DIR="${KILDE_APPSTORE_OUTPUT_DIR:-$ROOT_DIR/dist/appstore}"
STAMP_VERSION=""
STAMP_BUILD=""
UPLOAD=false

usage() {
    cat <<'EOF'
Usage: scripts/release/appstore-archive.sh [options]

KildeGUI-AppStore (App Store 配布ビルド、issue #126) をアーカイブし、
App Store Connect 用の .pkg を作成します (--upload でアップロードまで実行)。

Options:
  --upload              作成した .pkg を App Store Connect へアップロードする
                        (アップロードだけでは審査は始まらない。提出は App Store Connect
                        または ASC API で行う)
  --version VERSION     Info.plist の CFBundleShortVersionString に差し込む
                        (真実の源は v* タグ。**差し込んだ Info.plist はコミットしないこと** —
                        release.yml と同じビルド時差し込み)
  --build NUMBER        Info.plist の CFBundleVersion に差し込む。
                        App Store では以前の提出より大きい値が必須 (Sparkle の
                        CFBundleVersion 単調増加と同じ契約)
  --output-dir DIR      成果物の出力先 (既定: dist/appstore)
  --team-id ID          Developer Team ID (既定: 4B873Q67MK)

Environment:
  AC_API_KEY       App Store Connect API キー (.p8) のパス (必須)
  AC_API_KEY_ID    キー ID (必須)
  AC_API_ISSUER    issuer ID (必須)
  KILDE_CLI_SWIFT_TOKEN   private な kilde-cli-swift を解決するための PAT
                          (Contents: Read-only)。未設定なら既存の git 認証を使う

例:
  AC_API_KEY=~/.kilde-asc/AuthKey_XYZ.p8 AC_API_KEY_ID=XYZ AC_API_ISSUER=... \
      scripts/release/appstore-archive.sh --version 0.4.0 --build 42
EOF
}

log() { echo "appstore: $*"; }
die() { echo "appstore: エラー: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --upload) UPLOAD=true ;;
        --version) STAMP_VERSION="${2:?}"; shift ;;
        --build) STAMP_BUILD="${2:?}"; shift ;;
        --output-dir) OUTPUT_DIR="${2:?}"; shift ;;
        --team-id) TEAM_ID="${2:?}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "不明なオプション: $1" ;;
    esac
    shift
done

[ -n "$KEY_PATH" ] || { usage >&2; die "AC_API_KEY (.p8 のパス) が必要です"; }
[ -n "$KEY_ID" ] || die "AC_API_KEY_ID が必要です"
[ -n "$ISSUER" ] || die "AC_API_ISSUER が必要です"
[ -f "$KEY_PATH" ] || die "API キーが見つかりません: $KEY_PATH"
[ -d "$GUI_DIR" ] || die "gui/ が見つかりません: $GUI_DIR"
# CFBundleVersion は整数またはドット区切り整数のみ。不正値はビルド開始前に弾く
# (ASC は提出時に拒否するが、そのためだけにアーカイブ一式を作らせない — cubic レビュー指摘)
if [ -n "$STAMP_BUILD" ] && ! [[ "$STAMP_BUILD" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    die "--build は整数 (またはドット区切り整数) で指定してください: $STAMP_BUILD"
fi

# 相対パスの --output-dir は **cd "$GUI_DIR" の前に**絶対化する — 後から解決すると
# gui/ 配下に書かれてしまう (cubic レビュー指摘)
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

AUTH_ARGS=(
    -authenticationKeyPath "$KEY_PATH"
    -authenticationKeyID "$KEY_ID"
    -authenticationKeyIssuerID "$ISSUER"
    -allowProvisioningUpdates
)

# private な kilde-cli-swift のパッケージ解決には GitHub の git 認証が要る
# (DEVELOPMENT.md §1)。KILDE_CLI_SWIFT_TOKEN があれば release.yml と同じ insteadOf
# 置換を **プロセス環境だけ** で足す — GIT_CONFIG_* はファイルに書かれないため
# trap での後始末が不要。未設定なら既存の git 認証に任せる (cubic レビュー指摘)
if [ -n "${KILDE_CLI_SWIFT_TOKEN:-}" ]; then
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="url.https://x-access-token:${KILDE_CLI_SWIFT_TOKEN}@github.com/kilde-team/.insteadOf"
    export GIT_CONFIG_VALUE_0="https://github.com/kilde-team/"
    log "KILDE_CLI_SWIFT_TOKEN を private パッケージ解決に使用 (環境変数のみ、永続化しない)"
fi

cd "$GUI_DIR"

# .xcodeproj は生成物。常に生成し直す (project.yml を変え忘れても古いプロジェクトで
# アーカイブしないため)
log "xcodegen でプロジェクトを生成"
xcodegen

log "パッケージ依存を解決"
xcodebuild -resolvePackageDependencies

# バージョン・ビルド番号をビルド前に差し込む (release.yml と同じ plutil 手法)。
# このリポジトリには CFBundleVersion の単調増加を強制する仕組みが無いので、
# 提出のたびに --build を大きくして指定する。
# 追跡対象の Info.plist を書き換えるため、元の内容を退避して **EXIT で必ず復元**する
# — 失敗・中断後に古い MAS のバージョン番号が残るのを防ぐ (cubic レビュー指摘)
PLIST="$GUI_DIR/Resources/Info.plist"
if [ -n "$STAMP_VERSION" ] || [ -n "$STAMP_BUILD" ]; then
    PLIST_BACKUP="$(mktemp)"
    cp "$PLIST" "$PLIST_BACKUP"
    trap 'cp "$PLIST_BACKUP" "$PLIST" && rm -f "$PLIST_BACKUP"' EXIT
fi
if [ -n "$STAMP_VERSION" ]; then
    log "CFBundleShortVersionString=$STAMP_VERSION を差し込み"
    plutil -replace CFBundleShortVersionString -string "$STAMP_VERSION" "$PLIST"
fi
if [ -n "$STAMP_BUILD" ]; then
    log "CFBundleVersion=$STAMP_BUILD を差し込み"
    plutil -replace CFBundleVersion -string "$STAMP_BUILD" "$PLIST"
fi

ARCHIVE_PATH="$OUTPUT_DIR/KildeGUI-AppStore.xcarchive"

# PRODUCT_NAME が直接配布版と同じ KildeGUI のため、DerivedData を分離する。
# 使い回すと以前の KildeGUI ビルドの Sparkle.framework が成果物に残る (project.yml 参照)。
#
# project.yml の CODE_SIGN_IDENTITY=kilde-dev はローカル開発用 — このままでは
# 自動署名が kilde-dev を探してアーカイブが失敗するため、ASC 用の証明書名を
# 明示して上書きする (Apple Distribution は -allowProvisioningUpdates が作る。
# cubic レビュー指摘)
log "アーカイブを開始 (scheme=$SCHEME)"
xcodebuild archive \
    -project KildeGUI.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$OUTPUT_DIR/derived" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    "${AUTH_ARGS[@]}"

# アーカイブの中身を検証する。「MAS 版に Sparkle を含めない」「サンドボックス有効」は
# このスクリプトの契約 — 作ってから確かめるまで通ったことにならない
APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/KildeGUI.app"
[ -d "$APP_IN_ARCHIVE" ] || die "アーカイブに KildeGUI.app がありません: $APP_IN_ARCHIVE"
if [ -e "$APP_IN_ARCHIVE/Contents/Frameworks/Sparkle.framework" ]; then
    die "アーカイブに Sparkle.framework が含まれています (APPSTORE 条件の除外漏れを確認してください)"
fi
# 値まで見る — キーの存在だけだと false/ でも通り抜ける (CodeRabbit レビュー指摘)。
# entitlements は :- で XML plist として受け取る (省略形 (-) は人間可読テキストで
# plutil が読めない)。plutil -extract はドットを keypath 区切りにするため、
# 鍵名のドットはバックスラッシュでエスケープする
ENTITLEMENTS_PLIST="$OUTPUT_DIR/archive-entitlements.plist"
codesign -d --entitlements :- "$APP_IN_ARCHIVE" > "$ENTITLEMENTS_PLIST" 2>/dev/null \
    || die "アーカイブのエンタイトルメントを取得できません"
[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$ENTITLEMENTS_PLIST" 2>/dev/null)" = "true" ] \
    || die "アーカイブで App Sandbox が有効ではありません (entitlement の値を確認してください)"
log "検証 OK: Sparkle 無し・App Sandbox 有効"

# exportOptions はアップロード / .pkg 書き出しの両方で使う。signingStyle automatic
# により、プロファイルが無ければ -allowProvisioningUpdates が作成する
if [ "$UPLOAD" = true ]; then
    DESTINATION="upload"
else
    DESTINATION="export"
fi
EXPORT_OPTIONS="$OUTPUT_DIR/exportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$DESTINATION</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

if [ "$UPLOAD" = true ]; then
    # destination=upload はエクスポートとアップロードを 1 度に行う
    log "App Store Connect へアップロード"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$OUTPUT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        "${AUTH_ARGS[@]}"
    log "アップロード完了。App Store Connect で処理完了後に提出してください"
    exit 0
fi

# .pkg として書き出す (Transporter / ASC ウェブからの手動アップロード用)
log ".pkg を書き出し"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    "${AUTH_ARGS[@]}"

PKG="$OUTPUT_DIR/KildeGUI.pkg"
[ -f "$PKG" ] || PKG="$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.pkg' | head -1)"
[ -n "$PKG" ] && [ -f "$PKG" ] || die ".pkg が見つかりません ($OUTPUT_DIR を確認してください)"
log "完成: $PKG"
echo "appstore: アップロードは --upload か、この .pkg を Transporter 等で"
echo "appstore: アップロードしてください。Info.plist に差し込んだバージョンは終了時に元へ戻りました"
