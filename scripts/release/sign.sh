#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_KEY="${AC_API_KEY:-}"
NOTARY_KEY_ID="${AC_API_KEY_ID:-}"
NOTARY_ISSUER="${AC_API_ISSUER:-}"
OUTPUT_DIR="${KILDE_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
VERSION="${KILDE_RELEASE_VERSION:-}"
SKIP_NOTARIZE=false

usage() {
    cat <<'EOF'
Usage: scripts/release/sign.sh [options]

Developer ID で CLI と GUI を署名し、zip / DMG を作成して notarization します。

Options:
  --identity NAME       Developer ID Application 証明書名
                        (env: DEVELOPER_ID_APPLICATION)
  --key PATH            App Store Connect API キー (.p8) のパス
                        (env: AC_API_KEY。パスまたは .p8 の内容)
  --key-id ID           App Store Connect API キー ID (env: AC_API_KEY_ID)
  --issuer UUID         App Store Connect issuer ID (env: AC_API_ISSUER)
  --output-dir DIR      成果物の出力先 (env: KILDE_RELEASE_OUTPUT_DIR、既定: dist)
  --version VERSION     成果物名に使うバージョン
                        (env: KILDE_RELEASE_VERSION、既定: Info.plist のバージョン)
  --skip-notarize       署名とパッケージ作成のみ行う
  -h, --help            このヘルプを表示する

Examples:
  scripts/release/sign.sh --identity "Developer ID Application: Example (TEAMID)" \
    --key AuthKey_ABC123.p8 --key-id ABC123 --issuer 00000000-0000-0000-0000-000000000000
  DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
    scripts/release/sign.sh --skip-notarize
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: $1 には値が必要です" >&2
        usage >&2
        exit 64
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            require_value "$@"
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --key)
            require_value "$@"
            NOTARY_KEY="$2"
            shift 2
            ;;
        --key-id)
            require_value "$@"
            NOTARY_KEY_ID="$2"
            shift 2
            ;;
        --issuer)
            require_value "$@"
            NOTARY_ISSUER="$2"
            shift 2
            ;;
        --output-dir)
            require_value "$@"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --version)
            require_value "$@"
            VERSION="$2"
            shift 2
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: 不明なオプションです: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

for tool in swift codesign security otool plutil xcodegen xcodebuild ditto hdiutil; do
    command -v "$tool" >/dev/null 2>&1 || die "必要なコマンドが見つかりません: $tool"
done

[[ -f "$ENTITLEMENTS" ]] || die "entitlements が見つかりません: $ENTITLEMENTS"
[[ -n "$SIGN_IDENTITY" ]] || die "--identity または DEVELOPER_ID_APPLICATION で Developer ID Application 証明書名を指定してください"
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] \
    || die "配布署名には Developer ID Application identity の完全な名前を指定してください: $SIGN_IDENTITY"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -Fq "\"$SIGN_IDENTITY\"" <<<"$IDENTITIES"; then
    die "Keychain に署名可能な証明書 '$SIGN_IDENTITY' が見つかりません。security find-identity -v -p codesigning で確認してください"
fi

if [[ -z "$VERSION" ]]; then
    VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/Sources/kilde/Info.plist")"
fi
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "バージョンには英数字、ピリオド、ハイフン、アンダースコアだけを使用してください: $VERSION"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    command -v xcrun >/dev/null 2>&1 || die "必要なコマンドが見つかりません: xcrun"
    [[ -n "$NOTARY_KEY" ]] || die "--key または AC_API_KEY を指定してください"
    [[ -n "$NOTARY_KEY_ID" ]] || die "--key-id または AC_API_KEY_ID を指定してください"
    [[ -n "$NOTARY_ISSUER" ]] || die "--issuer または AC_API_ISSUER を指定してください"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kilde-release.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

NOTARY_KEY_PATH=""
if [[ "$SKIP_NOTARIZE" == false ]]; then
    if [[ -f "$NOTARY_KEY" ]]; then
        NOTARY_KEY_PATH="$NOTARY_KEY"
    elif [[ "$NOTARY_KEY" == *"BEGIN PRIVATE KEY"* ]]; then
        NOTARY_KEY_PATH="$WORK_DIR/AuthKey.p8"
        printf '%s\n' "$NOTARY_KEY" > "$NOTARY_KEY_PATH"
        chmod 600 "$NOTARY_KEY_PATH"
    else
        die "App Store Connect API キーがファイルとして見つからず、.p8 の内容でもありません"
    fi
fi

CLI_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$ROOT_DIR/Sources/kilde/Info.plist")"
CLI_PATH="$ROOT_DIR/.build/release/kilde"
EMBEDDED_INFO_PLIST="$WORK_DIR/cli-embedded-info.plist"
DERIVED_DATA="$WORK_DIR/DerivedData"
GUI_PROJECT="$ROOT_DIR/gui/KildeGUI.xcodeproj"
GUI_APP="$DERIVED_DATA/Build/Products/Release/KildeGUI.app"
CLI_ZIP="$OUTPUT_DIR/kilde-$VERSION-macos.zip"
GUI_DMG="$OUTPUT_DIR/KildeGUI-$VERSION.dmg"

echo "==> CLI をリリースビルド"
swift build -c release --package-path "$ROOT_DIR"
[[ -x "$CLI_PATH" ]] || die "CLI のビルド成果物が見つかりません: $CLI_PATH"

# otool は plist の前にバイナリ名とセクション名を表示するため、XML 部分だけを
# 取り出してから機械的に比較する。
otool -P "$CLI_PATH" | awk 'found || /^<\?xml/ { found = 1; print }' > "$EMBEDDED_INFO_PLIST"
EMBEDDED_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$EMBEDDED_INFO_PLIST")"
[[ "$EMBEDDED_IDENTIFIER" == "$CLI_IDENTIFIER" ]] \
    || die "CLI の埋め込み CFBundleIdentifier が一致しません: source=$CLI_IDENTIFIER embedded=$EMBEDDED_IDENTIFIER"

echo "==> CLI を署名 (identifier: $CLI_IDENTIFIER)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$CLI_IDENTIFIER" \
    --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$CLI_PATH"
codesign --verify --strict --verbose=2 "$CLI_PATH"

echo "==> GUI プロジェクトを生成して Release ビルド"
(
    cd "$ROOT_DIR/gui"
    xcodegen generate
)
xcodebuild -project "$GUI_PROJECT" -scheme KildeGUI -configuration Release \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
[[ -d "$GUI_APP" ]] || die "GUI のビルド成果物が見つかりません: $GUI_APP"

# 現在は埋め込みフレームワークを持たない。将来追加された dylib / framework は
# 外側の .app より先に署名し、コード署名の内側から外側という順序を維持する。
while IFS= read -r -d '' nested_code; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$nested_code"
done < <(find "$GUI_APP/Contents" -type f -name '*.dylib' -print0)
while IFS= read -r -d '' nested_bundle; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$nested_bundle"
done < <(find "$GUI_APP/Contents" -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0)

echo "==> GUI を署名 (Hardened Runtime)"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$GUI_APP"
codesign --verify --deep --strict --verbose=2 "$GUI_APP"

echo "==> 配布アーカイブを作成"
mkdir -p "$OUTPUT_DIR"
rm -f "$CLI_ZIP" "$GUI_DMG"
ditto -c -k --sequesterRsrc --keepParent "$CLI_PATH" "$CLI_ZIP"
hdiutil create -quiet -format UDZO -fs HFS+ -volname KildeGUI \
    -srcfolder "$GUI_APP" "$GUI_DMG"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> CLI zip を notarization に送信"
    xcrun notarytool submit "$CLI_ZIP" --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait

    echo "==> GUI DMG を notarization に送信してチケットを staple"
    xcrun notarytool submit "$GUI_DMG" --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$GUI_DMG"
    xcrun stapler validate "$GUI_DMG"
else
    echo "==> --skip-notarize: notarization と staple を省略"
fi

echo "完了:"
echo "  CLI: $CLI_ZIP"
echo "  GUI: $GUI_DMG"
