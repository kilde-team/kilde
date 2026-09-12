# CLAUDE.md

このファイルは Claude (Claude Code / Cowork / デスクトップ) がこのリポジトリで
作業するときに最初に読むコンテキストです。**issue / ブランチ / PR / レビュー対応の
運用ルールは [AGENTS.md](AGENTS.md)** にあり、作業を始める前に併せて読むこと。
人間向けの手順書は
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)、設計の根拠は
[docs/DESIGN.md](docs/DESIGN.md) と [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md) にあります。

## 1. このプロダクトは何か

**kilde** — macOS 向け OSS の画面 + 音声 録画 CLI。
QuickTime Player では録れない**システム音声を含む録画・録音**をワンコマンドで行う。

- 言語/ビルド: Swift / SwiftPM (`swift build`)。`swift-tools-version:5.10`、
  検証時のツールチェーンは Swift 6.3.3 / Xcode 26.5 SDK。依存は `swift-argument-parser` のみ
- 対応: macOS 14+ (宣言)。**実検証は macOS 26 / Apple Silicon のみ**
- 最重要ユースケース: Zoom / Google Meet / Teams の会議を、相手の声 (システム音声) と
  自分の声 (マイク) の両方を 1 トラックにミックスして録る
- 最重要要件: **Ctrl+C でもファイルが必ずファイナライズされる** (壊れたファイルを残さない)

## 2. 現在地 (2026-09-11)

| 項目 | 状態 |
|------|------|
| ブランチ | `main` (M1 CLI MVP = PR #1 を 2026-09-11 にマージ済み)。作業は issue ごとに `feature/<N>-<slug>` |
| M0 技術スパイク | ✅ 完了 (S1–S9)。S10 会議アプリ実地検証は issue #2 |
| M1 CLI MVP | ✅ 実装済み — `rec` / `devices` / `doctor` / `audio monitor` / `inspect` |
| 統合テスト | `scripts/integration-test.sh` (T1–T12)。ローカル実録画、全 PASS 実績あり。T11 (GUI) は xcodegen・kilde-dev 証明書が無い環境や KildeGUI 起動中は SKIP |
| 単体テスト (`Tests/`) | ✅ KildeCoreTests (権限不要、CI で実行 — issue #5 完了) |
| CI (`.github/`) | ✅ swift build / swift test (macos-15) — issue #6 完了 |
| GUI (`gui/`) | 骨格 ✅ (issue #17: NSStatusItem + NSPopover + KildeCore 参照 — macOS 26 の MenuBarExtra 不具合を回避)。録画 UI ✅ (issue #18)。オンボーディング・通知は #19 / #20 |
| ライセンス / OSS 整備 | ✅ `LICENSE` (MIT)、`CONTRIBUTING.md`、`.github/` の Issue・PR テンプレート (issue #21) |
| 残タスク全体 | GitHub issue #2〜#25 (4 マイルストーン)。§8 の役割分担・依存順を参照 |

## 3. 全体の地図

```
Package.swift            SPM: KildeCore (lib) + kilde (executable)
Sources/kilde/           CLI 層 — 引数解析とコンソール出力のみ。ロジックを置かない
  main.swift               エントリポイント (KildeCommand.main() のみ)
  KildeCommand.swift       ルートコマンド / cliError() / installStopSignalHandler()
  RecCommand.swift         rec — オプション検証、meeting プリセット、進捗表示、サマリ出力
  DevicesCommand.swift     devices (--no-windows でウィンドウ一覧を省略)
  DoctorCommand.swift      doctor (権限診断 + 要求)
  AudioCommand.swift       audio monitor status|setup|teardown
  InspectCommand.swift     inspect FILE
  ConfigCommand.swift      config show|set|unset|path
  Info.plist               リンカで実行ファイルに埋め込む (§5 参照)
Sources/KildeCore/       UI 非依存のコア。将来 GUI と共用する
  Recording/Recorder.swift     セッションの指揮 (RecordOptions → 実行 → Summary)
  Recording/MovieWriter.swift  AVAssetWriter ラッパ。PTS アンカーとカウンタ
  Recording/AudioMixer.swift   複数ソース → 48kHz/2ch 1 トラック合成
  Recording/RecordRequest.swift GUI の選択 → RecordOptions (RecordSettings.apply 経由で CLI と同じ解決)
  Capture/ScreenAudioStream.swift  SCStream ラッパ (.screen / .audio)
  Capture/MicStream.swift          AVCaptureSession ラッパ (マイク / 任意入力デバイス)
  Capture/AudioConversion.swift    CMSampleBuffer → interleaved Float32
  Devices/DisplayCatalog.swift     SCShareableContent 列挙・ウィンドウ解決
  Devices/AudioDeviceCatalog.swift CoreAudio HAL + MonitorDevice (マルチ出力デバイス)
  Support/Permissions.swift        TCC 権限の確認・要求
  Support/FileInspection.swift     出力ファイルの検証 (inspect / 統合テストが使用)
  Support/Errors.swift             KilError → 終了コード
  Support/Config.swift             ~/.kilde/config.json (ConfigStore) と rec 既定値の優先順位解決 (RecordSettings)
  Support/{AsyncUtil,Misc}.swift   awaitSync (同期コンテキスト専用・noasync) / parseDuration / 出力名生成
scripts/integration-test.sh  T1–T12 の実録画テスト (T11 GUI / T12 設定ファイル)
scripts/soundapp.swift       テスト用「音を鳴らすウィンドウ」アプリ
gui/                         M3 メニューバー GUI (XcodeGen: project.yml が正本)
  Sources/KildeGUIApp.swift    アプリのエントリポイント (AppDelegate 接続)
  Sources/AppDelegate.swift     NSStatusItem + NSPopover の手動管理。録画モデルの持ち主 (閉じても録画継続)
  Sources/RecordingController.swift  Recorder の start/stop と events 購読 → 状態・経過時間・レベル
  Sources/RecordingSetup.swift  選択状態 (RecordRequest) と画面・ウィンドウ・入力デバイスの列挙
  Sources/ContentView.swift    録画パネル (対象・音声・保存先の選択、Rec/Stop、レベルメーター)
  Sources/LevelMeter.swift     ソース別レベルメーター (dB 表示)
  Sources/SelfTest.swift       KILDE_GUI_SELFTEST_* による UI なし録画 (検証用)
  Resources/Info.plist         LSUIElement・権限説明文字列 (バンドル用)
  Resources/KildeGUI.entitlements  audio-input (Hardened Runtime 下のマイクに必須)
```

**レイヤ規約: CLI 層にロジックを足さない。** 録画の挙動に関わる変更は必ず
KildeCore 側に入れる (M3 の GUI が同じコードを使うため)。

## 4. コマンドと契約

```sh
swift build                       # ビルド (バイナリは .build/debug/kilde)
.build/debug/kilde doctor         # 権限・環境の診断 (初回はここから)
.build/debug/kilde devices        # ディスプレイ / ウィンドウ / オーディオ機器
.build/debug/kilde rec [出力パス]  # 録画・録音 (Ctrl+C で停止)
.build/debug/kilde audio monitor status|setup|teardown
.build/debug/kilde inspect FILE   # トラック構成・RMS/peak
.build/debug/kilde config show|set|unset|path  # ~/.kilde/config.json (rec の既定値)
```

`rec` の主なオプション: `--display` / `--window` / `--audio`(複数可) /
`--audio-tracks mixed|separate` / `--no-video` / `--monitor` / `--output,-o` /
`--duration` / `--codec h264|hevc|prores` / `--fps` / `--cursor|--no-cursor` /
`--countdown` / `--preset meeting`

既定値の優先順位は **CLI 引数 > `--preset` > 環境変数 (`KILDE_OUTPUT_DIR`) > 設定ファイル > 既定値**
(DESIGN.md §6「設定ファイル」)。CLI のオプションは「未指定 = nil」で受け、解決は
`RecordSettings.apply()` に任せる — CLI 側に既定値を書くと設定ファイルが効かなくなる

**変えてはいけない契約 (DESIGN.md §6 / Errors.swift):**

- 終了コード: `0` 成功 / `1` その他失敗 (`KilError.failed`) / `2` 権限不足 /
  `3` デバイス・ウィンドウ不明。`KilError` の case を増やすときは `exitCode` も
  併せて定義し、DESIGN.md §6 の終了コード表も更新する
- **オプション検証エラー (`validate()` の `ValidationError`、未知のオプション名) は
  `cliError()` を通らず、ArgumentParser が `64` を返す。** 「その他の失敗 = 1」では
  ないので、終了コードでスクリプトを分岐させるときはここを踏む
- **SIGINT / SIGTERM / SIGHUP による停止は「正常な停止」で exit 0** (ファイナライズ
  成功時)。DESIGN.md v0.3 の「`130` 割り込み」は v0.4 で廃止した。T10 がこれを保証する
- 既定は `--audio system` + `--audio-tracks mixed`
- 出力の既定名は `kilde-yyyyMMdd-HHmmss.mov` (音声のみは `.m4a`)
- SIGINT / SIGTERM / **SIGHUP** の 3 つを安全停止に接続する
  (SIGHUP を外すとターミナル終了時にファイナライズが飛ぶ)

## 5. 踏んではいけない地雷 (macOS 26 実測)

1〜5 の出典は SPIKE-NOTES.md F-C / F-D。6 は `FileInspection.swift` のコメント、
7 は `Package.swift` の `linkerSettings` とコミット `11768a9`、
8 は issue #16 (PR #74) の CI 失敗が出典。

1. **`cfg.pixelFormat` を明示し、コーデックのクロマに合わせる。** 既定に頼らない。
   - **H.264 / HEVC は `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`。BGRA に戻さないこと** —
     エンコーダ入力はどのみち 4:2:0 YUV なので、BGRA を渡すと色変換が 1 回余計に入り、
     実測で CPU が +24% (うち sys はほぼ倍) になる。画質は PSNR 47.6 dB / SSIM 0.9998 (F-G)
   - **ProRes は `kCVPixelFormatType_32BGRA` のまま。420v にしないこと** —
     ProRes 422 は 4:2:2 なので、4:2:0 で渡すとクロマを半分捨てたまま復元できない。
     編集用の中間ファイルという `--codec prores` の用途が損なわれる
   - **例外: HDR 収録時 (issue #16) はここを設定しないこと。** HDR では
     `SCStreamConfiguration` の HDR プリセットが pixelFormat / colorSpace / colorMatrix を
     整合した組で設定済みで、そこへ上書きすると 10-bit と PQ の情報が落ちて
     **黙って SDR になる**。`Recorder` は HDR で録らないときだけ pixelFormat を設定する

   なお「SCK は既定で圧縮済みフレームを渡す」という旧 F-D.1 の記述は**誤り**で、
   SCK が渡すのは常に非圧縮の pixel buffer である (issue #15 で訂正)
2. **映像の `outputSettings` に `AVVideoWidthKey` / `AVVideoHeightKey` は必須。**
   欠けると `NSInvalidArgumentException` でクラッシュする
3. **`RecCommand.run()` 冒頭の `NSApplication.shared` +
   `setActivationPolicy(.accessory)` を消さない。** 無いとウィンドウ収録開始時に
   `CGS_REQUIRE_INIT` で落ちる。録画経路だけで行い、他サブコマンドを
   GUI セッションに依存させないこと
4. **マルチ出力デバイスの非公開キー `"stacked": true`。**
   `AudioHardwareCreateAggregateDevice` にこれを渡さないとマスター側にしか音が流れず、
   BlackHole が無音になる。**非公開キーなので OS 更新で壊れうる** — 壊れたら
   `kilde audio monitor` 側の縮退で対応し、SCK ネイティブ経路には波及させない
5. **マイク (AVCaptureSession) は起動に ~370ms かかるので、SCStream より先に開始する。**
   `Recorder.recordAndFinalize()` の開始順序 (mic → SCK) はこのための設計
6. **`AVAssetTrack.load(.duration)` は macOS 26 のツールチェーンで壊れている。**
   `FileInspection` はデコードしたサンプルの PTS から長さを求めている
7. **`Info.plist` はリンカの `-sectcreate __TEXT __info_plist` で実行ファイルに埋め込む**
   (`Package.swift` の `unsafeFlags`)。バンドルを持たない CLI に
   `NSMicrophoneUsageDescription` を持たせるため。`unsafeFlags` はルートパッケージでのみ
   許可されるので、**kilde をライブラリとして他パッケージから参照できない**点に注意
8. **新しい OS の API を使うときは、CI の SDK にシンボルがあるかを先に確認する。**
   CI は `macos-26` ランナー (`.github/workflows/ci.yml`、PR #81 で移行) で、ローカルの
   Xcode 26.5 と同じ世代の SDK を使う。**`#available` はコンパイル時の不在を救わない** —
   `if #available(macOS 26, *)` は「実行時にその OS か」を見るだけで、可用性ブロックの
   中身も型チェックされるため、**SDK に無いシンボルはそこでコンパイルエラーになる**
   (`@available` も同じ)。ローカルで通っても CI で落ちる。実例: issue #16 で
   `SCStreamConfiguration.Preset.captureHDRRecordingPreservedSDRHDR10` (macOS 26) を
   `#available` で囲んで使い、当時の macos-15 ランナーの CI が `has no member` で失敗した
   (→ CI を macos-26 に上げて解消、HDR10 プリセットは issue #76 で使用開始)

## 6. 並行性の規約

キャプチャのコールバックは複数のキューから同時に来る。ここを緩めると壊れる。

- `MovieWriter` は `append*` / カウンタ読みのすべてを 1 つの `NSLock` で直列化する。
  **録画中のカウンタ読み出しは必ず `countersSnapshot()` 経由**にする
  (`Recorder.progress()` がこれを使う)。`recordAndFinalize()` 末尾の `Summary` 構築だけは
  停止後なので生プロパティを直接読んでいる — 停止前に読む経路を足す場合は
  スナップショット API 側に寄せること
- `Recorder.mixedAppendLock` は `mixer.push()` → `writer.appendAudio()` を
  ひとまとまりで守る。ここを分割すると mixed トラックへの追加順序が崩れる
- `AudioMixer` は内部 `lock` 保持中に `mixChunk()` を呼ぶ前提
- `MicStream.stop()` は `queue.sync {}` でコールバックを吐かせてから返る
  (`MovieWriter.finish()` の後に `append` が走るのを防ぐ)。`ScreenAudioStream.stop()` (async) も
  `stopCapture()` の後に出力キューを drain してから返る — 同じ理由
- **async コンテキスト (Recorder のセッション等) から `awaitSync` や同期版 API を呼ばない** (issue #35)。
  `awaitSync` は呼び出しスレッドを DispatchSemaphore で塞ぐので、協調プールのスレッドで呼ぶと
  プールを枯渇させうる。`DisplayCatalog.snapshot()` / `listOnScreenWindows()` /
  `FileInspection.report(url:)` / `Permissions.requestMic()` は同期版と async 版を同名で持ち、
  同期版と `awaitSync` は `@available(*, noasync)` にしてある — async から呼ぶとビルド警告になるので、
  **警告を増やさない = この規約を守れている**。同期版は CLI のサブコマンドと GUI の onAppear 用
- **`KildeCore.Recorder` は呼び出し元の実行文脈に依存しない — 特に MainActor を要求しない**
  (issue #16)。`Recorder` は CLI の同期経路 (`run()` が呼び出しスレッド = メインスレッドを
  完了までブロックする) と GUI の async 経路の両方から呼ばれる。セッションの中で
  `await MainActor.run { }` すると、CLI ではそのメインスレッドが `run()` で塞がっているため
  **永久に実行されずデッドロックする** (上の `awaitSync` 禁止と同じ根で、向きが逆)。
  `NSScreen` / `NSWorkspace` など UI フレームワークに触る判定は**呼び出し側**
  (CLI の起動時 / GUI の MainActor 上) で済ませ、結果だけを `RecordOptions` に載せて渡す
  (例: `DisplayHDR.capableDisplayIDs()` → `RecordOptions.hdrCapableDisplayIDs`)。
  **「まだ判定していない」と「判定した結果 該当なし」は別の値で表す** — 同じ値に倒すと
  呼び出し側の載せ忘れが正常系 (黙ってフォールバック) に化け、対象ハードを持つ人にしか
  再現しない。この種の欠陥は特定のオプションの組合せでしか到達せず単体テストをすり抜ける
- 失敗時は `fatalError` を使わない。`KilError` を投げて `Recorder.run()` の catch に
  後始末 (monitor の teardown、writer の cancel) をさせる

## 7. A/V 同期の考え方

- セッションのアンカー = **最初の映像サンプルの PTS** (音声のみモードは最初の音声 PTS)。
  `MovieWriter.Anchor` がこれを表す
- アンカーより前の音声 PTS は同期のためドロップする
- `AudioMixer` は最初に届いたバッファの PTS を基準に、全ソースが揃った範囲を
  1024 フレームずつ吐く。2 秒以上遅れたソースは無音として進め、
  3 秒経っても初回データが来ないソースは断念する (`abandoned`)
- 停止時は `mixer.flush()` の残りを書き切ってから `finish()` する
- `rec` のサマリに出る「映像との first-PTS 差」が同期の健全性指標。
  mic は開始遅延ぶん +0.3s 前後まで想定内

## 8. 作業の進め方 — issue 駆動 (共通ルールは AGENTS.md)

@AGENTS.md

**依頼が「issue #N を実装して」「〜を進めて」だけでも、AGENTS.md §1〜§5 の観点
(issue の受け入れ条件・`feature/<N>-<slug>` ブランチ・PR に検証結果と `Closes #N`・
AI レビュー指摘の処理・完了報告) を毎回自動で適用する。** 依頼文に書かれていなくても
省略しない。

**並行開発は worktree 前提** (2026-09-11 の合意 — 複数 AI セッションが同時に
issue を実装する)。着手前の宣言・1 issue = 1 worktree = 1 ブランチ・
メイン作業コピーでは実装しない・マージ後の後始末まで、詳細な手順は
**AGENTS.md §2「並行開発 — worktree 必須」** に従う。

役割分担 (2026-09-11 の合意):

- **実装は並行する AI エージェント (Claude / Codex 等) が分担**する。issue を単位に
  PR を出す。着手は AGENTS.md §2 の宣言ルールで調整する
- **Claude はアシスタント**: PR レビュー (統合テスト結果・設計との整合)、
  cubic / CodeRabbit 指摘の妥当性判定と整理、issue の追加・分割、実機検証手順の作成。
  依頼されない限り実装コードを書き始めない
- 依存順: #5 単体テスト → #6 CI / #8 Recorder イベント駆動化 → M3 (#17〜#20) /
  #14 設定 → #10 ホットキー → #20 / #23 署名 → #24 Homebrew → #25 Releases。
  検証系 (#2 S10, #3 ドリフト, #4 旧 OS) は手順整備までをエージェント、実行と記録は人間

環境ごとの注意:

- **Claude Code (macOS ターミナル上)**: `swift build` / 統合テストを直接実行できる。
  実行できない状態 (権限モードの分類器がレートリミット等) のときは、コマンドを提示して
  依頼者に `! <command>` で実行してもらう
- **Cowork / Linux 環境**: macOS SDK も権限もないためビルド不可。手順を提示して
  依頼者の macOS で実行してもらう
- 変更を入れたら、影響範囲に応じて `scripts/integration-test.sh` の該当 T 番号を
  再実行する (全体は ~2 分、権限と音量が必要)
- ドキュメントは日本語。コード内コメントも日本語で、**「なぜそうしたか」**
  (特に §5 の地雷) を書く。コミットメッセージは英語 (既存履歴に合わせる)
- `.claude/` は `.gitignore` 済み。**CLAUDE.md / AGENTS.md はコミット対象**

## 9. 次の一手

**タスクの正本は GitHub issue** (https://github.com/takezou621/kilde/issues)。
このファイルに個別タスクを列挙しない (陳腐化するため)。着手順は §8 の依存順と
マイルストーンに従い、M1 仕上げ → M2 → M3 → 配布の順で進める。
M1 の `feature/m1-cli-mvp` は PR #1 で `main` にマージ済み (2026-09-11)。
新しい作業は必ず `origin/main` から issue ごとのブランチを切る (AGENTS.md §2)。
