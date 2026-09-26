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

### TCC はバンドル ID ごとに 1 レコード — 署名系統を混ぜると権限が壊れる

さらに重要な仕組みとして、TCC は `(権限の種別, バンドル ID)` の組につき
**1 つのレコード**しか持たず、そのレコードに記録した designated requirement (DR)
で、起動してきたアプリの署名を検証します。DR が一致しないビルドが起動すると
「未許可」扱いで許可ダイアログが出ます (**システム設定では許可済みと表示されていても**)。

同一バンドル ID `com.takezou621.KildeGUI` でも、署名系統 (DR) が違えば互換がありません:

| 署名 | DR の内容 | 安定性 |
|------|----------|-------|
| Developer ID (リリース 0.6.0+) | team `4B873Q67MK` 固定 | 安定 |
| kilde-dev 自己署名証明書 (ローカル Debug) | 証明書のハッシュ固定 | 安定 (証明書を作り直すと変わる) |
| ad-hoc (`CODE_SIGNING_ALLOWED=NO` 等の検証ビルド) | cdhash 固定 | **ビルドのたびに変わる** |

別の系統を起動して許可するたびにレコードの DR が上書きされ、残りの系統がすべて
「未許可」に戻ります。これが「設定では許可済みなのに毎回ダイアログが出る」の正体です
(issue #217 実測)。

対策として **Debug 構成のバンドル ID は `com.takezou621.KildeGUI.dev` に分離して
あります** (`gui/project.yml` の `settings.configs.Debug`)。開発ビルドは TCC の
レコードを Release と別に持ち、互いの権限を壊しません。通知権限・ログイン項目・
UserDefaults (Sparkle の `SU*` キーを含む) も `.dev` ドメインに分かれます。
システム設定では同名の「KildeGUI」が 2 つ並ぶので、どちらが開発用かは
Xcode から起動したときに出るダイアログから許可すれば間違いありません。

計測も本番から切り離してあります。**Debug 構成は Firebase を初期化しない**ため
(issue #219)、Analytics の利用統計も Crashlytics のクラッシュレポートも本番の
Firebase プロジェクトへ送られません。`GoogleService-Info.plist` は本番アプリを
指したままです (Debug 用の Firebase アプリは登録していない — plist を 2 種類
管理しない選択)。«Debug なのに計測が飛ばない» は仕様で、開発時のクラッシュは
Xcode か Console.app のクラッシュレポートで確認してください。

過去に権限の取り合いで壊れたレコードは、対象バンドル ID を指定してリセットします
(ターミナルから実行可能。Full Disk Access は不要):

```sh
# 開発ビルドのレコードを消す
tccutil reset ScreenCapture com.takezou621.KildeGUI.dev
# リリース版のレコードを消す (ダイアログ → 許可 → アプリの再起動で復旧)
tccutil reset ScreenCapture com.takezou621.KildeGUI
```

リセット後にどのコピーを起動するかが重要です。そのバンドル ID で**最初に起動して
許可した署名系統**がレコードを獲得します。リリース版 (`~/Applications/KildeGUI.app` など)
の権限を作り直すときは、必ずリリース版を起動してから許可してください。

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

`KILDE_GUI_SELFTEST_TRANSCRIBE=1` は録画せず、**録画後の文字起こしの経路**を確かめて
終わります (issue #146)。`KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT` で渡した音声を
«録画の完了物» として GUI 本体と同じ経路 (RecordingSetup の文字起こし設定 →
TranscriptionCoordinator → enqueue → 必要なら言語モデル取得 → 文字起こし →
サイドカー書き出し) に流し、サイドカーが録画ファイルの隣に書かれることを検証します:

```sh
# 入力音声はリポジトリにコミットしないため自作する (Kyoko=日本語 / Samantha=英語)
say -v Kyoko -o /tmp/kilde-transcribe-test.aiff "本日の議事録のテストです"
afconvert -f m4af -d aac /tmp/kilde-transcribe-test.aiff /tmp/kilde-transcribe-test.m4a
KILDE_GUI_SELFTEST_TRANSCRIBE=1 KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT=/tmp/kilde-transcribe-test.m4a \
  "$APP/Contents/MacOS/KildeGUI"
# → selftest: transcribe input=kilde-transcribe-test.m4a format=markdown locale=(端末の言語設定)
#   selftest: expect sidecar=/tmp/kilde-transcribe-test.md
#   selftest: transcribed segments->kilde-transcribe-test.md bytes=… (exit 0)
```

**このセルフテストで「通った」にできないもの**: «録画完了 → 自動で文字起こしが
積まれる» の配線 (実録画が要るため — 後述の `RECORD_TRANSCRIBE=1` で確かめられる) と、
オフラインでのモデル取得失敗と再試行 (ネットワークの再現が要るため)。後者は
録画機能への影響がないことを構造 (録画完了の購読と TranscriptionCoordinator の
切り離し) で担保しています。«中止» の経路は `TRANSCRIBE_CANCEL=1` (後述) で
確かめられます。進捗は 10 秒ごとに
`selftest: waiting phase=…` として出ます — 初回実行は言語モデルの取得に
数分かかることがあります。

`KILDE_GUI_SELFTEST_TRANSCRIBE_CANCEL=1` は録画せず、**«中止» の経路**を確かめて
終わります (issue #146 の受け入れ条件 «キャンセルで出力ファイルが残らず、録画ファイルは
残る» の回帰)。`TRANSCRIBE_INPUT` で渡した音声を enqueue して**直後に cancelAll** し、
(1) running が空に戻る、(2) 完了・失敗の表示が立たない (キャンセルは失敗に数えない設計)、
(3) サイドカーが残らない、の 3 点を見ます。**«直後» にするのは最悪ケースのため** —
エンジンの SpeechAnalyzer 初期化はキャンセル通知窓の外で走るため、この窓での中止は
Task が hung しうる (実測) で、このテストは hung を 5 秒で打ち切る観測タイムアウトの
復帰経路も通します。入力は cancelAll 前に完了する競合を避けるため長め (目安 30 秒) を
渡してください:

```sh
# 長めの入力 (目安 30 秒)。短いと cancelAll 前に文字起こしが完了してしまう
say -v Kyoko -o /tmp/kilde-cancel-test.aiff "文字起こしの中止テストです。(以下 30 秒分の読み上げ)"
afconvert -f m4af -d aac /tmp/kilde-cancel-test.aiff /tmp/kilde-cancel-test.m4a
KILDE_GUI_SELFTEST_TRANSCRIBE_CANCEL=1 KILDE_GUI_SELFTEST_TRANSCRIBE_INPUT=/tmp/kilde-cancel-test.m4a \
  "$APP/Contents/MacOS/KildeGUI"
# → selftest: cancelled cleanly (no completion, no failure, no sidecar) (exit 0)
```

`KILDE_GUI_SELFTEST_TRANSCRIBE_RETRY=1` は録画・文字起こしともに実行せず、**«断続的な
文字起こしの失敗を自動で 1 回だけやり直す» 判定規則**を合成エラーで確かめて終わります
(issue #221)。失敗の -12203 (SDK ヘッダにも文書にも無い未文書のコード) は断続的で
外から再現できないため、再現を待つのではなく «どのエラーを再試行の対象にするか»
(`TranscriptionCoordinator.isTransientRetryable`) を機械的に縛ります:

```sh
KILDE_GUI_SELFTEST_TRANSCRIBE_RETRY=1 "$APP/Contents/MacOS/KildeGUI"
# → selftest: retry-rule[ok] 観測された -12203 (直接) は再試行する → true
#   selftest: retry-rule failures=0 (exit 0)
```

**このセルフテストで「通った」にできないもの**: -12203 が実際に起きたときの自動再試行
(断続的で誘発できないため)。実運用での発見は失敗表示の診断情報と統合ログ
(`log show --predicate 'category == "transcription"'`) と計測イベント
(`transcription_retry`) によります。

録画セルフテストに `KILDE_GUI_SELFTEST_RECORD_TRANSCRIBE=1` を付けると、**実録画の
完了から «AppDelegate が文字起こしを自動で積む» 配線、文字起こし、サイドカー書き出し
までを 1 回で確かめて終わります** (TRANSCRIBE 単体では確かめられない «録画完了 →
自動 enqueue» の経路)。録画中に音を載せるには、別ターミナルから `say -v Kyoko "…"` を
鳴らします (システム音声として録れます)。実行手順とスリープ・音声デバイスの注意は
録画セルフテストと同じ (このセクションの上と「検証時の環境の注意」) です:

```sh
# 録画 12 秒の間に、別ターミナルで say -v Kyoko "…読み上げ…" を鳴らす
KILDE_GUI_SELFTEST_RECORD=12 KILDE_GUI_SELFTEST_RECORD_TRANSCRIBE=1 \
  KILDE_GUI_SELFTEST_OUTPUT=/tmp \
  "$APP/Contents/MacOS/KildeGUI"
# → selftest: finished /tmp/kilde-….mp4 bytes=…
#   selftest: waiting for transcription of kilde-….mp4
#   selftest: transcribed segments->kilde-….md bytes=… (exit 0)
```

`KILDE_GUI_SELFTEST_TRANSCRIBE=<秒>` (2 以上) は、上の «録画なし版» と違い
**実録画を伴う完全経路**を確かめます (issue #150)。録画 → 停止 →
«録画完了 → 自動文字起こしが積まれる» の配線 → サイドカーへの書き出し →
«喋った内容のキーワードがサイドカーに乗る» までを 1 回の実行で通します。
テスト音声は `say` (Kyoko) でその場で作り、録画中に `afplay` で再生します —
実在の会議音声や第三者の音声は使いません。**実録画を伴うので、録画セルフテスト
(`KILDE_GUI_SELFTEST_RECORD`) や kilde-cli-swift 側の統合テストと同時に実行しないでください。**

```sh
# 1) 既定出力を BlackHole 2ch に向ける (スピーカーを介さずに録画へ信号を入れる。
#    戻すための元の名前を先に控える。brew install blackhole-2ch switchaudio-osx)
SwitchAudioSource -t output -c                # → 元のデバイス名 (メモしておく)
SwitchAudioSource -t output -n "BlackHole 2ch"
# 2) ディスプレイを起こして消灯を防ぐ (消灯中は SCK がフレームを出さない — 下の注意参照)
caffeinate -u -t 1; caffeinate -dims -w $$ &
# 3) 実行 (秒数はテスト音声の長さ + 余裕。say の 1 文なら 12 で十分)
KILDE_GUI_SELFTEST_TRANSCRIBE=12 KILDE_GUI_SELFTEST_OUTPUT=/tmp \
  KILDE_GUI_SELFTEST_AUDIO="device:BlackHole 2ch" \
  "$APP/Contents/MacOS/KildeGUI"
# → selftest: transcribeEnabled forced=true (config は変更しません)
#   selftest: playing kilde-selftest-speech-….aiff during recording
#   selftest: finished /tmp/kilde-yyyyMMdd-HHmmss.mp4 bytes=… — waiting for transcription…
#   selftest: transcription enqueued after recording finished (kilde-….mp4)
#   selftest: waiting phase=transcribing(…) …
#   selftest: transcribed sidecar=kilde-yyyyMMdd-HHmmss.md bytes=… keywords=… (exit 0)
# 4) 既定出力を元に戻し、caffeinate を止める (シェルを開いたままにするなら忘れずに)
SwitchAudioSource -t output -n "<手順 1 で控えた元のデバイス名>"
kill %1
```

キーワード照合は«喋った語が 1 語でも乗れば成功»の条件です。読み上げテキストと
キーワードは**日本語固定**です。セルフテストは認識言語をメモリ上で ja-JP に強制する
(`transcriptLocale forced=ja-JP` と出る。config は書き換えない) ので、端末の
«言語» 設定はそのままで構いません。`KILDE_GUI_SELFTEST_SPEECH_VOICE` は
«日本語テキストを読める音声» への代替指定です (Kyoko が無い環境で別の ja 音声に
変える。Samantha のような英語音声を指定してもテキストは日本語のままなので、
検証は成功しません)。

`KILDE_GUI_SELFTEST_POPOVER=close` を重ねると、**パネルを閉じた状態でも**
録画も文字起こしも完了することを検証します (issue #150 の受け入れ条件 —
TranscriptionCoordinator は AppDelegate 持ちでパネルに寿命がない):

```sh
KILDE_GUI_SELFTEST_TRANSCRIBE=12 KILDE_GUI_SELFTEST_OUTPUT=/tmp \
  KILDE_GUI_SELFTEST_AUDIO="device:BlackHole 2ch" KILDE_GUI_SELFTEST_POPOVER=close \
  "$APP/Contents/MacOS/KildeGUI"
# → selftest: popover shown=true / popover closed shown=false elapsed=…s /
#   transcribed … keywords=… popoverShown=false (exit 0)
```

**このセルフテストで「通った」にできないもの**: SpeechTranscriber の認識 «品質»
(«1 語でも一致» を成功条件にしているため、誤認識の率までは見ない) と、オフラインでの
モデル取得失敗と再試行 (録画なし版と同じ)。認識の確からしさは実機の目視確認に頼ります。

### 会議の自動録画の検知を確かめる (issue #197)

`KILDE_GUI_SELFTEST_MEETING=1` は録画せず、**会議の検知規則**を合成データで検証し、
続けて実機の観測 (マイクを使っているプロセスと、今検知される会議) を出して終わります。
合成データの全ケースが通れば終了コード 0、外れがあれば 1 (実機の観測は合否に含めません):

```sh
KILDE_GUI_SELFTEST_MEETING=1 "$APP/Contents/MacOS/KildeGUI"
# → selftest: meeting rule [PASS] Zoom: 会議ウィンドウを選ぶ (メインウィンドウは選ばない) expected=20 got=20
#   …
#   selftest: meeting supported=true
#   selftest: meeting audio us.zoom.xos pid=… input=true output=true   (会議中なら)
#   selftest: meeting detected app=Zoom window=… title=Zoom ミーティング exists=true
#   selftest: meeting failures=0 (exit 0)
```

会議に参加した状態で実行すると «その会議が検知されるか» をそのまま確かめられます。
`detected=none` のときは、`meeting audio` の行に会議アプリ (またはそのヘルパー) が
`input=true` で出ているかを見てください。出ていなければマイク側、出ていれば
ウィンドウのタイトル側 (画面収録の権限が無いと CGWindowList のタイトルが空になる) の問題です。

実際の自動録画 (検知 → 開始 → ウィンドウを閉じて停止 → ファイナライズ) は、
パネルの「会議の自動録画」を有効にして会議に参加し、退出して確かめます
(セルフテストの起動では監視を始めません — 検証中に実際の会議で録画が始まらないように)。

### 録画ライブラリの検索を確かめる (issue #165)

`KILDE_GUI_SELFTEST_LIBRARY_SEARCH=1` は録画せず、**録画ライブラリの索引構築と
全文検索**を一時ディレクトリに合成した文字起こしサイドカー 100 件
(md 80 / json 8 / srt 4 / vtt 4 / txt 4) で検証し、実測時間を出して終わります。
**実録画を伴わない**ため、録画のスロット (権限・スピーカー) を占有しません
(並行する録画テストと同時に回せます)。合成データの全ケースが通れば終了コード 0:

```sh
KILDE_GUI_SELFTEST_LIBRARY_SEARCH=1 "$APP/Contents/MacOS/KildeGUI"
# → selftest: library entries=100 build=0.084s search=0.002s
#   selftest: library OK: 索引構築が 1 秒以内 (0.084s)
#   selftest: library OK: «予算» が 20 件ヒット (実際 20 件)
#   …
#   selftest: library failures=0 (exit 0)
```

検証しているのは、録画 100 件の走査と既定名からの日時解析、5 形式のパース、
日本語 (2-gram 索引)・英語 (大文字小文字の同一視)・1 文字クエリの検索、
ヒット位置 (entry / セグメント / 開始時刻) の正しさです。
«ヒットしたセグメントから該当時刻へ再生» は実機で確認します:
パネルの「ライブラリ」からウィンドウを開き、録画を選んで文字起こしの行をクリックし、
**クリックした時刻から再生が始まること**を確かめてください。

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
> intents framework" が出ることがあります。これは App Shortcuts (AppIntents,
> issue #167) の登録まわりのシステムサービス接続のノイズで、ショートカットの
> 実行自体には影響しません (正式な Developer ID 署名では出なくなる見込みです)。

> **Sparkle (GUI 自動更新、issue #122)**: Debug ビルドは
> `SUEnableAutomaticChecks=false` を UserDefaults に書き込みます —
> 開発機が実フィード (`releases/latest/download/appcast.xml`) を定期的に見に
> いかないようにするため (SU* キーは UserDefaults が Info.plist より優先される。
> キー名は Sparkle 2 の `SUEnableAutomaticChecks` — Sparkle 1 の
> `SUAutomaticallyChecksForUpdates` は効かない)。
> **issue #217 以前の Debug ビルド (バンドル ID 分離前) はこの本番ドメインに
> 書いていた**ため、Release ドメインに残った値は Release ビルドにも効きます。
> 開発が終わったら開発機を
> 出荷時状態に戻す後始末として削除します。なお**手動の更新チェック**
> (ポップオーバーの「アップデートを確認」) はこの値に関係なく動く —
> 削除し忘れても手動チェックの成否には影響せず、影響するのは自動チェックだけ:
>
> ```sh
> defaults delete com.takezou621.KildeGUI SUEnableAutomaticChecks
> ```
>
> なお Debug ビルドの UserDefaults は issue #217 以降、バンドル ID 分離により
> **`com.takezou621.KildeGUI.dev` ドメイン**に書かれます (`gui/project.yml` の
> `settings.configs.Debug`)。上の削除コマンドは Release ビルドと同じドメイン
> (`com.takezou621.KildeGUI`) に残った値の後始末用です。Debug ビルド側の
> 値を見る・消すときは `.dev` を付けたドメインを使ってください:
>
> ```sh
> defaults delete com.takezou621.KildeGUI.dev SUEnableAutomaticChecks
> ```
>
> ダウンロード〜再起動までの E2E をリリース前に確認したいときは、フィードを
> ローカルに差し替えられます (同じく UserDefaults が優先されるのを利用)。ただし
> この E2E は**リリース版 (Developer ID 署名) のコピーで行う**ものなので、
> ドメインは本番のままです:
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
# 判定は **サブシェル** で行う — NG でも手元の対話シェルが落ちない。終了コードで
# CI にも埋め込める
(
  set -o pipefail
  out="$(KILDE_GUI_SELFTEST_NOTIFY=1 \
    /tmp/kilde-mas-sbcheck/Build/Products/Debug/KildeGUI.app/Contents/MacOS/KildeGUI)" || exit 1
  # 期待する 2 行が **絶対パスの値つきで出ていること** を必須にする。行の存在だけを
  # 見ると、出力が空のときも、値が空や相対パスのときも「NG が無いから OK」に
  # なってしまうため (cubic レビュー指摘)
  echo "$out" | grep -E "^selftest: outputDirectory=/[^[:space:]]" || exit 1
  echo "$out" | grep -E "^selftest: revealFallback=/[^[:space:]]" || exit 1
  # **値まで見る。** grep はキー名が出れば 0 を返すので、パスがコンテナを指していても
  # 「成功」に見えてしまう (CodeRabbit レビュー指摘)
  if echo "$out" | grep -qE "^selftest: (outputDirectory|revealFallback)=.*/Library/Containers/"; then
      echo "NG: 保存先がコンテナを指している (2.4.5(i) リジェクトの再発)" >&2
      exit 1
  fi
  echo "OK: 保存先はユーザーから見えるパス"
)
# `echo` の 0 で上書きしないよう、**終了コードを取ってから**表示して返す (cubic レビュー指摘)
status=$?; echo "検証の終了コード: $status"; test "$status" -eq 0
# → selftest: outputDirectory=/Users/<you>/Movies
#   selftest: revealFallback=/Users/<you>/Movies select=false
#   OK: 保存先はユーザーから見えるパス
#   検証の終了コード: 0
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

### UI 文字列のローカライズ (issue #137)

GUI は **文字列カタログ** `gui/Resources/Localizable.xcstrings` で
ja / en / zh-Hans / ko / es を扱う。ソース言語は ja で、**コード中の日本語の
リテラルがそのままキー兼 ja の値になる** (ja のエントリはカタログに書かない)。

- SwiftUI の `Text` / `Label` / `Button` / `.help` などに渡す**リテラルは
  `LocalizedStringKey` として自動的にカタログを引く** — コードの変更は不要
- `String` として扱われる場所 (`UNNotificationContent.title`、
  `NSStatusItem` の toolTip、`setup.notice` など) は
  **`String(localized: "…")` で明示的に包む**。包み忘れるとその文字列だけ
  どの言語でも ja のまま出る
- 補間 (`\(error)` など) を含むキーの書式指定子は Int なら `%lld`、
  それ以外は `%@`。**全言語で指定子の種類と順序を一致させる**こと —
  食い違うと実行時にフォーマットが壊れる
- キーを足したらカタログの 4 言語すべてに翻訳を足す。Xcode のカタログ
  エディタで編集するのが安全 (JSON 直編集はエスケープに注意)。
  キーは `extractionState: "manual"` でも**新規キーはビルド時に自動で
  追加される** ("manual" が抑えるのは既存キーの自動更新・自動削除) —
  ビルド後にカタログへ新規キーが入っていないか確認し、翻訳を足す。
  一方ソースの日本語リテラルを**変えたら**キー自体が変わり、
  4 言語の翻訳を手で移し替える (古いキーは自動では消えないので手で削除。
  放置すると使われないキーが残る)
- 開発者向けの文字列 (セルフテストの `fail()` メッセージ、stderr の
  WARNING、エンジン由来のエラー本文) は**ローカライズ対象外**
- 対応言語の一覧は `Info.plist` の `CFBundleLocalizations` と揃える。
  新言語を足すときは lproj の生成を確認する (ビルド後に
  `KildeGUI.app/Contents/Resources/<lang>.lproj/Localizable.strings` があること)

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
