# 開発ハンドブック

kilde をローカルでビルド・実行・検証するための手順書。
設計の背景は [DESIGN.md](DESIGN.md)、macOS 26 での実測結果は
[SPIKE-NOTES.md](SPIKE-NOTES.md)、AI エージェント向けの要約は
リポジトリ直下の [CLAUDE.md](../CLAUDE.md) にあります。

## 1. 前提環境

| 項目 | 要件 |
|------|------|
| OS | macOS 14+ (宣言)。**実検証済みは macOS 26.6.2 / Apple Silicon のみ** |
| ツールチェーン | `swift-tools-version:5.10`。検証時は Swift 6.3.3 / Xcode 26.5 SDK。Xcode Command Line Tools で可 |
| 依存 | [swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.5.0+ (SPM が自動取得) |
| 任意 | BlackHole — `brew install --cask blackhole-2ch` (`--audio device:` / `rec --monitor` / `audio monitor` を使う場合のみ) |

ネットワークは初回の `swift build` でのみ必要 (依存の取得)。

## 2. 権限 (TCC) のセットアップ

kilde は macOS のプライバシー権限を 2 種類使います。**どちらも「実行したバイナリ」
単位ではなく「起動元のプロセス」単位で記録される**ため、ターミナル.app や
iTerm など、実行に使うアプリに対して許可を与えることになります。

| 権限 | いつ必要か | 与え方 |
|------|-----------|-------|
| 画面収録 (画面とオーディオを収録) | 映像を録るとき、および `--audio system` のとき | システム設定 → プライバシーとセキュリティ → 画面とオーディオを収録 |
| マイク | `--audio mic` / `--audio device:...` のとき | システム設定 → プライバシーとセキュリティ → マイク |

手順:

```sh
swift build
.build/debug/kilde doctor
```

`doctor` は状態を表示し、未付与なら要求ダイアログ (またはシステム設定) を開きます。
**画面収録は許可した後にプロセスの再起動が必要**です — 許可してからもう一度
`kilde doctor` を実行し、`[screen] 画面収録権限: あり` になることを確認してください。

マイク権限が「拒否済み」になるとダイアログは二度と出ません。システム設定から
手動で有効化します。

> 補足: マイクの用途説明 (`NSMicrophoneUsageDescription`) はリンカで実行ファイルに
> 埋め込んだ `Sources/kilde/Info.plist` から解決されます (CLAUDE.md §5-7)。
> `Package.swift` の `linkerSettings` を触るときはここが壊れないか確認してください。

## 3. ビルドと実行

```sh
swift build                      # デバッグビルド → .build/debug/kilde
swift build -c release           # リリースビルド → .build/release/kilde

.build/debug/kilde --help
.build/debug/kilde rec --help
```

公式配布物の Developer ID 署名、notarization、zip / DMG 作成は
[RELEASE.md](RELEASE.md) と `scripts/release/sign.sh` を参照してください。

PATH に置いて `kilde` として使う場合:

```sh
ln -sf "$PWD/.build/debug/kilde" /usr/local/bin/kilde
```

> 注意: シンボリックリンク経由で起動しても TCC の記録は「起動元アプリ」に紐づくため、
> 別のターミナルアプリから使うと権限を再度求められます。

### よく使う実行例

```sh
kilde rec demo.mov                                  # 画面 + システム音声
kilde rec --preset meeting 会議.mov                  # 会議 (ウィンドウ選択 + system + mic ミックス)
kilde rec --audio system --audio mic out.mov        # 明示指定
kilde rec --no-video memo.m4a                       # 録音のみ
kilde rec --no-video --window zoom 会議.m4a          # 特定アプリの音声のみ
kilde rec --duration 30s --codec hevc out.mov       # 30 秒で自動停止
kilde devices                                       # 収録対象の ID を調べる
kilde inspect out.mov                               # 出来上がりの検証
kilde config set outputDirectory ~/Movies/kilde     # 既定の保存先 (~/.kilde/config.json)
kilde config show                                   # 設定値と既定値の一覧
```

設定ファイルの値は `kilde rec` の既定値になり、CLI 引数が常に優先されます
(キーと優先順位は DESIGN.md §6「設定ファイル」)。開発中に実環境の設定と monitor state を
分離したいときは `KILDE_CONFIG_DIR` に一時ディレクトリを指定してください。

`--window` は windowID の完全一致 / ウィンドウタイトル / bundleID の部分一致で解決し、
複数ヒットしたら**面積が最大のもの**を選びます。曖昧なときは `kilde devices` で
windowID を確認して数値で指定するのが確実です。

### 終了コード

| コード | 意味 |
|-------|------|
| 0 | 成功 (Ctrl+C / SIGTERM / SIGHUP / `--duration` による停止を含む) |
| 1 | その他の失敗 (ファイナライズ失敗、monitor の復元失敗、meeting の選択中止など) |
| 2 | 権限不足 (画面収録 / マイク) |
| 3 | デバイス・ウィンドウ・ディスプレイが見つからない |
| 64 | オプションの検証エラー (ArgumentParser が返す。`KilError` は経由しない) |

Ctrl+C は正規の停止操作なので、ファイナライズに成功すれば exit 0 です
(DESIGN.md §6 v0.4。統合テスト T10 が保証)。

### GUI (メニューバーアプリ、M3 開発中)

`gui/` にメニューバーアプリがあります (NSStatusItem + NSPopover、中身は SwiftUI —
macOS 26 で `MenuBarExtra` の `.window` パネルが開かないため AppKit で管理)。
`.xcodeproj` はコミットして
いないため、[XcodeGen](https://github.com/yonaskolb/XcodeGen) で生成してから
Xcode でビルドします (録画エンジンは CLI と同じ KildeCore をローカルパッケージ
依存で共有):

```sh
brew install xcodegen   # 初回のみ
cd gui && xcodegen      # project.yml から KildeGUI.xcodeproj を生成
open KildeGUI.xcodeproj # Xcode で KildeGUI スキームを Run
```

コマンドラインだけで検証する場合:

```sh
cd gui && xcodegen
xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI -configuration Debug build
```

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

`project.yml` を変更したら `xcodegen` を再実行してください (再生成し忘れによる乖離を
防ぐため、変更は必ず project.yml 側に行う)。

**GUI 経由の録画をコマンドラインで確かめる (セルフテスト)**: 環境変数を付けて実行ファイルを
直接起動すると、UI を操作せずに GUI と同じ経路 (`RecordingSetup` → `RecordRequest` →
`RecordingController` → `Recorder`) でディスプレイ 0 + システム音声を録画して終了します。
ターミナルから直接起動した場合、画面収録の権限はターミナルのものが使われます:

```sh
APP=$(xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI -configuration Debug \
      -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/KildeGUI.app
KILDE_GUI_SELFTEST_RECORD=3 KILDE_GUI_SELFTEST_OUTPUT=/tmp "$APP/Contents/MacOS/KildeGUI"
# → selftest: finished /tmp/kilde-yyyyMMdd-HHmmss.mov (終了コード 0)
../.build/debug/kilde inspect /tmp/kilde-*.mov   # CLI の録画と同じトラック構成か確認
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

> **検証時の環境の注意**: 画面がロックされている、または**ディスプレイが消灯している**間は
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

## 4. 統合テスト

`scripts/integration-test.sh` は CLI を実際に動かして録画し、出力ファイルの
トラック構成と RMS を機械検証します。

```sh
scripts/integration-test.sh
```

**前提条件 (満たさないと失敗します):**

- 画面収録・マイクの権限が付与済み (先に `kilde doctor`)
- **スピーカー音量が 0 / ミュートでない** — 音声シナリオが無音判定になります
- **ロック画面は解除しておく** — スクリプトは `caffeinate -u` + `-dims` で自動消灯を
  起こして防ぎますが、ロックされた画面は人手で解除する必要があります。
  消灯・ロック中は SCK がディスプレイを列挙せず (doctor で `[sck] displays=0`)、
  録画シナリオがすべて失敗します
- 所要 ~2 分。実行中は画面とスピーカーが占有されます
- テスト中に一時的に既定の出力デバイスが `kilde Monitor` に切り替わります
  (T9)。スクリプトは `trap` で必ず復元しますが、強制終了した場合は
  `kilde audio monitor teardown` を手動で実行してください
- 設定ファイルと monitor state は `KILDE_CONFIG_DIR` で作業ディレクトリ内に分離するため、
  ユーザーの `~/.kilde` には触れません

**テスト項目:**

| # | 内容 |
|---|------|
| T1 | `doctor` — 権限・環境診断 |
| T2 | `devices` — ディスプレイ / ウィンドウ / オーディオ列挙 |
| T3 | `rec` 既定 — 画面 + システム音声 |
| T4 | `rec --audio system --audio mic --audio-tracks separate` — トラック分離 |
| T4b | `rec --audio system --audio mic` — mixed (既定) |
| T5 | `rec --no-video` — SCK 音声のみ |
| T6 | `rec --window` — 収録対象ウィンドウの音は入る |
| T7 | `rec --window` — 他アプリの音は入らない (陰性確認)。無関係なウィンドウが見つからないと SKIP |
| T8 | `rec --no-video --window` — 特定アプリの音声のみ |
| T9 | `audio monitor` + `--audio device:BlackHole...` — BlackHole 未導入なら SKIP |
| T10 | SIGINT — Ctrl+C 相当で exit 0・再生可能なファイルが残る |
| T11 | GUI — KildeGUI のビルド・起動・正常終了 (xcodegen 未導入 / kilde-dev 証明書なし / KildeGUI 起動中は SKIP。メニューバー表示は目視確認) |
| T12 | 設定ファイル — `outputDirectory` が既定の保存先になる / 存在しない保存先は録画前に exit 1 |
| T13 | `rec --hotkey` — 待機中の SIGINT は録画を始めず exit 0・出力ファイルなし (ホットキーの押下自体は目視確認) |
| T14 | `rec --region` — 指定した矩形の解像度で録れる / 奇数は偶数へ切り捨て / 範囲外は録画前に exit 1 / 形式不正は exit 64 |
| T15 | `rec` 一時停止 / 再開 — SIGUSR1 で挟んだ区間が映像・音声のどちらの長さにも含まれず、A/V の差が 1 秒未満 (`p` キーは端末が要るので目視確認) |
| T16 | `rec --format mp4` — ISO Media コンテナで録れる / 出力パスの拡張子から自動判定 / 既定は MOV のまま / ProRes・`--no-video`・不正値との組合せは録画前に exit 64 (設定ファイル由来の codec は exit 1) |
| T17 | `rec --exclude-app` — 除外したアプリの音が出力に入らない / `--window` 複数指定でディスプレイ全体の大きさで録れ、音声スコープも効く (含めたアプリの音は入り、含めなかったアプリの音は入らない) / 実行中でない bundleID は exit 3 / 併用不可の組合せは録画前に exit 64 |
| T18 | 既定出力名の原子的予約 — 同名の 0 バイトがあれば `-2` に退避して元を保護 |
| T18b | 同秒の 2 本同時起動で互いのファイルを消さない (共存を検証。固まる場合は #70 をタイムアウトで回収) |
| T19 | `rec --codec prores` — ProRes (BGRA 経路) で録れる |
| T19b | `rec --codec hevc` — HEVC (420v 経路) で録れる。`SCStreamConfiguration` は単体テストから触れないため、両経路をここで通す |
| T21 | GUI 通知・最近の録画・ホットキー (issue #20) — `KILDE_GUI_SELFTEST_NOTIFY=1` で UI を操作せずに検証する。最近の録画の走査 (上限 5 件・更新時刻の新しい順・接頭辞/拡張子/ディレクトリ/隠しファイルの除外)、Finder に渡す URL (実在ファイルはそれ自身、消えていれば親ディレクトリ)、ホットキーの登録可否。**通知バナーの表示とクリック、他アプリ前面でのキー押下は自動化できない** (Notification Center と TCC の状態に依存) ので目視確認。T11 と同じく xcodegen 未導入 / kilde-dev 証明書なし / KildeGUI 起動中は SKIP |
| T20 | `rec --hdr` — SDR 機でのフォールバック (理由を `⚠ HDR:` で表示し、録画は成功して **exit 0**) / **`--codec` を明示**して hevc 以外にした場合と `--no-video` との併用は録画前に exit 64。**`--codec` 省略時と設定ファイル由来の非 hevc は exit 64 ではなく、警告つき SDR フォールバック (exit 0)** — CLI の引数検証は明示指定しか見られず、解決後の値は `Recorder` が判定するため。HDR として録れることの確認は HDR ディスプレイが要るため別 (下記の手動確認) |

作業ディレクトリ (録画物とログ) は失敗調査のため削除されず、最後に
パスが表示されます。

テスト用に「自分で音を鳴らすウィンドウ」を持つ最小アプリ
`scripts/soundapp.swift` を同梱しており、スクリプトが自動でコンパイルして使います
(T6–T8 のウィンドウ音声スコープ検証用)。

### HDR 収録の確認 (要 HDR ディスプレイ — issue #16)

`--hdr` は統合テストに入れていません。**HDR として録れたことの確認には HDR ディスプレイが
必要で、現在の検証機 (LG Ultra HD) は HDR 非対応**のためです (SPIKE-NOTES F-H)。
HDR ディスプレイのある環境では、次を手動で確認してください:

```sh
kilde rec --hdr --codec hevc --duration 10s hdr.mov
```

- 結果に `⚠ HDR:` の行が**出ない**こと (出ていれば SDR に落ちています)
- QuickTime Player でファイルを開き、インスペクタ (⌘I) で色空間が PQ
  (HLG ではない) になっていること
- `ffprobe -show_streams hdr.mov` なら `color_primaries=smpte432` (Display P3),
  `color_transfer=smpte2084` (PQ), `color_space=bt2020nc`, `profile=Main 10`

  色域が Display P3 なのは、使うプリセットが `captureHDRStreamLocalDisplay` だからです
  (HDR10 メタデータ付きの `captureHDRRecordingPreservedSDRHDR10` は CI の SDK に
  シンボルが無く使えていません — issue #76)。**PQ と組み合わせる YCbCr マトリクスは、
  色域が P3 でも BT.2020 を使います** (709 を使うと広色域が範囲外に出てクランプされる)。

SDR ディスプレイでは逆に、**SDR へのフォールバックが働くこと**を確認できます
(`⚠ HDR: 収録対象のディスプレイが HDR に対応していないため SDR で録画します
(HDR には HDR 対応ディスプレイが必要です)` が出て、録画自体は成功し**終了コードは 0**)。
`--codec` を省略した場合や設定ファイルの codec が hevc でない場合は、代わりに
`⚠ HDR: HDR は HEVC でのみ書き出せます (現在のコーデック: h264)。…` が出ます。

### A/V ドリフト計測 (長時間録画)

```sh
scripts/drift-test.sh [録画時間 (既定 15m)] [マーカー間隔秒 (既定 30)] [separate|mixed|both]
```

点滅 + ビープのマーカーを出すウィンドウを収録し、映像 / system / mic のずれが
録画中に増えていかないかを ms 単位で出します (issue #3)。統合テストとは別物で、
既定の 15 分 × 2 モードで ~31 分かかります。前提は統合テストと同じ (権限・音量) に加えて、
計測中は `KildeDriftMarker` ウィンドウを隠さず、画面をロックしないこと
(ロック中は SCK がフレームを出さず映像が 0 秒になります)。
音響経路 (スピーカー → マイク) で測る場合は、静かな環境で行ってください
(物音が入るとマーカーの検出が欠けて値が汚れます)。

鳴らす先とマイクは環境変数で指定できます (`OUT` はシステムの既定出力を変えません)。

```sh
OUT="BlackHole" MIC="device:BlackHole" scripts/drift-test.sh   # 音響経路なし (ループバック)
OUT="MacBook Proのスピーカー" MIC="device:MacBook" scripts/drift-test.sh  # 音響経路あり
```

内蔵スピーカー・内蔵マイクはクラムシェル (蓋を閉じた状態) では使えないため、
蓋を開けられない Mac では BlackHole ループバックを使います。この場合 mic 側は
BlackHole の仮想クロックになる点に注意してください。
仕組みと結果の記録先は SPIKE-NOTES.md F-E です。

### 単体テスト

```sh
swift test
```

`Tests/KildeCoreTests/` は権限なし・ヘッドレスで通る単体テストです
(CI で実行できる前提で書いている。ワークフロー自体は issue #6 で追加する)。
SCK / AVCapture / CoreAudio の実デバイスには触れません。

| ファイル | 対象 |
|---------|------|
| `ParseDurationTests` | `parseDuration` の正常系・異常系 |
| `AudioMixerTests` | 2 ソース合成とクリップ、44.1k mono → 48k stereo、ギャップの無音埋め / 重複の無視、初回データ待ち (`firstDataGraceFrames`) と `flush()`、非数値 PTS / `decodeFailures` |
| `MonitorDeviceStateTests` | `~/.kilde/monitor-state.json` の入出力 (`MonitorDevice.stateDirectory` を一時ディレクトリに差し替える) |
| `KilErrorTests` | `KilError.exitCode` の 1/2/3 契約 |
| `ConfigTests` | `~/.kilde/config.json` の入出力と不正値 (壊れた JSON・未知のキー・型違い・範囲外)、`rec` 既定値の優先順位 (CLI > プリセット > `KILDE_OUTPUT_DIR` > 設定 > 既定)、存在しない保存先の事前検出 (`ConfigStore.directory` を一時ディレクトリに差し替える) |
| `FileInspectionTests` | 生成した正弦波ファイルに対し、`FileInspection.report(url:)` の同期版と async 版 (issue #35) が同じ RMS / peak / 長さを返す |
| `AudioSampleBufferTestHelper` | テスト用の Float32 / Int16 `CMSampleBuffer` 生成 |

`RecCommand.validate()` は CLI ターゲット (実行ファイル) 側にあるため対象外です。

## 5. トラブルシュート

| 症状 | 原因と対処 |
|------|-----------|
| `権限エラー: 画面収録の権限がありません` | `kilde doctor` → 許可 → **プロセスを再起動** |
| ウィンドウ収録で `CGS_REQUIRE_INIT` 相当のクラッシュ | `RecCommand.run()` 冒頭の `NSApplication.shared` / `setActivationPolicy(.accessory)` が消えていないか |
| 映像トラックが真っ黒 / サイズ不正 | `SCStreamConfiguration.pixelFormat` に BGRA を指定しているか、`outputSettings` に幅・高さがあるか |
| 音声が無音 (rms=0.0000) | 出力音量、収録対象ウィンドウの取り違え (ウィンドウ収録は他アプリの音が入らないのが仕様) |
| `--monitor` / `audio monitor setup` で BlackHole が無音 | aggregate device の非公開キー `"stacked": true` が落ちていないか (SPIKE-NOTES F-C) |
| 既定出力が `kilde Monitor` のまま戻らない | `kilde audio monitor teardown`。状態は通常 `~/.kilde/monitor-state.json` に保存される。`KILDE_CONFIG_DIR` を指定して実行した場合は、そのディレクトリの `monitor-state.json` を確認する |
| サマリの `ミックスできなかった音声バッファ` が 0 でない | 入力デバイスが非対応フォーマット (Float32 以外) を返している。`MicStream.init` の `output.audioSettings` (Float32 / 48k / 2ch) の統一が効いているか |
| mic の first-PTS 差が大きい | マイクを SCK より先に開始しているか (`Recorder.recordAndFinalize()` の順序) |

## 6. 残課題

| # | 内容 | 状態 |
|---|------|------|
| 1 | **S10: 会議アプリ実地検証** (Zoom / Teams / Chrome Meet で `--preset meeting`) | 未実施 — issue #2 |
| 2 | `feature/m1-cli-mvp` を `main` へマージ | 済 (PR #1) |
| 3 | `Tests/KildeCoreTests` の作成 | issue #5 |
| 4 | CI (`.github/workflows`) で `swift build` + 単体テスト | issue #6 |
| 5 | 長時間 (10 分級) の A/V ドリフト測定 | 部分完了 — BlackHole ループバックで 15 分 (最大 12 ms)、実マイクでの計測は未実施 (issue #3、SPIKE-NOTES F-E) |
| 6 | 旧 OS (14/15) での S7 / S8 / S9 挙動の確認 | issue #4 |
| 7 | `LICENSE` (MIT) の追加 | 済 (issue #21) |
| 8 | DESIGN.md §6 の終了コード `130` と実装 (SIGINT で exit 0) の食い違いを解消 | 済 — exit 0 に統一 (issue #7) |
| 9 | SCK 圧縮フレーム passthrough (無再エンコード録画) の検討 | issue #15 |
| 10 | M2: 領域指定収録 / グローバルホットキー / 一時停止・再開 | issue #9 / #10 / #11 |
| 11 | M3: メニューバー GUI (`gui/` を Xcode プロジェクトとして作成) | issue #17〜#20 |

残タスクの正本は GitHub issue です。この表は索引としてだけ使ってください。

## 7. ブランチと PR

- **AI エージェント向けの運用ルール (issue 起点の作業、ブランチ命名、PR とレビュー対応) は
  リポジトリ直下の [AGENTS.md](../AGENTS.md) にある。**
- 作業ブランチ: issue ごとに `origin/main` から `feature/<issue番号>-<slug>` を切る
  (M1 の `feature/m1-cli-mvp` は PR #1 でマージ済み。今後は使わない)
- リモート: https://github.com/takezou621/kilde
- コミットメッセージは英語。既存履歴のスタイル (命令形の要約行) に合わせる
- ドキュメントとコードコメントは日本語。特に macOS 26 固有の回避策は
  **「なぜそう書いたか」**をコメントに残す (後から消されると再発するため)
- `.claude/` は `.gitignore` 済み。`CLAUDE.md` はコミット対象
