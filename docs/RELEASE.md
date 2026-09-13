# リリース署名と notarization

公式配布する CLI と GUI を Developer ID で署名し、Apple の notarization を通すための
手順です。GUI は Hardened Runtime を有効にした DMG、CLI は zip として生成します。
通常の開発ビルドとテストにはこの手順は不要です。

実際の署名には Apple Developer Program のチームが発行した
`Developer ID Application` 証明書、notarization には App Store Connect API キーが
必要です。秘密鍵や証明書を書き出したファイルはリポジトリへコミットしないでください。

## 1. Developer ID 証明書の準備

Apple Developer の Certificates で `Developer ID Application` 証明書を作成し、
秘密鍵とともにログイン Keychain へ登録します。登録後、利用できる identity を確認します。

```sh
security find-identity -v -p codesigning
```

出力された完全な名前 (例: `Developer ID Application: Example, Inc. (TEAMID)`) を
`--identity` に渡します。証明書が無い、秘密鍵が対応していない、期限切れである場合は
`sign.sh` がビルド前にエラーで停止します。

## 2. App Store Connect API キーの準備

App Store Connect の「ユーザとアクセス」→「統合」から Team API key を作成します。
notarization を行える権限 (Developer 以上) を与え、次の 3 点を保存します。

- Key ID
- Issuer ID
- ダウンロードした秘密鍵 `AuthKey_<KEY_ID>.p8`

`.p8` は一度しかダウンロードできません。アクセス権を限定した場所に保存し、漏えい時は
App Store Connect で直ちに無効化してください。Apple の画面や権限名が変わった場合は、
[Creating API keys for App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
と [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
を確認してください。

## 3. `sign.sh` の使い方

リポジトリのルートで実行します。Xcode、Swift、XcodeGen が必要です。

```sh
brew install xcodegen # 未導入の場合のみ

scripts/release/sign.sh \
  --identity "Developer ID Application: Example, Inc. (TEAMID)" \
  --key "$HOME/private/AuthKey_ABC123.p8" \
  --key-id ABC123 \
  --issuer 00000000-0000-0000-0000-000000000000 \
  --version 0.1.0
```

スクリプトは次の処理を順番に行い、いずれかが失敗すると直ちに停止します。

1. `swift build -c release` で CLI をビルドする
2. CLI の埋め込み `CFBundleIdentifier` (`dev.kilde.cli`) を検査し、同じ signing
   identifier と audio-input entitlement、Hardened Runtime、timestamp を付けて署名する
3. XcodeGen と `xcodebuild` で KildeGUI の Release `.app` をビルドし、同じ条件で署名する
4. `dist/kilde-<version>-macos.zip` と `dist/KildeGUI-<version>.dmg` を作る
5. 両方を `notarytool submit --wait` へ送り、GUI の DMG にチケットを staple する

zip には notarization ticket を直接 staple できません。CLI の ticket は Gatekeeper が
Apple のサービスから取得します。GUI の DMG はオフライン検証にも対応できるよう staple します。

署名とパッケージ作成だけをローカルで確認する場合は `--skip-notarize` を使います。
Developer ID の timestamp 取得は行うため、このモードでも署名時にネットワーク接続が必要です。
このモードの成果物は公式リリースとして配布しません。

```sh
scripts/release/sign.sh \
  --identity "Developer ID Application: Example, Inc. (TEAMID)" \
  --skip-notarize
```

全オプションは `scripts/release/sign.sh --help` で確認できます。引数の代わりに次の環境変数も
使用できます。

| 引数 | 環境変数 | 内容 |
|------|----------|------|
| `--identity` | `DEVELOPER_ID_APPLICATION` | Keychain に登録した identity の完全な名前 |
| `--key` | `AC_API_KEY` | `.p8` のパス、または `.p8` ファイルの内容 |
| `--key-id` | `AC_API_KEY_ID` | API Key ID |
| `--issuer` | `AC_API_ISSUER` | Issuer ID |
| `--output-dir` | `KILDE_RELEASE_OUTPUT_DIR` | 成果物の出力先。既定は `dist/` |
| `--version` | `KILDE_RELEASE_VERSION` | 成果物名のバージョン。既定は CLI の Info.plist |

引数と環境変数を両方指定した場合は引数が優先されます。

## 4. GitHub Actions 用 Secrets

release workflow は issue #25 で追加します。workflow から `sign.sh` へ渡す名前は次で固定し、
証明書の import と一時 Keychain の作成は workflow 側で行います。

| GitHub Secret | workflow での用途 / `sign.sh` との対応 |
|---------------|-----------------------------------------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID 証明書と秘密鍵を含む `.p12` の Base64。workflow が一時 Keychain に import |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` の書き出しパスワード |
| `KEYCHAIN_PASSWORD` | CI で作る一時 Keychain のパスワード |
| `DEVELOPER_ID_APPLICATION` | `sign.sh` の `--identity` / 同名環境変数 |
| `AC_API_KEY_ID` | `sign.sh` の `--key-id` / 同名環境変数 |
| `AC_API_ISSUER` | `sign.sh` の `--issuer` / 同名環境変数 |
| `AC_API_KEY` | `.p8` の内容。`sign.sh` が権限 600 の一時ファイルにして `--key` へ渡す |

バージョンと出力先は秘密情報ではないため、workflow の値または GitHub Actions Variables として
次を使えます。

| workflow 変数 | 用途 |
|---------------|------|
| `KILDE_RELEASE_VERSION` | 通常は release tag から `v` を除いた値を設定 |
| `KILDE_RELEASE_OUTPUT_DIR` | workflow の artifact staging directory。未指定なら `dist/` |

GitHub のログに秘密値を表示しないでください。workflow 終了時は一時 Keychain と API キーの
一時ファイルを削除します (`sign.sh` が作った API キーファイルは trap で削除されます)。

## 5. リリース前の確認

証明書と API キーを持つ担当者は、上記手順で notarization まで実行した後に確認します。

```sh
codesign --verify --deep --strict --verbose=2 "/path/to/KildeGUI.app"
spctl --assess --type open --context context:primary-signature -vv "dist/KildeGUI-0.1.0.dmg"
xcrun stapler validate "dist/KildeGUI-0.1.0.dmg"
```

CLI は zip を展開して `codesign --verify --strict --verbose=2 kilde` と
`codesign -d --entitlements :- kilde` を実行し、別の macOS ユーザー環境で初回起動時の
Gatekeeper と TCC (画面収録・マイク) の動作も確認してください。


## GitHub でのリリース自動化 (issue #25)

`.github/workflows/release.yml` が `v*` タグの push で起動します:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

フロー: タグからバージョンを解決 → `Info.plist` と `KildeCommand` の version に
差し込み (ビルド限り、コミットはしない) → `swift build -c release` → 埋め込み
Info.plist の生存とバージョンを検証 → 署名 → Release を作成して zip を添付。

**署名は secrets の有無で自動分岐**:

| secrets | 動作 |
|---------|------|
| §4 の 6 secret がすべて設定済み (`DEVELOPER_ID_CERTIFICATE_BASE64` + `DEVELOPER_ID_CERTIFICATE_PASSWORD` + `DEVELOPER_ID_APPLICATION` + `AC_API_KEY` / `AC_API_KEY_ID` / `AC_API_ISSUER`) | 証明書を一時キーチェーンに import → `sign.sh` で署名・notarization・staple まで実行 |
| 未設定 (現在) | **unsigned zip** でリリース。Release Notes に「未署名」の注意と `xattr -d` の回避方法を明記 |

証明書を取得したらリポジトリ設定で 6 つの secrets を足すだけで署名に切り替わります
(ワークフロー側の変更は不要)。`DEVELOPER_ID_CERTIFICATE_BASE64` は「Developer ID
Application」の .p12 を `base64 -i cert.p12 | pbcopy` でエンコードしたもの。

**手動検証** (タグを打たずにビルドだけ確認): Actions タブから `Release` ワークフローを
`workflow_dispatch` で実行。**手動実行は常に dry-run** (ビルドと署名分岐までを検証、
Release は作成しない) — タグが無いと Info.plist 由来の現在値でリリースを作りかねないため、
Release の作成は `v*` タグの push に限定しています。

### 未実装 (follow-up)

- **tap リポジトリ (`takezou621/homebrew-kilde`) への formula 自動更新** —
  tap 自体が未作成のため、tap 作成 (#24 のフォロー) 後に `url` / `sha256` を
  更新する PR を送るジョブを追加する
- **Release Notes の自動生成 (PR タイトル由来)** — 初回リリース後に手順を確定させる
