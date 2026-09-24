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
6. GUI の DMG に Sparkle の EdDSA 署名をして `dist/appcast.xml` を作る (§5。
   `--skip-notarize` でも生成する — appcast が無いと GUI の自動更新が壊れるため)

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
| `--sign-update` | `KILDE_SIGN_UPDATE` | Sparkle の EdDSA 署名ツール `sign_update` のパス (§5) |

引数と環境変数を両方指定した場合は引数が優先されます。

## 4. GitHub Actions 用 Secrets

release workflow から `sign.sh` へ渡す名前は次で固定し、証明書の import と一時
Keychain の作成は workflow 側で行います。

署名用の 6 secrets と、GUI 自動更新 (Sparkle) 用の 1 secret:

| GitHub Secret | workflow での用途 / `sign.sh` との対応 |
|---------------|-----------------------------------------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID 証明書と秘密鍵を含む `.p12` の Base64。workflow が一時 Keychain に import |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` の書き出しパスワード |
| `DEVELOPER_ID_APPLICATION` | `sign.sh` の `--identity` / 同名環境変数 |
| `AC_API_KEY_ID` | `sign.sh` の `--key-id` / 同名環境変数 |
| `AC_API_ISSUER` | `sign.sh` の `--issuer` / 同名環境変数 |
| `AC_API_KEY` | `.p8` の内容。workflow が権限 600 の一時ファイルにして `--key` へ渡す |
| `SPARKLE_ED25519_PRIVATE_KEY` | Sparkle の EdDSA 秘密鍵 (base64、§5)。workflow が `sign.sh` の環境変数へ渡す。署名ブランチでは**必須** — 無いとジョブが失敗する |

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

## 5. Sparkle (GUI 自動更新) の鍵と appcast

GUI は Sparkle 2 でアプリ内更新を行い、更新情報 (appcast) と DMG の EdDSA 署名を
`sign.sh` が生成します (issue #122)。EdDSA 鍵は Apple の証明書とは別の、Sparkle 専用の鍵対です。

### 鍵の生成と登録 (最初の 1 回)

`generate_keys` / `sign_update` は homebrew に formula が無く、SPM checkout
(バイナリターゲット) にも含まれないため、**GitHub Releases の tar.xz** から取ります:

```sh
curl -fsSL -o /tmp/Sparkle-2.10.0.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
# tarball をパイプで直接展開しない — SHA-256 が一致するか見てから展開する
# (sign_update は署名鍵のある環境で動くため、差し替え資産を展開・実行させない。
#  release workflow も同じ固定値で検証している)
echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  /tmp/Sparkle-2.10.0.tar.xz" \
  | shasum -a 256 --check || { echo "SHA-256 が一致しません"; exit 1; }
tar -xJf /tmp/Sparkle-2.10.0.tar.xz -C /tmp
/tmp/bin/generate_keys            # login Keychain に鍵対を生成
/tmp/bin/generate_keys -p         # 公開鍵を表示 → gui/Resources/Info.plist の SUPublicEDKey へ
/tmp/bin/generate_keys -x /tmp/sparkle-private-key.txt   # 秘密鍵を export
```

1. `generate_keys -p` の出力 (base64 1 行) を `gui/Resources/Info.plist` の
   `SUPublicEDKey` に書く (リポジトリにコミットしてよい — 公開鍵なので)
2. 秘密鍵 (export した 1 行) を GitHub Secret **`SPARKLE_ED25519_PRIVATE_KEY`** に登録する
3. **秘密鍵は失うと既存ユーザーの更新ができなくなります** — 新しい鍵対で署名した
   appcast は、古いアプリ (古い公開鍵入り) は検証できないためです。鍵のバックアップを
   取り、GitHub Secret と同じ値を安全な場所に保管してください

バージョンは `gui/project.yml` の Sparkle の `exactVersion` と揃えます
(上の URL の `2.10.0`。release workflow も同じバージョンをダウンロードする)。

### ローカルでの署名

`sign.sh` は `SPARKLE_ED25519_PRIVATE_KEY` 環境変数があればそれを stdin で
`sign_update` に渡し、無ければ **login Keychain の鍵** (`generate_keys` で作ったもの) を
使います。ローカルで `--skip-notarize` を試す場合は Keychain に鍵があるため設定不要で、
`sign_update` のパスだけ `--sign-update` / `KILDE_SIGN_UPDATE` で渡します。

### 運用上の契約

- **EdDSA 署名は staple の後**: `stapler staple` は DMG を書き換えるため、先に署名すると
  配布物と署名の対象が食い違い Sparkle が更新を拒否します。`sign.sh` はこの順序を保証します
- **一度 Sparkle を公開したら、以降の全リリースを署名ありにする**: SUFeedURL は
  `releases/latest/download/appcast.xml` の固定 URL なので、appcast の無いリリースが
  latest になると**全ユーザーの更新チェックが 404 で壊れます**。そのため release workflow は
  署名ブランチで `dist/appcast.xml` が無ければジョブを失敗させる設計にしてあります
- `sparkle:version` (= GUI の `CFBundleVersion`) はリリースごとに**単調増加させる** —
  Sparkle はバージョン文字列ではなくこの値で更新を判定します。release workflow が
  `GITHUB_RUN_NUMBER` を差し込むため、タグを打つたびに自動的に増えます

## 6. リリース前の確認

証明書と API キーを持つ担当者は、上記手順で notarization まで実行した後に確認します。

```sh
codesign --verify --deep --strict --verbose=2 "/path/to/KildeGUI.app"
spctl --assess --type open --context context:primary-signature -vv "dist/KildeGUI-0.2.0.dmg"
xcrun stapler validate "dist/KildeGUI-0.2.0.dmg"
```

CLI は zip を展開して `codesign --verify --strict --verbose=2 kilde` と
`codesign -d --entitlements :- kilde` を実行し、別の macOS ユーザー環境で初回起動時の
Gatekeeper と TCC (画面収録・マイク) の動作も確認してください。

## 7. App Store 配布ビルド (issue #126)

GUI は **直接配布 (Sparkle 自動更新) と Mac App Store の 2 チャネルで併存**します。
両方ともバンドル ID は `com.takezou621.KildeGUI` で、App Store 版は
`KildeGUI-AppStore` ターゲットからビルドします。App Store 版の要件:

- **App Sandbox が必須** — `gui/Resources/KildeGUI-AppStore.entitlements`
  (app-sandbox + マイク + `~/Movies` + ユーザー選択ファイル + app-scope bookmark)
- **Sparkle を含めない** — ストア外自己更新の仕組みのため審査で拒否される。
  `UpdaterCoordinator.swift` 全体が `#if !APPSTORE` で、MAS ビルドでは
  `UpdaterCoordinatorAppStore.swift` のスタブに差し替わる。UI の「アップデート」
  セクションも `#if !APPSTORE` で消える
- サンドボックス下では `~/.kilde` が読めないため、設定はアプリコンテナ内
  (`~/Library/Containers/com.takezou621.KildeGUI/Data/Library/Application
  Support/kilde/`) に保存される (SandboxSupport が `ConfigStore.directory` を退避)。
  保存先ディレクトリは NSOpenPanel で選んだ security-scoped bookmark を
  UserDefaults に永続化する。**CLI との設定共有は MAS 版では発生しない**

### ビルドとアップロード (`scripts/release/appstore-archive.sh`)

```sh
# この Mac で完結 (既定) — Xcode にログイン済みの Apple ID が
# 証明書・プロファイル・アップロードに使われる
scripts/release/appstore-archive.sh --version 0.4.0 --build 42          # .pkg まで
scripts/release/appstore-archive.sh --version 0.4.0 --build 42 --upload # ASC へアップロードまで

# ASC API キーを使う場合 (CI など Apple ID でログインできない環境)。
# キーの作り方は §2 と同じ。**キーにはクラウド署名の権限 (App Manager 以上) が必要**
export AC_API_KEY="$HOME/private/AuthKey_ABC123.p8"
export AC_API_KEY_ID=ABC123
export AC_API_ISSUER=00000000-0000-0000-0000-000000000000
scripts/release/appstore-archive.sh --version 0.4.0 --build 42
```

スクリプトは xcodegen → パッケージ解決 →
バージョン差し込み (plutil。**追跡対象の Info.plist への書き換えだが、スクリプトが
終了時に元へ復元する** — release.yml と同じビルド時差し込みで、コミットはしない) →
`xcodebuild archive` → 検証 (アーカイブ内に
**Sparkle.framework が無いこと・App Sandbox エンタイトルメントが true であること**を
確認してから次へ進む) → `exportOptions.plist` 生成 → `.pkg` 書き出し
(または `--upload` でアップロードまで) を行う。

- `--build` は **App Store Connect にアップロード済みの最大値より大きい値が必須**
  (Sparkle の CFBundleVersion 単調増加と同じ契約)。基準は «前回の提出» ではない —
  提出せずに残っているアップロード済み build (TestFlight 用など) があると、
  それより大きくないと拒否される (cubic レビュー指摘)。リポジトリには番号を追跡する
  仕組みが無いので、ASC の「TestFlight > macOS ビルド」で最大値を見てから決める
- 証明書 (`Apple Distribution` と Mac Installer) とプロビジョニングプロファイルは
  `-allowProvisioningUpdates` が**自動作成する** — 手動での証明書発行は不要。
  API キーを渡さなければ Xcode の Apple ID セッションが使われる (開発機ならこれで
  十分。v0.3.0 build 1 の .pkg 生成で実測)。API キーを渡すのにクラウド署名の権限が
  無いと .pkg 書き出しが "Cloud signing permission error" で失敗する (Xcode 26 実測)
- アーカイブ段階の署名は Apple Development (自動署名)。**ここで Apple Distribution を
  指定すると「conflicting provisioning settings」で xcodebuild が失敗する** —
  配布署名は `-exportArchive` 時に適用される (スクリプトが差し替える。Xcode 26 実測)
- **提出に必須の Info.plist キー** (欠けるとアップロードやビルド処理で止まる。v0.3.0 build 2 の
  提出で実測): `LSApplicationCategoryType` (= `public.app-category.utilities`。無いと
  アップロードが "must contain a LSApplicationCategoryType key" で拒否される) と
  `ITSAppUsesNonExemptEncryption` (= false。無いとビルドが「コンプライアンスがありません」で
  止まり、ASC での申告を毎回求められる)。暗号化 API や独自の通信を足したら後者を見直す
- アイコンは KildeGUI と同じ `Resources/Assets.xcassets` を App Store ターゲットの
  `sources` にも入れて結線する (`ASSETCATALOG_COMPILER_APPICON_NAME` も両ターゲットに必要)
- `--upload` しても**審査は始まらない**。アップロード後、App Store Connect の
  TestFlight / App Store 提出画面で提出する

### スクリプトで自動化できない手作業 ( ASC の画面または ASC API)

1. **アプリレコードの作成** (初回のみ) — App Store Connect で「新規 App」を作成
   (バンドル ID `com.takezou621.KildeGUI`、SKU など)
2. **プライバシーラベル (App Privacy) の入力** — Firebase Analytics (#136) に合わせて
   「おおよその場所・デバイス ID・製品の操作」(いずれもアナリティクス目的、ユーザに関連付けない、
   トラッキングなし) を申告する (2026-09-23 に公開済み。収集するデータを変えたら更新する)。
   あわせて画面収録・マイクの用途説明
3. **審査への提出** — アップロード済みビルドの選択と提出

アップロードの方法が `--upload` (xcodebuild が直接アップロード) で失敗する環境
(ネットワーク制限など) では、`--upload` 無しで書き出した `.pkg` を Transporter app
でアップロードできる。`xcrun altool --upload-app` も **Xcode 26 でまだ動く**
(`xcrun altool --version` → 27.0.5 (2.1) を実測。cubic の「Xcode 26 では実行できない」は
この環境では再現しなかった) が、Apple は非推奨としているので Transporter を先に試すこと。

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

**署名は必須 (secrets 不足でジョブが失敗する)**:

| secrets | 動作 |
|---------|------|
| §4 の署名用 6 secret がすべて設定済み (`DEVELOPER_ID_CERTIFICATE_BASE64` + `DEVELOPER_ID_CERTIFICATE_PASSWORD` + `DEVELOPER_ID_APPLICATION` + `AC_API_KEY` + `AC_API_KEY_ID` + `AC_API_ISSUER`) | 証明書を一時キーチェーンに import → `sign.sh` で署名・notarization・staple と appcast 生成 (§5) まで実行 |
| 一部でも未設定 / すべて未設定 | **ジョブを失敗させる** (unsigned zip でのリリースは行わない) |

v0.2.0 以降は署名ありリリースで運用しており、GUI は Sparkle で latest の
appcast を見にいく — 署名なしリリースが latest になると appcast が 404 になり
全ユーザーの更新チェックが壊れるため、secrets 不足で unsigned に落ちる経路は
持たせない (cubic レビュー指摘により v0.1.0 時代の unsigned 分岐は廃止)。
`DEVELOPER_ID_CERTIFICATE_BASE64` は「Developer ID
Application」の .p12 を `base64 -i cert.p12 | pbcopy` でエンコードしたもの。
署名には Sparkle の `SPARKLE_ED25519_PRIVATE_KEY` (§5) も必要です —
この secret が無いとジョブは appcast 生成の前で失敗します。

**手動検証** (タグを打たずにビルドだけ確認): Actions タブから `Release` ワークフローを
`workflow_dispatch` で実行。**手動実行は常に dry-run** (ビルドと署名分岐までを検証、
Release は作成しない) — タグが無いと Info.plist 由来の現在値でリリースを作りかねないため、
Release の作成は `v*` タグの push に限定しています。

### CLI ソースの pin の更新

workflow は kilde-cli-swift を **revision 固定**で checkout します
(`release.yml` の `ref:`。現在は GUI (`gui/project.yml` の pin) と同じ
`4d2f251535ed6e907fea185e116ed9b9eb1392b3`)。pin は「リリース成果物がどのコミットで
ビルドされたか」を追跡可能にするための固定で、GUI と release が同じエンジンを参照する
契約です。**更新するときは `gui/project.yml` と `release.yml` の `ref:` を同じ PR で
必ず揃えてください** (片方だけ更新すると、GUI と CLI が別のエンジン revision で
ビルドされます)。

### Homebrew tap の更新

次リリース (`v0.2.0` 以降) では、Release に添付された zip のハッシュを formula に書いて
tap へ反映します。formula の正本は本リポジトリの `homebrew/Formula/kilde.rb` で、
[kilde-team/homebrew-kilde](https://github.com/kilde-team/homebrew-kilde) (public) に
反映して初めてユーザーに届きます。

```sh
# Release ページ (または gh release download) から zip を取得してハッシュを計算
shasum -a 256 kilde-0.2.0-macos.zip
```

1. `homebrew/Formula/kilde.rb` の `url` を `.../download/v0.2.0/kilde-0.2.0-macos.zip` に、
   `sha256` を計算値に更新する (本リポジトリの PR として)
2. 同じ内容を kilde-team/homebrew-kilde の formula に反映する
3. 反映後に `brew install kilde-team/kilde/kilde` (または `brew upgrade`) で動作を確認する
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
