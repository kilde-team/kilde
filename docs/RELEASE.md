# リリース署名と notarization

公式配布する CLI と GUI を Developer ID で署名し、Apple の notarization を通すための
手順です。GUI は Hardened Runtime を有効にした DMG、CLI は zip として生成します。
通常の開発ビルドとテストにはこの手順は不要です。

CLI のソースは kilde-team/kilde-cli-swift (private、issue #115 で分離) にあり、
本リポジトリには GUI・配布・ドキュメントしかありません。リリースビルドでは
同リポジトリを checkout / clone して使います (§3)。リリースの起動から成果物の
添付までを自動化する workflow の説明は「GitHub でのリリース自動化」を参照してください。

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

本リポジトリのルートで実行します。Xcode、Swift、XcodeGen が必要です。

CLI のソースは本リポジトリに無いため、事前に kilde-team/kilde-cli-swift を
`$ROOT_DIR/kilde-cli-swift` (リポジトリ直下) に clone しておきます。別の場所に
置くときは `--cli-dir` (環境変数 `KILDE_CLI_DIR`) で指定します。ソースが無い状態では
ビルドに入る前にエラーで停止します。

```sh
brew install xcodegen # 未導入の場合のみ
git clone git@github.com:kilde-team/kilde-cli-swift.git   # CLI ソース

scripts/release/sign.sh \
  --identity "Developer ID Application: Example, Inc. (TEAMID)" \
  --key "$HOME/private/AuthKey_ABC123.p8" \
  --key-id ABC123 \
  --issuer 00000000-0000-0000-0000-000000000000 \
  --version 0.2.0
```

スクリプトは次の処理を順番に行い、いずれかが失敗すると直ちに停止します。

1. `swift build -c release --package-path "$CLI_DIR"` で CLI をビルドする
   (`$CLI_DIR` は上の kilde-cli-swift の checkout / clone)
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
| `--cli-dir` | `KILDE_CLI_DIR` | CLI ソース (kilde-team/kilde-cli-swift) の checkout / clone。既定はリポジトリ直下の `kilde-cli-swift/` |
| `--output-dir` | `KILDE_RELEASE_OUTPUT_DIR` | 成果物の出力先。既定は `dist/` |
| `--version` | `KILDE_RELEASE_VERSION` | 成果物名のバージョン。既定は CLI の Info.plist |

引数と環境変数を両方指定した場合は引数が優先されます。

## 4. GitHub Actions 用 Secrets

release workflow から `sign.sh` へ渡す名前は次で固定し、証明書の import と一時
Keychain の作成は workflow 側で行います。

署名用の 6 secrets:

| GitHub Secret | workflow での用途 / `sign.sh` との対応 |
|---------------|-----------------------------------------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID 証明書と秘密鍵を含む `.p12` の Base64。workflow が一時 Keychain に import |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` の書き出しパスワード |
| `DEVELOPER_ID_APPLICATION` | `sign.sh` の `--identity` / 同名環境変数 |
| `AC_API_KEY_ID` | `sign.sh` の `--key-id` / 同名環境変数 |
| `AC_API_ISSUER` | `sign.sh` の `--issuer` / 同名環境変数 |
| `AC_API_KEY` | `.p8` の内容。workflow が権限 600 の一時ファイルにして `--key` へ渡す |

CLI ソースの checkout 用 secret (issue #118):

| GitHub Secret | 内容 |
|---------------|------|
| `KILDE_CLI_SWIFT_TOKEN` | kilde-team/kilde-cli-swift (private) を読むための fine-grained PAT。Repository access を同リポジトリに限定し、権限は `Contents: Read-only` のみ。**未設定だと checkout step が失敗し、リリースが作れない** — `GITHUB_TOKEN` は他リポジトリを読めないため必須 |

一時 Keychain のパスワードは workflow が実行ごとに生成するため secret は不要です。
ローカルで `sign.sh` を直接使う場合も `--identity` 等の引数で渡すため、設定は不要です。

バージョンと出力先は秘密情報ではないため、設定は不要です。release workflow
(`.github/workflows/release.yml`) はバージョンを**タグから解決**し、出力先は
`sign.sh` の既定 (`dist/`) を使います。上の 2 つの表は、workflow が読む secrets と
ローカルで `sign.sh` を直に使うときの引数 / 環境変数の対応です。

GitHub のログに秘密値を表示しないでください。workflow 終了時は一時 Keychain と API キーの
一時ファイルを削除します (`sign.sh` が作った API キーファイルは trap で削除されます)。

## 5. リリース前の確認

証明書と API キーを持つ担当者は、上記手順で notarization まで実行した後に確認します。

```sh
codesign --verify --deep --strict --verbose=2 "/path/to/KildeGUI.app"
spctl --assess --type open --context context:primary-signature -vv "dist/KildeGUI-0.2.0.dmg"
xcrun stapler validate "dist/KildeGUI-0.2.0.dmg"
```

CLI は zip を展開して `codesign --verify --strict --verbose=2 kilde` と
`codesign -d --entitlements :- kilde` を実行し、別の macOS ユーザー環境で初回起動時の
Gatekeeper と TCC (画面収録・マイク) の動作も確認してください。

## GitHub でのリリース自動化

`.github/workflows/release.yml` が `v*` タグの push で起動します:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

フロー: 本リポジトリと kilde-team/kilde-cli-swift (pin 固定、`KILDE_CLI_SWIFT_TOKEN`
で checkout) を取得 → タグからバージョンを解決 (手動実行時は kilde-cli-swift の
`Info.plist` 由来) → `kilde-cli-swift/Sources/kilde/Info.plist`、`gui/Resources/Info.plist`、
`KildeCommand.swift` の version に差し込み (ビルド限り、コミットはしない) →
`swift build -c release --package-path kilde-cli-swift` → 埋め込み Info.plist の生存と
バージョンを検証 → 署名 → Release を作成して zip (署名時は GUI の DMG も) を添付。

**署名は secrets の有無で自動分岐**:

| secrets | 動作 |
|---------|------|
| §4 の署名用 6 secret がすべて設定済み (`DEVELOPER_ID_CERTIFICATE_BASE64` + `DEVELOPER_ID_CERTIFICATE_PASSWORD` + `DEVELOPER_ID_APPLICATION` + `AC_API_KEY` + `AC_API_KEY_ID` + `AC_API_ISSUER`) | 証明書を一時キーチェーンに import → `sign.sh` で署名・notarization・staple まで実行 |
| 未設定 (v0.1.0 時点) | **unsigned zip** でリリース。Release Notes に「未署名」の注意と `xattr -d` の回避方法を明記 |

証明書を取得したら §4 の 6 つの secrets を足すだけで署名に切り替わります
(ワークフロー側の変更は不要)。`DEVELOPER_ID_CERTIFICATE_BASE64` は「Developer ID
Application」の .p12 を `base64 -i cert.p12 | pbcopy` でエンコードしたもの。

**手動検証** (タグを打たずにビルドだけ確認): Actions タブから `Release` ワークフローを
`workflow_dispatch` で実行。**手動実行は常に dry-run** (ビルドと署名分岐までを検証、
Release は作成しない) — タグが無いと Info.plist 由来の現在値でリリースを作りかねないため、
Release の作成は `v*` タグの push に限定しています。

### CLI ソースの pin の更新

workflow は kilde-cli-swift を **revision 固定**で checkout します
(`release.yml` の `ref:`。現在は GUI (`gui/project.yml` の pin) と同じ
`5518a5d79826c5e0f918f57d8d19e719ac44eb83`)。pin は「リリース成果物がどのコミットで
ビルドされたか」を追跡可能にするための固定で、GUI と release が同じエンジンを参照する
契約です。**更新するときは `gui/project.yml` と `release.yml` の `ref:` を同じ PR で
必ず揃えてください** (片方だけ更新すると、GUI と CLI が別のエンジン revision で
ビルドされます)。

### Homebrew tap の更新

次リリース (`v0.2.0` 以降) では、Release に添付された zip のハッシュを formula に書いて
tap へ反映します。formula の正本は本リポジトリの `homebrew/Formula/kilde.rb` で、
[takezou621/homebrew-kilde](https://github.com/takezou621/homebrew-kilde) (public) に
反映して初めてユーザーに届きます。

```sh
# Release ページ (または gh release download) から zip を取得してハッシュを計算
shasum -a 256 kilde-0.2.0-macos.zip
```

1. `homebrew/Formula/kilde.rb` の `url` を `.../download/v0.2.0/kilde-0.2.0-macos.zip` に、
   `sha256` を計算値に更新する (本リポジトリの PR として)
2. 同じ内容を takezou621/homebrew-kilde の formula に反映する
3. 反映後に `brew install takezou621/kilde/kilde` (または `brew upgrade`) で動作を確認する
   (`kilde --version` が新バージョンを返すこと)

**zip は arm64 (Apple Silicon) ビルドのみ**です。Formula には
`depends_on arch: :arm64` を置いてあり、Intel への誤 install を brew が拒否します。
tap 側へ反映するときも同じ行を消さないこと。Intel 対応 (universal binary) を
始めるときは、release workflow・Formula・README の arm64 記載を一体で見直す。

CLI のソースは kilde-team/kilde-cli-swift (private) に分離されたため、head ブロック
(`brew install --HEAD` による外部からのソースビルド) は廃止しました。

### 未実装 (follow-up)

- **formula 更新の自動化** — 上の tap 更新手順は手動。workflow から tap へ更新 PR を
  送るジョブを追加する (PAT の権限設計が必要なため別 issue で)
- **Release Notes の自動生成 (PR タイトル由来)** — 初回リリース後に手順を確定させる
