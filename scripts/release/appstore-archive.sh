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

AUTH_ARGS=(
    -authenticationKeyPath "$KEY_PATH"
    -authenticationKeyID "$KEY_ID"
    -authenticationKeyIssuerID "$ISSUER"
    -allowProvisioningUpdates
)

cd "$GUI_DIR"

# .xcodeproj は生成物。常に生成し直す (project.yml を変え忘れても古いプロジェクトで
# アーカイブしないため)
log "xcodegen でプロジェクトを生成"
xcodegen

log "パッケージ依存を解決"
xcodebuild -resolvePackageDependencies

# バージョン・ビルド番号をビルド前に差し込む (release.yml と同じ plutil 手法)。
# このリポジトリには CFBundleVersion の単調増加を強制する仕組みが無いので、
# 提出のたびに --build を大きくして指定する
PLIST="Resources/Info.plist"
if [ -n "$STAMP_VERSION" ]; then
    log "CFBundleShortVersionString=$STAMP_VERSION を差し込み"
    plutil -replace CFBundleShortVersionString -string "$STAMP_VERSION" "$PLIST"
fi
if [ -n "$STAMP_BUILD" ]; then
    log "CFBundleVersion=$STAMP_BUILD を差し込み"
    plutil -replace CFBundleVersion -string "$STAMP_BUILD" "$PLIST"
fi

ARCHIVE_PATH="$OUTPUT_DIR/KildeGUI-AppStore.xcarchive"
mkdir -p "$OUTPUT_DIR"

# PRODUCT_NAME が直接配布版と同じ KildeGUI のため、DerivedData を分離する。
# 使い回すと以前の KildeGUI ビルドの Sparkle.framework が成果物に残る (project.yml 参照)
log "アーカイブを開始 (scheme=$SCHEME)"
xcodebuild archive \
    -project KildeGUI.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$OUTPUT_DIR/derived" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    "${AUTH_ARGS[@]}"

# アーカイブの中身を検証する。「MAS 版に Sparkle を含めない」「サンドボックス有効」は
# このスクリプトの契約 — 作ってから確かめるまで通ったことにならない
APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/KildeGUI.app"
[ -d "$APP_IN_ARCHIVE" ] || die "アーカイブに KildeGUI.app がありません: $APP_IN_ARCHIVE"
if [ -e "$APP_IN_ARCHIVE/Contents/Frameworks/Sparkle.framework" ]; then
    die "アーカイブに Sparkle.framework が含まれています (APPSTORE 条件の除外漏れを確認してください)"
fi
codesign -d --entitlements - "$APP_IN_ARCHIVE" | grep -q "com.apple.security.app-sandbox" \
    || die "アーカイブに App Sandbox のエンタイトルメントがありません"
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
echo "appstore: アップロードしてください。Info.plist に差し込んだバージョンはコミットしないこと"
