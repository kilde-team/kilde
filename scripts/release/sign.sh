#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# CLI のソースは kilde-team/kilde-cli-swift に分離された (kilde#115 / #118)。
# このリポジトリにはソースが無いため、checkout / clone を CLI_DIR として受ける。
# 既定は release.yml が checkout するパス (リポジトリ直下の kilde-cli-swift/)
CLI_DIR="${KILDE_CLI_DIR:-$ROOT_DIR/kilde-cli-swift}"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_KEY="${AC_API_KEY:-}"
NOTARY_KEY_ID="${AC_API_KEY_ID:-}"
NOTARY_ISSUER="${AC_API_ISSUER:-}"
OUTPUT_DIR="${KILDE_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
VERSION="${KILDE_RELEASE_VERSION:-}"
SKIP_NOTARIZE=false
SIGN_UPDATE_TOOL="${KILDE_SIGN_UPDATE:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_ED25519_PRIVATE_KEY:-}"

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
  --cli-dir DIR         CLI ソース (kilde-team/kilde-cli-swift) の checkout / clone
                        (env: KILDE_CLI_DIR、既定: <リポジトリルート>/kilde-cli-swift)
  --output-dir DIR      成果物の出力先 (env: KILDE_RELEASE_OUTPUT_DIR、既定: dist)
  --version VERSION     成果物名に使うバージョン
                        (env: KILDE_RELEASE_VERSION、既定: Info.plist のバージョン)
  --skip-notarize       署名とパッケージ作成のみ行う
  --sign-update PATH    Sparkle の EdDSA 署名ツール sign_update のパス
                        (env: KILDE_SIGN_UPDATE、未指定なら PATH 上を探す。
                         入手手順は docs/RELEASE.md「Sparkle (GUI 自動更新)」)
  -h, --help            このヘルプを表示する

Environment (Sparkle 自動更新用、issue #122):
  SPARKLE_ED25519_PRIVATE_KEY  EdDSA 秘密鍵 (base64)。設定あれば stdin から
                        sign_update へ渡す。未設定なら login Keychain の
                        Sparkle 鍵 (generate_keys で作ったもの) を使う

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
    # --identity --key XXX のように値の位置に別オプションが来た場合、空チェックだけ
    # 通してしまうと引数が 1 つずれて誤解を招くエラーになるため先に弾く
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
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
        --cli-dir)
            require_value "$@"
            CLI_DIR="$2"
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
        --sign-update)
            require_value "$@"
            SIGN_UPDATE_TOOL="$2"
            shift 2
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
# ソース不在はビルド段階まで進まないうちに弾く — swift build の
# 「directory does not exist」より、原因 (CLI_DIR の誤り) を具体的に伝えられる
[[ -f "$CLI_DIR/Sources/kilde/Info.plist" ]] \
    || die "CLI ソースが見つかりません: $CLI_DIR/Sources/kilde/Info.plist — --cli-dir / KILDE_CLI_DIR に kilde-team/kilde-cli-swift の checkout を指定してください"
[[ -n "$SIGN_IDENTITY" ]] || die "--identity または DEVELOPER_ID_APPLICATION で Developer ID Application 証明書名を指定してください"
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] \
    || die "配布署名には Developer ID Application identity の完全な名前を指定してください: $SIGN_IDENTITY"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -Fq "\"$SIGN_IDENTITY\"" <<<"$IDENTITIES"; then
    die "Keychain に署名可能な証明書 '$SIGN_IDENTITY' が見つかりません。security find-identity -v -p codesigning で確認してください"
fi

if [[ -z "$VERSION" ]]; then
    VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$CLI_DIR/Sources/kilde/Info.plist")"
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

CLI_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$CLI_DIR/Sources/kilde/Info.plist")"
CLI_PATH="$CLI_DIR/.build/release/kilde"
EMBEDDED_INFO_PLIST="$WORK_DIR/cli-embedded-info.plist"
DERIVED_DATA="$WORK_DIR/DerivedData"
GUI_PROJECT="$ROOT_DIR/gui/KildeGUI.xcodeproj"
GUI_APP="$DERIVED_DATA/Build/Products/Release/KildeGUI.app"
CLI_ZIP="$OUTPUT_DIR/kilde-$VERSION-macos.zip"
GUI_DMG="$OUTPUT_DIR/KildeGUI-$VERSION.dmg"

echo "==> CLI をリリースビルド (source: $CLI_DIR)"
swift build -c release --package-path "$CLI_DIR"
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

# Sparkle.framework (issue #122) はネストしたコードを複数持つ: XPCServices/*.xpc、
# ネスト .app の Updater.app、拡張子なし Mach-O の Autoupdate。find がこれらを
# 拾わないと --deep 相当の検証で外側の署名だけが作られ、配布物のゲートが通らない。
# find -d (-depth) で子を親より先に列挙し、最深のコードから署名する — 内側を
# 後から署名すると外側の署名が無効になるため。BSD find の -d を使うのは、
# macOS 標準の sort に NUL 区切りの -z が無いため (パス逆順ソートが使えない)
while IFS= read -r -d '' nested_code; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$nested_code"
done < <(find -d "$GUI_APP/Contents" \( -type f \( -name '*.dylib' -o -name 'Autoupdate' \) \
    -o -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \) -print0)

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

# DMG 自体も Developer ID で署名する (issue #216)。未署名の DMG では stapler が
# notarization チケットを xattr (拡張属性) に記録するため、GitHub Release への
# HTTP upload で失われ、ダウンロード後の spctl --type open が rejected になる
# (v0.6.0 実測)。署名済みの DMG では codesign の signature も stapler のチケットも
# イメージ内に埋め込まれるため、upload を経ても «オフライン検証»
# (docs/RELEASE.md §3) が生き残る。Hardened Runtime は Mach-O の属性で
# ディスクイメージには効かない — 「実行コードは runtime 付き」という notarization
# の要件はイメージ内の .app が満たすため、DMG には --options runtime を付けない
echo "==> DMG を Developer ID で署名"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$GUI_DMG"
codesign --verify --strict --verbose=2 "$GUI_DMG"

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

# ---- appcast.xml (Sparkle 自動更新、issue #122) ----
# GUI DMG を作ったら必ず appcast も作る — SUFeedURL は latest download の固定 URL なので、
# appcast の無いリリースが latest になると GUI の更新チェックが壊れる。
# EdDSA 署名は **staple の後**に行う。stapler は DMG を書き換えるため、先に署名すると
# 配布物と署名の対象が一致しなくなり、Sparkle が更新を拒否する
if [[ -z "$SIGN_UPDATE_TOOL" ]] && command -v sign_update >/dev/null 2>&1; then
    SIGN_UPDATE_TOOL="$(command -v sign_update)"
fi
[[ -n "$SIGN_UPDATE_TOOL" && -x "$SIGN_UPDATE_TOOL" ]] \
    || die "sign_update が見つかりません — --sign-update / KILDE_SIGN_UPDATE で指定してください (入手は docs/RELEASE.md「Sparkle (GUI 自動更新)」)"

# sparkle:version は CFBundleVersion (= リリース workflow が差し込む GITHUB_RUN_NUMBER)。
# Sparkle はこの値の単調増加で更新を判定する — バージョン文字列ではない
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$GUI_APP/Contents/Info.plist")"
GUI_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$GUI_APP/Contents/Info.plist")"
# sparkle:shortVersionString には VERSION を書くため、ビルドした GUI と VERSION が
# ずれていると appcast と DMG の中身が不一致になる — 更新を催促するのに中身が古い
# 配布物ができ上がる。--version 直接実行 (stamp 無し) で起こりうるので弾く
[[ "$GUI_SHORT_VERSION" == "$VERSION" ]] \
    || die "GUI の CFBundleShortVersionString ($GUI_SHORT_VERSION) が成果物バージョン ($VERSION) と一致しません — リリース workflow の stamp を通すか、gui/Resources/Info.plist を更新してください"
SIGN_UPDATE_OUT=""
if [[ -n "$SPARKLE_PRIVATE_KEY" ]]; then
    # CI など鍵ファイルが無い環境: 秘密鍵を stdin に流す (--ed-key-file - は定型)
    SIGN_UPDATE_OUT="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE_TOOL" --ed-key-file - "$GUI_DMG")"
else
    # ローカル: login Keychain の Sparkle 鍵 (generate_keys で作ったもの) を使う
    SIGN_UPDATE_OUT="$("$SIGN_UPDATE_TOOL" "$GUI_DMG")"
fi
SIGNATURE="$(sed -n 's/^sparkle:edSignature="\([^"]*\)".*$/\1/p' <<<"$SIGN_UPDATE_OUT")"
DMG_LENGTH_REPORTED="$(sed -n 's/.*length="\([^"]*\)".*$/\1/p' <<<"$SIGN_UPDATE_OUT")"
DMG_LENGTH="$(stat -f %z "$GUI_DMG")"
[[ -n "$SIGNATURE" ]] || die "sign_update から EdDSA 署名を取り出せませんでした: $SIGN_UPDATE_OUT"
# length は Sparkle がダウンロードの検証に使う。署名対象と実際の DMG が同じであることを
# ここでも機械的に確かめる (staple 前に署名していないかの検出にもなる)
[[ "$DMG_LENGTH_REPORTED" == "$DMG_LENGTH" ]] \
    || die "sign_update が報告した length ($DMG_LENGTH_REPORTED) が実際の DMG サイズ ($DMG_LENGTH) と一致しません"

APPCAST="$OUTPUT_DIR/appcast.xml"
# pubDate は RFC 822 (英語の曜日・月名) でなければならない。date の出力は LC_TIME に
# 従うため、日本語ロケールの実行環境では «水, 16 9月 2026…» になり Sparkle が日付を
# パースできない — LC_ALL=C で英語に固定する
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>KildeGUI</title>
    <link>https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml</link>
    <description>kilde GUI の更新情報</description>
    <language>ja</language>
    <item>
      <title>kilde ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/kilde-team/kilde/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/kilde-team/kilde/releases/download/v${VERSION}/KildeGUI-${VERSION}.dmg" sparkle:edSignature="${SIGNATURE}" length="${DMG_LENGTH}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
# item は常に 1 件 — SUFeedURL が latest 固定なので過去分の累積は不要。
# 展開漏れのプレースホルダが残っていないか機械的に検査する (sed の失敗は黙って通るため)
if grep -q '\${' "$APPCAST"; then
    die "appcast に未置換のプレースホルダが残っています: $APPCAST"
fi
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$APPCAST" || die "appcast.xml が整形式ではありません: $APPCAST"
else
    echo "warn: xmllint が無いため appcast の整形式検査を省略しました"
fi

echo "完了:"
echo "  CLI: $CLI_ZIP"
echo "  GUI: $GUI_DMG"
echo "  appcast: $APPCAST"
