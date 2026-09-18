# 開発ハンドブック

kilde リポジトリ (GUI・配布・ドキュメント) をローカルでビルド・実行・検証するための手順書。

録画エンジン (`KildeCore`) と CLI (`kilde`) のソースは
**[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift) (private)**
にあり (issue #115 で分離)、そのビルド・単体テスト・統合テスト・トラブルシュートは
同リポジトリのドキュメントと `CLAUDE.md` / `AGENTS.md` が正本です。
このファイルは GUI と、エンジンを利用する側 (配布) の手順を扱います。

設計の背景は [DESIGN.md](DESIGN.md)、macOS 26 での実測結果は
[SPIKE-NOTES.md](SPIKE-NOTES.md)、AI エージェント向けの要約は
リポジトリ直下の [CLAUDE.md](../CLAUDE.md) にあります。

## 1. 前提環境

| 項目 | 要件 |
|------|------|
| OS (実行対象) | **macOS 14+** (GUI の deployment target — `gui/project.yml` の `deploymentTarget`)。動作検証は macOS 26 / Apple Silicon のみ |
| OS (開発環境) | macOS 26 (Apple Silicon)。**実検証済みはこの構成のみ** |
| ツールチェーン | Xcode 26 以降 (**macOS 26 SDK 必須**) — GUI が参照する KildeCore が macOS 26 の API (`captureHDRRecordingPreservedSDRHDR10` など) を使うため。26 未満の SDK ではパッケージのビルドが `has no member` で失敗します |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `brew install xcodegen` (`.xcodeproj` はコミットせず `project.yml` から生成する) |
| kilde-team メンバー権限 | GUI は kilde-team/kilde-cli-swift (private) をパッケージ依存で参照するため、パッケージ解決には**同リポジトリを読める git 認証**が必要。Xcode の SwiftPM 解決は `https://github.com/kilde-team/kilde-cli-swift.git` で clone するため、**HTTPS で認証できること**が条件。手軽なのは fine-grained PAT (kilde-cli-swift へ contents:read) を macOS キーチェーン (`osxkeychain` credential helper) に保存する方法。SSH 鍵で運用している場合は `git config --global url."ssh://git@github.com/kilde-team/".insteadOf "https://github.com/kilde-team/"` の url 置換で kilde-team 配下の HTTPS URL だけを SSH へ書き換える。**prefix を `https://github.com/` まで広げないこと** — `url."ssh://git@github.com/".insteadOf "https://github.com/"` とすると、kilde-team 以外も含む github.com 配下のすべての HTTPS clone が SSH へ書き換わり、PAT 運用の他リポジトリや SSH 鍵の無い環境で失敗する (insteadOf は先頭一致の prefix 置換) |
| 任意 | BlackHole — `brew install --cask blackhole-2ch` (セルフテストの入力デバイス指定 `KILDE_GUI_SELFTEST_AUDIO=device:BlackHole 2ch` でスピーカーを介さず信号を入れる、またはクラムシェル検証のために既定出力を切り替える場合。§3 参照) |
| 任意 | `kilde-dev` 自己署名証明書 — TCC 権限のトグルを安定させる (§3 の注意を参照) |

## 2. 権限 (TCC) のセットアップ

kilde は macOS のプライバシー権限を 2 種類使います。**どちらも「実行したバイナリ」
単位ではなく「起動元のプロセス」単位で記録される**ため、Xcode からビルドした
KildeGUI には KildeGUI を、ターミナルからセルフテストを実行する場合は
ターミナル.app や iTerm など、実行に使うアプリに対して許可を与えることになります。

| 権限 | いつ必要か | 与え方 |
|------|-----------|-------|
| 画面収録 (画面とオーディオを収録) | 映像を録るとき、およびシステム音声を拾うとき | システム設定 → プライバシーとセキュリティ → 画面とオーディオを収録 |
| マイク | マイク・入力デバイスを録るとき | システム設定 → プライバシーとセキュリティ → マイク |

**画面収録は許可した後にプロセスの再起動が必要**です。マイク権限が「拒否済み」に
なるとダイアログは二度と出ません。システム設定から手動で有効化します。

> 補足: CLI 側のマイク用途説明 (`NSMicrophoneUsageDescription`) は、エンジン側
> (kilde-cli-swift) の `Sources/kilde/Info.plist` をリンカで実行ファイルに埋め込んで
> 解決されます。GUI 側は `gui/Resources/Info.plist` (バンドル) と
> `gui/Resources/KildeGUI.entitlements` (Hardened Runtime 下のマイクに必須の
> `com.apple.security.device.audio-input`) を使います。

## 3. ビルドと実行 (GUI)

`.xcodeproj` はコミットしていないため、[XcodeGen](https://github.com/yonaskolb/XcodeGen)
で生成してから Xcode でビルドします (録画エンジンは kilde-team/kilde-cli-swift
(issue #115 で分離) の KildeCore を **revision 固定**のリモートパッケージ依存で共有。
**private リポジトリのため、パッケージ解決には kilde-team のメンバー権限の git 認証が必要**):

```sh
brew install xcodegen   # 初回のみ
cd gui && xcodegen      # project.yml から KildeGUI.xcodeproj を生成
open KildeGUI.xcodeproj # Xcode で KildeGUI スキームを Run
```

コマンドラインだけで検証する場合:

```sh
cd gui && xcodegen
xcodebuild -resolvePackageDependencies
xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI -configuration Debug build
```

`project.yml` を変更したら `xcodegen` を再実行してください (再生成し忘れによる乖離を
防ぐため、変更は必ず project.yml 側に行う)。GUI が参照するエンジンの revision は
`project.yml` の pin で固定してあり、リリース workflow (`release.yml`) と同じ値を
指す契約です。更新手順は [RELEASE.md](RELEASE.md) を参照してください。

メニューバーの ● をクリックすると録画パネルが開きます (issue #18):
収録対象 (画面 / ウィンドウ (サムネイル付き) / 音声のみ)・音声ソース (システム音声 /
マイク / 入力デバイス)・複数ソースの合成か分離・保存先を選んで「録画開始」。
録画中はメニューバーに経過時間が出て、パネルにはソース別のレベルメーターと停止ボタンが
出ます。**パネルを閉じても録画は続きます** (録画はパネルではなく AppDelegate が持つ
`RecordingController` にある)。録画中にアプリを終了すると、停止してファイナライズを
待ってから終わります。

- 選択 → 録画オプションの変換は KildeCore の `RecordRequest` で行い、CLI と同じ
  `RecordSettings.apply()` → `Recorder` を通る (codec / fps / カーソルは設定ファイルの値)
- 初期値は `~/.kilde/config.json` から読む。GUI の操作で設定ファイルは書き換えず、
  「この音声・保存先の選択を既定にする」を押したときだけ保存する (CLI の既定も変わるため)
- 設定に保存先が無いときは `~/Movies` に保存する (GUI はカレントディレクトリが `/` のため)

権限が足りない構成を選ぶと、パネルに案内が出て「録画開始」が押せなくなります (issue #19)。
判定は CLI の `kilde doctor` と同じ `KildeCore.Permissions` を使い、**その構成に要る権限だけ**を
求めます — 音声のみ + マイクのみの録音では画面収録権限を求めません。画面収録の権限は
許可してもプロセスを再起動するまで有効にならないため、案内も再起動を促す文面に変わります。
macOS 15 以降は一度許可した画面収録権限が定期的に再確認されて失効しうる (DESIGN.md F4) ので、
パネルを開くたびと録画開始の直前に取り直します。

### GUI 経由の録画をコマンドラインで確かめる (セルフテスト)

環境変数を付けて実行ファイルを直接起動すると、UI を操作せずに GUI と同じ経路
(`RecordingSetup` → `RecordRequest` → `RecordingController` → `Recorder`) で
ディスプレイ 0 + システム音声を録画して終了します。
ターミナルから直接起動した場合、画面収録の権限はターミナルのものが使われます:

```sh
APP=$(xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI -configuration Debug \
      -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/KildeGUI.app
KILDE_GUI_SELFTEST_RECORD=3 KILDE_GUI_SELFTEST_OUTPUT=/tmp "$APP/Contents/MacOS/KildeGUI"
# → selftest: finished /tmp/kilde-yyyyMMdd-HHmmss.mp4 (終了コード 0。既定コンテナは
#   mp4 — kilde-cli-swift#24。設定 format=mov や ProRes 退避なら .mov になる)
# inspect には finished に表示されたパスをそのまま渡す。kilde-*.mp4 の glob だと
# format=mov 等で .mov になった出力を取りこぼす
kilde inspect /tmp/kilde-yyyyMMdd-HHmmss.mp4   # CLI の録画と同じトラック構成か確認
#   (kilde は brew install kilde-team/kilde/kilde のバイナリか、
#    kilde-cli-swift を swift build したものを使う)
```

`KILDE_GUI_SELFTEST_AUDIO` で音声ソースを変えられます: `system` (既定) / `none` (映像のみ — 音声出力が
使えない環境でも GUI → Recorder の経路は確かめられる) / `device:<UID または名前>`
(例: `device:BlackHole 2ch`。スピーカーを介さずに信号を入れて検証でき、既定の出力デバイスも変えずに済む)。

`KILDE_GUI_SELFTEST_POPOVER=close` を付けると、録画中にポップオーバーを開いてから閉じ、
**閉じた後も録画が続く** (経過時間が伸びる) ことを成功条件にします (issue #18 の受け入れ条件 2)。
`KILDE_GUI_SELFTEST_FORCE_CLOSE_FAIL=1` を併用すると閉じる操作をわざと行わず、
「閉じられなかったときに終了コード 1 で失敗する」ことを確認できます — セルフテスト自身の
失敗経路を踏むための指定で、これが無かったために「閉じ失敗を exit 0 と誤判定する」回帰を
見逃しました。

`KILDE_GUI_SELFTEST_PERMISSIONS=1` は録画せず、**構成ごとにどの権限を要求するか**を出して終わります
(issue #19)。TCC の許可を実際に取り消さなくても「音声のみの録音に画面収録権限を求めない」などの
判定を確認できます:

```sh
KILDE_GUI_SELFTEST_PERMISSIONS=1 "$APP/Contents/MacOS/KildeGUI"
# → selftest: screen=true mic=authorized
#   selftest: [画面 + システム音声] needsScreen=true needsMic=false missing=なし
#   selftest: [画面 + マイク] needsScreen=true needsMic=true missing=なし
#   selftest: [音声のみ + システム音声] needsScreen=true needsMic=false missing=なし
#   selftest: [音声のみ + マイクのみ] needsScreen=false needsMic=true missing=なし
#   selftest: [音声のみ + 入力デバイス指定] needsScreen=false needsMic=true missing=なし
```

`KILDE_GUI_SELFTEST_DENY=screen,mic` を付けると、**実際には許可されている権限を「無い」ことにして**
扱えます。権限を外さずに「案内が出る」「録画開始が押せない」経路を踏めるので、セルフテストの
権限レポートと併用して確認します (通常起動で付ければ、案内そのものを目で見ることもできます):

```sh
KILDE_GUI_SELFTEST_PERMISSIONS=1 KILDE_GUI_SELFTEST_DENY=screen "$APP/Contents/MacOS/KildeGUI"
# → selftest: screen=false mic=authorized
#   selftest: [画面 + システム音声] needsScreen=true needsMic=false missing=screen
#   selftest: [画面 + マイク] needsScreen=true needsMic=true missing=screen
#   selftest: [音声のみ + システム音声] needsScreen=true needsMic=false missing=screen
#   selftest: [音声のみ + マイクのみ] needsScreen=false needsMic=true missing=なし
#   selftest: [音声のみ + 入力デバイス指定] needsScreen=false needsMic=true missing=なし
```

画面収録を拒否しても「音声のみ + マイクのみ」が `missing=なし` のままである点が、この機能の要です
(要らない権限を求めない)。

案内の文面や配置そのものは、最終的には人の目で確認してください。

`KILDE_GUI_SELFTEST_UPDATE=1` は録画せず、**Sparkle 自動更新の配線と設定**を確かめて
終わります (issue #122)。SUFeedURL / SUPublicEDKey / CFBundleVersion の形式、
AppDelegate が持つ UpdaterCoordinator との配線、更新チェック可能になること
(`canCheckForUpdates`)、録画中のインストール判定 (`installAction`) の全ケースを検証します:

```sh
KILDE_GUI_SELFTEST_UPDATE=1 "$APP/Contents/MacOS/KildeGUI"
# → selftest: SUFeedURL=https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml
#   selftest: SUPublicEDKey=… selftest: CFBundleVersion=1
#   selftest: delegate=ok updaterOwned=true
#   selftest: canCheckForUpdates=true
#   selftest: installAction[録画中]=afterStop … (exit 0)
```

**このセルフテストで「通った」にできないもの**: 更新のダウンロード・EdDSA 検証・
インストール・再起動。これらは Developer ID 署名同士のビルドでしか成立せず、
実機 E2E は v0.3.0 → v0.3.1 のリリースで手動確認します (SelfTest.swift の線引きコメント
と同じ)。また、v0.3.0 より前は Releases に appcast が無いため、**手動の更新チェックが
404 エラーになるのが正常**です。

### 検証時の環境の注意

> 画面がロックされている、または**ディスプレイが消灯している**間は
> SCK がフレームを出しません。録画は成功 (exit 0) するのに `kilde inspect` が `duration=0.00s` に
> なります (CLI も同じ)。実録画の検証はロックを解除してから行ってください。
> **消灯対策は「起こす」と「消させない」の 2 段構え**です — `caffeinate -dims` は自動消灯を
> 止めるだけで、**すでに消えているディスプレイは起こしません**。録画を始める前に
> `caffeinate -u -t 1` で起こし、続けて `caffeinate -dims -w $$ &` で保持します
> (消えたまま録ると、1 フレームも来ないまま録画時間だけが過ぎ、出力ファイルすら作られません)。
> ロック画面はこの方法では解除できないので、人手でのロック解除が必要です。また、蓋を閉じたクラムシェル運用で既定出力が内蔵スピーカーだと、
> `afplay` が `AudioQueueStart failed (-66681)`、SCK のシステム音声が `-3818` で失敗します。
> 既定出力を外部スピーカーや BlackHole ループバックに変えてから検証してください。

> **マイクのエンタイトルメント**: Hardened Runtime 下でマイク・入力デバイスを使うには
> `com.apple.security.device.audio-input` が必要です (`gui/Resources/KildeGUI.entitlements`)。
> 欠けるとエラーもクラッシュもなく無音のトラックになります。GUI にはマイクの TCC 権限も
> 別途必要です (初回の録画開始時にダイアログが出る)。

> **GUI にも権限が必要**: ディスプレイ/ウィンドウ一覧には画面収録権限が要ります
> (CLI とは別プロセスなので、CLI に許可があっても別途付与が必要)。
> システム設定 → プライバシーとセキュリティ → 画面とオーディオを収録 に
> KildeGUI を追加し、**アプリを再起動**してください (画面収録権限はプロセスの
> 再起動で有効化 — CLI の `doctor` と同じ仕様)。未付与の間はオーディオ機器
> 一覧のみ表示され、パネルには権限の案内が出ます (issue #19)。
> 音声のみ + マイク/入力デバイスの録音は画面収録権限なしでも開始できます。

> **開発用署名証明書 (kilde-dev)**: TCC 権限はコード署名でアプリを識別するため、
> ad-hoc 署名のビルドでは権限のトグルが再起動のたびに外れることがある。
> `gui/project.yml` は `kilde-dev` という名前の自己署名コード署名証明書で署名する
> 設定にしてある。無い場合はキーチェーンアクセス → 証明書アシスタント →
> 「証明書を作成」で以下のように作成する:
>
> - 名前: `kilde-dev` / 認証タイプ: 自己署名ルート / 「デフォルトを上書き」✅
> - 有効期間: 3650 日 / 拡張キー使用: **コード署名** / 鍵: RSA 2048 (既定)
> - 作成先: ログインキーチェーン

> 補足: ローカル署名ビルド (kilde-dev) や Xcode の実行では、コンソールに
> `com.apple.linkd.autoShortcut` への接続エラーや "Error registering app with
> intents framework" が出ることがあります。これは App Shortcuts 登録まわりの
> システムサービス接続のノイズで、KildeGUI は AppIntents を使わないため機能に
> 影響しません (正式な Developer ID 署名では出なくなると考えられます)。

> **Sparkle (GUI 自動更新、issue #122)**: Debug ビルドは
> `SUEnableAutomaticChecks=false` を UserDefaults に書き込みます —
> 開発機が実フィード (`releases/latest/download/appcast.xml`) を定期的に見に
> いかないようにするため (SU* キーは UserDefaults が Info.plist より優先される。
> キー名は Sparkle 2 の `SUEnableAutomaticChecks` — Sparkle 1 の
> `SUAutomaticallyChecksForUpdates` は効かない)。
> **この値は Release ビルドにも効いてしまう**ので、開発が終わったら開発機を
> 出荷時状態に戻す後始末として削除します。なお**手動の更新チェック**
> (ポップオーバーの「アップデートを確認」) はこの値に関係なく動く —
> 削除し忘れても手動チェックの成否には影響せず、影響するのは自動チェックだけ:
>
> ```sh
> defaults delete com.takezou621.KildeGUI SUEnableAutomaticChecks
> ```
>
> ダウンロード〜再起動までの E2E をリリース前に確認したいときは、フィードを
> ローカルに差し替えられます (同じく UserDefaults が優先されるのを利用):
>
> ```sh
> # ローカル HTTP サーバ (appcast.xml と DMG を置く) を立てて差し替え
> defaults write com.takezou621.KildeGUI SUFeedURL http://127.0.0.1:8000/appcast.xml
> # 確認が終わったら戻す (Info.plist の値へ戻る)
> defaults delete com.takezou621.KildeGUI SUFeedURL
> ```
>
> 鍵と appcast の運用は docs/RELEASE.md §5、録画中の再起動待ちの設計は
> docs/DESIGN.md §9 を参照してください。

### App Store 配布ビルド (KildeGUI-AppStore) のビルドと検証 (issue #126)

App Store 申請用のサンドボックスビルドは、通常の KildeGUI スキームとは別の
`KildeGUI-AppStore` スキームで行います (`gui/project.yml` の同名ターゲット。
Sparkle 無し・App Sandbox 有効 — 詳細は docs/RELEASE.md §7):

```sh
cd gui && xcodegen
# **最初のビルドから -derivedDataPath を付ける** — PRODUCT_NAME が直接配布版と同じ
# KildeGUI のため、標準 DerivedData を使い回すと以前の Sparkle.framework が成果物に
# 残ることがある (下の説明も参照)
xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI-AppStore \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/kilde-mas
# CODE_SIGNING_ALLOWED=NO は **コンパイル確認のみ** — 署名と entitlements の埋め込みが
# 行われないため、App Sandbox の実行時挙動はこのビルドでは検証できない。
# サンドボックス下の動作は下の ad-hoc 署名ビルドで確かめる
# 両スキームを触ったときは **どちらも** ビルドを通すこと。#if APPSTORE の
# 分岐漏れ (import Sparkle の位置など) は通常ビルドでは検出できない
```

**DerivedData を分離する** — PRODUCT_NAME が直接配布版と同じ KildeGUI のため、
共通の DerivedData を使い回すと以前の KildeGUI ビルドの Sparkle.framework が
成果物に残ることがある (`scripts/release/appstore-archive.sh` は分離済みの
`-derivedDataPath` を使う。手動ビルドは上のコマンドのように
`-derivedDataPath /tmp/kilde-mas` を付ける)。

サンドボックス下での実録画を確かめるときは、セルフテストの保存先を
**`~/Movies` 配下**にします。サンドボックスでは tmp やホーム直下には書けず、
書けるのはアプリコンテナ・`~/Movies` (entitlement)・NSOpenPanel で選んだ場所だけです:

**署名の選び方** — 2 つのコマンドは同じではありません。`kilde-dev` 証明書がある環境では
そちらを使ってください。ad-hoc 署名は TCC がビルドのたびにアプリを別物と見なすため、
画面収録・マイクの許可を再起動のたびに付け直すことになります (cubic レビュー指摘。
§3 の kilde-dev 作成手順を参照):

```sh
# (A) kilde-dev 証明書がある環境 — project.yml の既定のまま署名する。TCC が安定する
xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI-AppStore -configuration Debug build \
  -derivedDataPath /tmp/kilde-mas

# (B) 証明書が無い環境 — ad-hoc + Hardened Runtime オフでローカル起動だけ可能にする
#     (App Sandbox 自体は entitlement なので ad-hoc でも有効。TCC の許可は毎回付け直し)
xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI-AppStore -configuration Debug build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO \
  -derivedDataPath /tmp/kilde-mas

mkdir -p ~/Movies/kilde-selftest
KILDE_GUI_SELFTEST_RECORD=3 KILDE_GUI_SELFTEST_AUDIO=none \
  KILDE_GUI_SELFTEST_OUTPUT="$HOME/Movies/kilde-selftest" \
  /tmp/kilde-mas/Build/Products/Debug/KildeGUI.app/Contents/MacOS/KildeGUI
# → selftest: finished /Users/<you>/Movies/kilde-selftest/kilde-… (exit 0)。
#   拡張子は設定に従う (format=mov や ProRes 退避なら .mov)。**finished に表示された
#   パスをそのまま使う** — kilde-*.mp4 の glob だと .mov を取りこぼす
```

**保存先が «ユーザーから見えるパス» になっていることを確かめる** — サンドボックス下の
`FileManager.urls(for: .moviesDirectory, …)` はコンテナ内の Movies を返すため、そのまま
使うと録画がユーザーからアクセスできない場所に落ちます (App Store 審査 Guideline
2.4.5(i) でのリジェクト理由。CLAUDE.md §5.17)。既定の保存先は **まっさらなコンテナ**
でしか確かめられない (config と bookmark が残っていると前回の選択が復元される) 一方、
シェルから他アプリのコンテナは TCC で触れません。**バンドル ID を変えたビルド**で
新しいコンテナを作って確認します:

```sh
set -o pipefail   # grep の 0 で «セルフテストが落ちた» を見逃さない (cubic レビュー指摘)
# **バンドル ID は実行のたびに変える。** 同じ ID で再実行すると前回のコンテナに残った
# config と bookmark が復元され、«新しいコンテナの既定値» を確かめられない
# (シェルからは他アプリのコンテナを TCC で消せないので、消すより変えるほうが確実)
SBID="com.takezou621.KildeGUI.sbcheck$(date +%H%M%S)"
xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI-AppStore -configuration Debug build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  PRODUCT_BUNDLE_IDENTIFIER="$SBID" \
  -derivedDataPath /tmp/kilde-mas-sbcheck
KILDE_GUI_SELFTEST_NOTIFY=1 \
  /tmp/kilde-mas-sbcheck/Build/Products/Debug/KildeGUI.app/Contents/MacOS/KildeGUI \
  | grep -E "outputDirectory|revealFallback"
# → selftest: outputDirectory=/Users/<you>/Movies
#   selftest: revealFallback=/Users/<you>/Movies select=false
#   どちらかが /Users/<you>/Library/Containers/… を指したら **失敗** (リジェクトの再発)
```

検証のたびに空のコンテナが増えます (`…KildeGUI.sbcheck<時刻>`)。**シェルからは TCC で
消せない**ので、「システム設定 > 一般 > ストレージ > アプリケーション」から、または
Finder で `~/Library/Containers/` を開いて削除してください。残っていても実害はありません。

確認ポイント:

- **設定の退避**: `~/Library/Containers/com.takezou621.KildeGUI/Data/Library/
  Application Support/kilde/` が作られ、`~/.kilde/` は MAS 版の実行では
  書き換わらないこと (SandboxSupport が `ConfigStore.directory` をコンテナへ退避)
- `KILDE_GUI_SELFTEST_UPDATE=1` は **MAS ビルドでは使えません** (Sparkle ごと
  除外しているため)。更新まわりの検証は通常の KildeGUI スキームで行う
- ad-hoc 署名のままだと TCC 権限のトグルが再起動のたびに外れることがある
  (§3 の kilde-dev の注意と同じ)。審査相当の確認は
  `scripts/release/appstore-archive.sh` が Apple Distribution で自動署名する

## 4. エンジンと CLI の開発

`KildeCore` (録画エンジン) と `kilde` (CLI) の開発は
**[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)**
で行います。`swift build` / `swift test`、実録画の統合テスト
(`scripts/integration-test.sh`、T1〜T25)、A/V ドリフト計測 (`scripts/drift-test.sh`)、
CLI 固有のトラブルシュートは、すべて同リポジトリのドキュメントが正本です。

本リポジトリとの境界は次の 2 点です:

- **GUI は kilde-cli-swift を revision 固定で参照する** (`gui/project.yml` の pin)。
  pin を更新するときはリリース workflow (`release.yml`) の `ref:` と同じ PR で揃える
- **リリースと配布は本リポジトリが担う** (`release.yml` + `scripts/release/sign.sh` +
  Homebrew formula)。手順は [RELEASE.md](RELEASE.md)

## 5. ブランチと PR

- **AI エージェント向けの運用ルール (issue 起点の作業、ブランチ命名、PR とレビュー対応) は
  リポジトリ直下の [AGENTS.md](../AGENTS.md) にある。**
- 作業ブランチ: issue ごとに `origin/main` から `feature/<issue番号>-<slug>` を切る
- リモート: https://github.com/kilde-team/kilde
- コミットメッセージは英語。既存履歴のスタイル (命令形の要約行) に合わせる
- ドキュメントとコードコメントは日本語。特に macOS 26 固有の回避策は
  **「なぜそう書いたか」**をコメントに残す (後から消されると再発するため)
- `.claude/` は `.gitignore` 済み。`CLAUDE.md` はコミット対象
