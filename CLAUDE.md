# CLAUDE.md

このファイルは Claude (Claude Code / Cowork / デスクトップ) がこのリポジトリで
作業するときに最初に読むコンテキストです。**issue / ブランチ / PR / レビュー対応の
運用ルールは [AGENTS.md](AGENTS.md)** にあり、作業を始める前に併せて読むこと。
人間向けの手順書は
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)、リリース手順は
[docs/RELEASE.md](docs/RELEASE.md)、設計の根拠は
[docs/DESIGN.md](docs/DESIGN.md) と [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md) にあります。

## 1. このプロダクトは何か

**kilde** — macOS 向け OSS の画面 + 音声 録画ツール。
QuickTime Player では録れない**システム音声を含む録画・録音**をワンコマンド (CLI) と
メニューバーアプリ (GUI) で行う。

最重要ユースケース: Zoom / Google Meet / Teams の会議を、相手の声 (システム音声) と
自分の声 (マイク) の両方を 1 トラックにミックスして録る。
最重要要件: **Ctrl+C でもファイルが必ずファイナライズされる** (壊れたファイルを残さない)。

### リポジトリ分割 (issue #115 / #118)

| リポジトリ | 内容 | 公開範囲 |
|---|---|---|
| kilde-team/kilde (**本リポジトリ**) | メニューバー GUI (`gui/`)、リリースと配布 (`release.yml` + `scripts/release/` + Homebrew formula)、ドキュメント | Public |
| kilde-team/kilde-cli-swift | 録画エンジン (`KildeCore`) と `kilde` CLI のソース、単体テスト、統合テスト、CI | Private (kilde-team メンバー) |

- **本リポジトリに Swift パッケージは無い**。`swift build` / `swift test` は
  kilde-cli-swift 側で行う (エンジンを変更する作業は同リポジトリで)
- GUI は kilde-cli-swift を **revision 固定**のリモートパッケージ依存で参照する
  (`gui/project.yml` の pin)。private リポジトリのため、パッケージ解決には
  kilde-team メンバーの git 認証が必要
- release workflow も同じ revision を checkout する (`release.yml` の `ref:`)

## 2. 現在地 (2026-09-14)

| 項目 | 状態 |
|------|------|
| ブランチ | `main`。作業は issue ごとに `feature/<N>-<slug>` (AGENTS.md §2 の worktree ルール) |
| GUI (`gui/`) | ✅ メニューバー録画アプリとして実用域 (録画 UI・権限オンボーディング・完了通知・最近の録画・グローバルホットキー・ログイン時起動)。issue #17〜#20 |
| エンジン / CLI | kilde-team/kilde-cli-swift に移管済み (issue #115 Phase 1〜2)。本リポジトリの `Sources/` `Tests/` `Package.swift` と CLI 関連スクリプト・ci.yml は削除済み (issue #118) |
| リリース | `v*` タグで自動リリース (issue #25 / #118)。CLI は kilde-cli-swift の pin 付き checkout からビルド。v0.1.0 は unsigned zip で公開済み |
| Homebrew | tap `kilde-team/homebrew-kilde` (public) で `brew install kilde-team/kilde/kilde` (v0.1.0+)。head ブロック (外部ソースビルド) は廃止 — CLI ソースが private のため |

## 3. 全体の地図

```
gui/                           メニューバー GUI (XcodeGen: project.yml が正本)
  project.yml                  ビルド設定と kilde-cli-swift への pin (依存の真実の源)
  Sources/KildeGUIApp.swift    アプリのエントリポイント (AppDelegate 接続)
  Sources/AppDelegate.swift    NSStatusItem + NSPopover の手動管理。録画モデルの持ち主 (閉じても録画継続)
  Sources/RecordingController.swift  Recorder の start/stop と events 購読 → 状態・経過時間・レベル
  Sources/RecordingSetup.swift 選択状態 (RecordRequest) と画面・ウィンドウ・入力デバイスの列挙
  Sources/ContentView.swift    録画パネル (対象・音声・保存先の選択、Rec/Stop、レベルメーター)
  Sources/LevelMeter.swift     ソース別レベルメーター (dB 表示)
  Sources/SelfTest.swift       KILDE_GUI_SELFTEST_* による UI なし録画 (検証用)
  Sources/MeetingDetector.swift  会議の検知 (CoreAudio のプロセス単位のマイク使用 +
                               CGWindowList の会議ウィンドウ)。判定は純関数 evaluate (issue #197)
  Sources/MeetingAutoRecorder.swift  会議の自動録画の状態遷移 (検知 → 開始 → 終了判定 → 停止)。
                               AppDelegate が持つ。規則の検証は SelfTestMeeting.swift
  Sources/UpdaterCoordinator.swift  Sparkle 2 自動更新の窓口 + 録画中の再起動待ち (issue #122)。
                               ファイル全体が `#if !APPSTORE` — MAS ビルドでは
                               UpdaterCoordinatorAppStore.swift のスタブに差し替わる
  Sources/SandboxSupport.swift サンドボックス下 (MAS) でのみ必要な支援。全体が `#if APPSTORE`
  Resources/Info.plist         LSUIElement・権限説明文字列・SUFeedURL/SUPublicEDKey (バンドル用)
  Resources/KildeGUI.entitlements  audio-input (Hardened Runtime 下のマイクに必須)
  Resources/KildeGUI-AppStore.entitlements  App Sandbox + マイク + Movies + bookmark (MAS 版用)
scripts/release/sign.sh        Developer ID 署名 + notarization + zip/DMG 作成
                               (CLI は kilde-cli-swift の checkout をビルド — CLI_DIR)
scripts/release/appstore-archive.sh  App Store 配布ビルド (KildeGUI-AppStore) の
                               アーカイブ + 検証 + ASC へのアップロード (issue #126)
scripts/release/entitlements.plist  audio-input (署名用)
.github/workflows/release.yml  v* タグで kilde-cli-swift (pin 固定 + PAT) を checkout し
                               CLI をビルド、sign.sh で署名して Release を作成
                               (署名 secrets 不足ならジョブは失敗 — unsigned 分岐は廃止)
homebrew/Formula/kilde.rb      tap (kilde-team/homebrew-kilde) と同じ内容の formula 正本
docs/                          DEVELOPMENT.md / RELEASE.md / DESIGN.md / SPIKE-NOTES.md ほか
```

録画の挙動 (`KildeCore`) と CLI 層の設計・地雷は kilde-team/kilde-cli-swift の
`CLAUDE.md` が正本。エンジンに関わる変更はそちらの issue / ブランチで行う。

## 4. リリースと配布の契約

- **GUI と release workflow の pin は必ず揃える**: `gui/project.yml` の依存 revision と
  `release.yml` の `ref:` は同じコミットを指す (現在 `4d2f251535ed6e907fea185e116ed9b9eb1392b3`)。
  片方だけ更新すると、GUI と配布 CLI が**別のエンジン revision** でビルドされる。
  更新は必ず同じ PR で行い、手順は docs/RELEASE.md「CLI ソースの pin の更新」
- **`KILDE_CLI_SWIFT_TOKEN` が無いと release が作れない**: GITHUB_TOKEN は他リポジトリを
  読めないため、kilde-cli-swift (private) の checkout には fine-grained PAT
  (Contents: Read-only) が必要。未設定だと checkout step が失敗する
- **バージョンの真実の源は `v*` タグ**。workflow がタグの値を kilde-cli-swift と gui の
  `Info.plist` と `KildeCommand.swift` にビルド時に差し込む (コミットはしない)。
  手動実行 (workflow_dispatch) は常に dry-run — Release は作らない
- **成果物名は `kilde-<version>-macos.zip`** — Homebrew formula の `url` がこの名前を
  指す。**署名は必須**: §4 の署名用 6 secrets と Sparkle の `SPARKLE_ED25519_PRIVATE_KEY`
  (RELEASE.md §5) が揃っていないとジョブは失敗する。unsigned へのフォールバックは
  廃止 — appcast の無いリリースが latest になると全ユーザーの更新チェックが壊れるため
- **Homebrew formula は 2 箇所で揃える**: 本リポジトリの `homebrew/Formula/kilde.rb`
  (正本) と tap kilde-team/homebrew-kilde。リリース zip の `url` / `sha256` を更新して
  tap へ反映する (docs/RELEASE.md「Homebrew tap の更新」)。head ブロックはない —
  CLI ソースが private のため外部ソースビルドの経路は存在しない
- **`sign.sh` は CLI ソースの場所を知っている**: 既定 `$ROOT_DIR/kilde-cli-swift`
  (release.yml の checkout path と一致)。別の場所は `--cli-dir` / `KILDE_CLI_DIR`
- **App Store 配布は直接配布 (Sparkle) と併存する 2 本立て** (issue #126):
  `KildeGUI-AppStore` ターゲットが MAS 版を作る。バンドル ID は 2 チャネルで同じ
  `com.takezou621.KildeGUI`。**MAS 版に Sparkle は禁止** (ストア外自己更新のため) —
  `#if APPSTORE` / `#if !APPSTORE` で分岐し、appstore-archive.sh がアーカイブ内の
  Sparkle 無しと App Sandbox 有効を検証する。**MAS ビルドの DerivedData は必ず分離**
  (PRODUCT_NAME が同じ KildeGUI のため、使い回すと以前の Sparkle.framework が残る)。
  サンドボックス下では `~/.kilde` が読めないため、SandboxSupport が
  `ConfigStore.directory` をコンテナ内へ退避させる。手順は docs/RELEASE.md §7
- CLI の終了コード (`0`/`1`/`2` 権限/`3` デバイス不明、検証エラー `64`) と既定値
  (`--audio system`、`--audio-tracks mixed`、出力名 `kilde-yyyyMMdd-HHmmss.*`) は
  変更してはいけない契約。**正本は kilde-team/kilde-cli-swift と DESIGN.md §6** —
  変更はエンジン側の PR で行い、DESIGN.md §6 も揃えて更新する

## 5. GUI を触るときの地雷 (macOS 26 実測)

エンジン本体の地雷 (pixelFormat、`outputSettings`、`NSApplication` accessory、
aggregate device の `"stacked": true`、マイクの起動順、`AVAssetTrack.load(.duration)`、
Info.plist 埋め込みの `unsafeFlags`、SDK シンボルの CI 確認) は
**kilde-team/kilde-cli-swift の `CLAUDE.md` §5 が正本** — エンジンに触る変更の前に
必ずそちらを読む。ここには GUI と配布側のものを書く:

1. **`MenuBarExtra` の `.window` パネルは macOS 26 で開かない。** そのため GUI は
   `NSStatusItem` + `NSPopover` を AppKit で手動管理する (`AppDelegate.swift`)。
   SwiftUI 化・単純化でこれを崩さないこと
2. **`NSApp.delegate as? AppDelegate` は nil になる** (ロード順のタイミング)。
   AppDelegate への参照は `AppDelegate.shared` を使う
3. **録画は AppDelegate が持つ** (`RecordingController`)。パネル (NSPopover の
   contentViewController) に持たせると、**パネルを閉じた瞬間に録画が死ぬ**。
   「閉じても録画継続」は issue #18 の受け入れ条件で、セルフテスト
   (`KILDE_GUI_SELFTEST_POPOVER=close`) が保証する
4. **Hardened Runtime 下のマイクには `com.apple.security.device.audio-input`
   エンタイトルメントが必須** (`gui/Resources/KildeGUI.entitlements`)。欠けると
   エラーもクラッシュもなく**無音のトラック**になる (検証手順は docs/DEVELOPMENT.md §3)
5. **TCC 権限はコード署名で識別される**ため、ad-hoc 署名だと権限トグルが再起動のたびに
   外れる。`gui/project.yml` は `kilde-dev` 自己署名証明書で署名する設定にしてある。
   無い環境での作り方は docs/DEVELOPMENT.md §3
6. **画面収録権限はプロセス再起動後に有効化**され、macOS 15+ では定期的に再確認で
   失効しうる。GUI はパネルを開くたびと録画開始直前に権限を取り直す
   (KildeCore.Permissions)。また**その構成に要る権限だけ**を要求する
   (音声のみ + マイクなら画面収録は不要 — `KILDE_GUI_SELFTEST_PERMISSIONS=1` で確認)
7. **消灯・ロック中は SCK がフレームを出さない** — 録画は exit 0 なのに `duration=0.00s`
   のファイルが残る。実録画検証は `caffeinate -u -t 1` (起こす) + `caffeinate -dims`
   (消させない) の 2 段構えで行う。ロック解除は人手。クラムシェルで内蔵スピーカーが
   既定出力だと音声が `-66681` / `-3818` で失敗する (docs/DEVELOPMENT.md §3)
8. **UI なしの録画検証はセルフテスト経由** (`KILDE_GUI_SELFTEST_RECORD` 等)。UI の
   手動操作に頼らず、GUI → Recorder の経路をコマンドラインから確かめられる
9. ローカル署名ビルドでは `com.apple.linkd.autoShortcut` 接続エラー等のノイズが
   コンソールに出るが、AppIntents を使わないため機能への影響はない
10. **Sparkle の postpone セレクタは `untilInvokingBlock:`** (Sparkle 2)。旧名
    `untilInvoking:` はオプショナルメソッドのため、間違えても警告なしで永久に
    呼ばれず、**録画中の再起動待ちが黙って無効になる** (壊れたファイルを残す経路が
    復活する)。`UpdateInstallGate` を触るときは必ず確認する
11. **sign.sh のネスト署名の find を狭めない**。Sparkle.framework はネストコードとして
    `XPCServices/*.xpc`、ネスト `.app` の Updater.app、拡張子なし Mach-O の Autoupdate
    を持つ。find がこれらを拾わないと外側の署名だけが作られ、配布物の Gatekeeper が
    通らない (`--deep` 相当の検証で落ちる)
12. **appcast の EdDSA 署名は staple の後**。`stapler staple` は DMG を書き換えるため、
    先に署名すると配布物と署名の対象が食い違い Sparkle が更新を拒否する。
    sign.sh はこの順序を保証する — 処理順を変えるときは理由を書く
13. **GUI の `CFBundleVersion` (= appcast の `sparkle:version`) はリリースごとに
    単調増加が契約**。Sparkle はバージョン文字列ではなくこの値で更新を判定する。
    release workflow が `GITHUB_RUN_NUMBER` を差し込む前提なので、手差し込みの
    リリースでは必ず前回より大きい値にする
14. **Sparkle 2 の自動チェックのキーは `SUEnableAutomaticChecks`**。Sparkle 1 の
    `SUAutomaticallyChecksForUpdates` に戻すと警告なしで効かなくなり、Debug ビルドの
    「実フィードを見にいかない」が黙って無効になる (UpdaterCoordinator が書き込む値。
    defaults での戻し手順は docs/DEVELOPMENT.md §3)
15. **MAS ビルド (`KildeGUI-AppStore`) は Sparkle をリンクしない**ため、
    `import Sparkle` は `UpdaterCoordinator.swift` 内の `#if !APPSTORE` の**内側**に
    ある。外に出すと MAS ビルドだけが「モジュールを解決できない」で落ちる
    (通常ビルドは通るので、GUI 単体ビルドでは気づけない)。MAS 版の同じ API の
    スタブは UpdaterCoordinatorAppStore.swift。両スキームのビルドを通して初めて
    「通った」と言える
16. **サンドボックス下では `~/.kilde` が読み書きできない**。MAS 版は
    `SandboxSupport.redirectConfigStoreIntoContainer()` が `ConfigStore.directory`
    をコンテナ内 (App Support/kilde) へ退避させる — これは static var の
    **初回アクセス前に**実行する必要があり、現在の最初の消費者は
    `RecordingSetup.init`。ConfigStore に触る新しいコードを足すときは呼び出し位置を
    見直すこと。保存先の永続化は security-scoped bookmark を UserDefaults に置く
    (~/.kilde/config.json を MAS 専用 blob で汚さないため。CLI は bookmark を解釈できない)
17. **サンドボックス下の `FileManager.urls(for: .moviesDirectory, …)` は «コンテナ内» の
    Movies を返す**。既存コンテナでは実 `~/Movies` への symlink になっていることも
    あるが、**新規コンテナでは実ディレクトリが作られ、録画がコンテナの中に落ちる**
    (2026-09-18 実測: 修正前ビルドは `recentCount=0` — ユーザーの ~/Movies が
    見えていなかった)。symlink だった場合でもアプリが持ち回るパス文字列はコンテナの
    ままなので、保存先表示・録画完了のパス表示・通知の「Finder で表示」・
    「最近の録画」がユーザーからアクセスできない場所を指す。これで
    **App Store 審査 Guideline 2.4.5(i) でリジェクトされた** (0.3.0 (2)、2026-09-17)。
    MAS 版の既定保存先は必ず `SandboxSupport.userVisibleMoviesDirectory()` を通す
    (symlink 解決 → だめなら getpwuid の実ホーム)。**`NSHomeDirectory()` も
    サンドボックス下ではコンテナを返す**ので、実ホームの取得には使えない
18. **会議の自動録画の検知に ScreenCaptureKit の列挙を使わない** (issue #197)。
    検知は 2 秒周期で常時回るので、`SCShareableContent` を使うと録画開始との競合
    (issue #70 — 両方が無期限に止まる) を常時作りうる。ウィンドウは
    `CGWindowListCopyWindowInfo` で見る (CGWindowID = `SCWindow.windowID`)。
    また**自動で始めた録画だけを自動で止める** (`MeetingAutoRecorder.ownsSession`) —
    手動の録画を会議の終了で止めない。マイク使用の判定 (`kAudioProcessPropertyIsRunningInput`)
    は macOS 14.2+ の API なので `#available` の内側に置く (デプロイ対象は 14.0)

## 6. 作業の進め方 — issue 駆動 (共通ルールは AGENTS.md)

@AGENTS.md

**依頼が「issue #N を実装して」「〜を進めて」だけでも、AGENTS.md §1〜§5 の観点
(issue の受け入れ条件・`feature/<N>-<slug>` ブランチ・PR に検証結果と `Closes #N`・
AI レビュー指摘の処理・完了報告) を毎回自動で適用する。** 依頼文に書かれていなくても
省略しない。

**並行開発は worktree 前提** (2026-09-11 の合意)。着手前の宣言・
1 issue = 1 worktree = 1 ブランチ・メイン作業コピーでは実装しない。詳細は
**AGENTS.md §2「並行開発 — worktree 必須」** に従う。

このリポジトリ固有の注意:

- **エンジン / CLI への変更依頼は kilde-team/kilde-cli-swift 側の issue に切り出す**
  (本リポジトリの issue で実装しない)。GUI が参照する pin の更新だけが本リポジトリ側の
  作業 (§4 の契約: GUI と release.yml を同じ PR で揃える)
- 変更を入れたら GUI のビルドを確認する (`cd gui && xcodegen && xcodebuild … build`)。
  録画の挙動に関わる検証 (統合テスト・セルフテスト) は docs/DEVELOPMENT.md §3 の手順で、
  **両リポジトリのテストスイートを並行実行しない** (録画の権限・画面・音声が衝突する)。
  実録画を伴う統合テストの実行前に、その事実を依頼者に宣言する (録画スロットの合図)
- ドキュメントは日本語。コード内コメントも日本語で、**「なぜそうしたか」**
  (特に §5 の地雷) を書く。コミットメッセージは英語 (既存履歴に合わせる)
- `.claude/` は `.gitignore` 済み。**CLAUDE.md / AGENTS.md はコミット対象**

## 7. 次の一手

**タスクの正本は GitHub issue** (https://github.com/kilde-team/kilde/issues)。
このファイルに個別タスクを列挙しない (陳腐化するため)。エンジン / CLI のタスクは
kilde-team/kilde-cli-swift の issue 管理へ移っている。新しい作業は必ず `origin/main`
から issue ごとのブランチを切る (AGENTS.md §2)。
