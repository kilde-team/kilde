#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUI_DIR="$ROOT_DIR/gui"
SCHEME="KildeGUI-AppStore"

# App Store Connect API キー (**任意** — 「ユーザとアクセス → 統合」で発行する .p8)。
# 未指定なら xcodebuild -allowProvisioningUpdates がこの Mac の Xcode にログイン済みの
# Apple ID セッションで証明書・プロファイルを作り、アップロードもそこから行う。
# API キーを渡す場合は «クラウド署名» の権限 (キーロール App Manager 以上) が要る —
# 権限の無いキーだとエクスポートが "Cloud signing permission error" で失敗する
# (Xcode 26 実測)。sign.sh と同じ変数名にしてある
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
  AC_API_KEY       App Store Connect API キー (.p8) のパス (**任意** —
                   未指定なら Xcode の Apple ID セッションでプロビジョニングする。
                   キーを使うにはクラウド署名の権限 (App Manager 以上) が必要)
  AC_API_KEY_ID    キー ID (AC_API_KEY とセットで指定)
  AC_API_ISSUER    issuer ID (AC_API_KEY とセットで指定)
  KILDE_CLI_SWIFT_TOKEN   private な kilde-cli-swift を解決するための PAT
                          (Contents: Read-only)。未設定なら既存の git 認証を使う

例:
  # この Mac で完結 — Xcode の Apple ID セッションが証明書・プロファイルを自動作成する
  scripts/release/appstore-archive.sh --version 0.4.0 --build 42

  # ASC API キーを使う (CI など Apple ID でログインできない環境)
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

# API キーは 3 変数をすべて指定するかすべて省略する (任意)。片方だけの指定は設定漏れ
if [ -n "$KEY_PATH" ] || [ -n "$KEY_ID" ] || [ -n "$ISSUER" ]; then
    { [ -n "$KEY_PATH" ] && [ -n "$KEY_ID" ] && [ -n "$ISSUER" ]; } \
        || die "AC_API_KEY / AC_API_KEY_ID / AC_API_ISSUER は 3 つとも指定するか、すべて省略してください"
    [ -f "$KEY_PATH" ] || die "API キーが見つかりません: $KEY_PATH"
fi
[ -d "$GUI_DIR" ] || die "gui/ が見つかりません: $GUI_DIR"
# CFBundleVersion は整数またはドット区切り整数のみ。不正値はビルド開始前に弾く
# (ASC は提出時に拒否するが、そのためだけにアーカイブ一式を作らせない — cubic レビュー指摘)
if [ -n "$STAMP_BUILD" ] && ! [[ "$STAMP_BUILD" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    die "--build は整数 (またはドット区切り整数) で指定してください: $STAMP_BUILD"
fi
# CFBundleShortVersionString は **3 個の整数をドット区切り** が Apple の規定
# ("The required format is three period-separated integers" — Information Property List
# リファレンス)。1〜3 個を許すのは CFBundleVersion のほうで、2 つのキーの仕様は違う
# (Codex レビュー指摘。cubic / CodeRabbit の «1〜3 個» という指摘もこの混同だった)。
# 実サーバーは 0.4 のような 2 要素も受理するが、**事前検証は公開された契約に合わせる**。
# "0.4.0-beta" のような接尾辞付きも当然拒否される — アーカイブ一式を作らせてから
# 弾かれないよう、開始前に検証する
if [ -n "$STAMP_VERSION" ] && { ! [[ "$STAMP_VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]] \
    || [ "${#STAMP_VERSION}" -gt 18 ]; }; then
    die "--version は 3 個の整数をドット区切りで指定してください (例 0.4.0、18 文字以内): $STAMP_VERSION"
fi
# --upload は «そのまま App Store Connect に載る» 経路。バージョンを差し込まずに走らせると
# Info.plist の古い値 (リポジトリ上の 0.1.0 / build 1) でアーカイブしてアップロードまで進み、
# build 番号の重複で拒否されるまで高コストなビルドを費やす (cubic レビュー指摘)
if [ "$UPLOAD" = true ] && { [ -z "$STAMP_VERSION" ] || [ -z "$STAMP_BUILD" ]; }; then
    die "--upload には --version と --build の両方が必要です"
fi

# 相対パスの --output-dir は **cd "$GUI_DIR" の前に**絶対化する — 後から解決すると
# gui/ 配下に書かれてしまう (cubic レビュー指摘)
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [ -n "$KEY_PATH" ]; then
    AUTH_ARGS=(
        -authenticationKeyPath "$KEY_PATH"
        -authenticationKeyID "$KEY_ID"
        -authenticationKeyIssuerID "$ISSUER"
    )
    log "ASC API キーを使用: $KEY_PATH"
else
    # 認証キーを渡さなければ -allowProvisioningUpdates が Xcode の Apple ID
    # セッションを使う — 配布証明書・プロファイルの自動作成もアップロードもこれで通る
    AUTH_ARGS=()
    log "ASC API キー未指定 — Xcode の Apple ID セッションでプロビジョニング"
fi

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
# project.yml の CODE_SIGN_STYLE=Manual + CODE_SIGN_IDENTITY=kilde-dev はローカル
# 開発用 — このままではアーカイブが kilde-dev を探して失敗するため、自動署名に
# 差し替える。ここで CODE_SIGN_IDENTITY は **Apple Development** を指定する
# (Xcode 26 実測): 自動署名のままで Apple Distribution を明示すると
# 「conflicting provisioning settings」で失敗する。配布署名 (Apple Distribution) は
# -exportArchive が exportOptions の signingStyle=automatic + -allowProvisioningUpdates
# で適用する — 証明書・プロファイルが無ければその時点で自動作成される
log "アーカイブを開始 (scheme=$SCHEME)"
# "${AUTH_ARGS[@]+...}" は配列が空のときの set -u 対策 (macOS 標準の bash 3.2 は
# 空配列展開でエラーになる)。AUTH_ARGS が空でも -allowProvisioningUpdates は
# 常に渡す — Apple ID セッションのプロビジョニングはこのフラグで有効になる
xcodebuild archive \
    -project KildeGUI.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$OUTPUT_DIR/derived" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

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
        -allowProvisioningUpdates \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
    log "アップロード完了。App Store Connect で処理完了後に提出してください"
    exit 0
fi

# .pkg として書き出す (Transporter / ASC ウェブからの手動アップロード用)。
# **書き出しは毎回空のサブディレクトリへ行う** — OUTPUT_DIR に直接出すと、前回の
# KildeGUI.pkg が残っている状態で今回の書き出し名が変わった (または書き出しが
# 何も作らなかった) ときに、古いパッケージを «完成品» として返してしまう
# (cubic レビュー指摘)
EXPORT_DIR="$OUTPUT_DIR/export"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
log ".pkg を書き出し"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

# glob で拾う。`find … | head -1` は **.pkg が 2 つ以上あると head が先に閉じて
# find が SIGPIPE で落ち、`set -o pipefail` がそれを拾って中断する** (cubic レビュー指摘。
# 指摘にあった「BSD find に -maxdepth が無い」は macOS 26 では再現しない — 理由は違うが
# glob のほうが堅いので採用した)
EXPORTED=""
for candidate in "$EXPORT_DIR"/*.pkg; do
    if [ -f "$candidate" ]; then
        EXPORTED="$candidate"
        break
    fi
done
[ -n "$EXPORTED" ] || die ".pkg が書き出されませんでした ($EXPORT_DIR を確認してください)"
PKG="$OUTPUT_DIR/$(basename "$EXPORTED")"
mv -f "$EXPORTED" "$PKG"
rm -rf "$EXPORT_DIR"
log "完成: $PKG"
echo "appstore: アップロードは --upload か、この .pkg を Transporter 等で"
echo "appstore: アップロードしてください。Info.plist に差し込んだバージョンは終了時に元へ戻りました"
