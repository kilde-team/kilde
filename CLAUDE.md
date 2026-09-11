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
| 統合テスト | `scripts/integration-test.sh` (T1–T10)。ローカル実録画、全 PASS 実績あり |
| 単体テスト (`Tests/`) | **未作成** — issue #5 |
| CI (`.github/`) | **未作成** — issue #6 |
| GUI (`gui/`) | **未作成** — M3 (issue #17〜#20) |
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
  Info.plist               リンカで実行ファイルに埋め込む (§5 参照)
Sources/KildeCore/       UI 非依存のコア。将来 GUI と共用する
  Recording/Recorder.swift     セッションの指揮 (RecordOptions → 実行 → Summary)
  Recording/MovieWriter.swift  AVAssetWriter ラッパ。PTS アンカーとカウンタ
  Recording/AudioMixer.swift   複数ソース → 48kHz/2ch 1 トラック合成
  Capture/ScreenAudioStream.swift  SCStream ラッパ (.screen / .audio)
  Capture/MicStream.swift          AVCaptureSession ラッパ (マイク / 任意入力デバイス)
  Capture/AudioConversion.swift    CMSampleBuffer → interleaved Float32
  Devices/DisplayCatalog.swift     SCShareableContent 列挙・ウィンドウ解決
  Devices/AudioDeviceCatalog.swift CoreAudio HAL + MonitorDevice (マルチ出力デバイス)
  Support/Permissions.swift        TCC 権限の確認・要求
  Support/FileInspection.swift     出力ファイルの検証 (inspect / 統合テストが使用)
  Support/Errors.swift             KilError → 終了コード
  Support/{AsyncUtil,Misc}.swift   awaitSync (同期コンテキスト専用・noasync) / parseDuration / 出力名生成
scripts/integration-test.sh  T1–T10 の実録画テスト
scripts/soundapp.swift       テスト用「音を鳴らすウィンドウ」アプリ
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
```

`rec` の主なオプション: `--display` / `--window` / `--audio`(複数可) /
`--audio-tracks mixed|separate` / `--no-video` / `--monitor` / `--output,-o` /
`--duration` / `--codec h264|hevc|prores` / `--fps` / `--no-cursor` /
`--countdown` / `--preset meeting`

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
7 は `Package.swift` の `linkerSettings` とコミット `11768a9` が出典。

1. **`cfg.pixelFormat = kCVPixelFormatType_32BGRA` を外さない。**
   SCK は既定で圧縮済みフレームを返すため、AVAssetWriter で再圧縮する現構成では
   非圧縮を明示的に要求する必要がある
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
