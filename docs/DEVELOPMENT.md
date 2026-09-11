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
```

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

## 4. 統合テスト

`scripts/integration-test.sh` は CLI を実際に動かして録画し、出力ファイルの
トラック構成と RMS を機械検証します。

```sh
scripts/integration-test.sh
```

**前提条件 (満たさないと失敗します):**

- 画面収録・マイクの権限が付与済み (先に `kilde doctor`)
- **スピーカー音量が 0 / ミュートでない** — 音声シナリオが無音判定になります
- 所要 ~2 分。実行中は画面とスピーカーが占有されます
- テスト中に一時的に既定の出力デバイスが `kilde Monitor` に切り替わります
  (T9)。スクリプトは `trap` で必ず復元しますが、強制終了した場合は
  `kilde audio monitor teardown` を手動で実行してください

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

作業ディレクトリ (録画物とログ) は失敗調査のため削除されず、最後に
パスが表示されます。

テスト用に「自分で音を鳴らすウィンドウ」を持つ最小アプリ
`scripts/soundapp.swift` を同梱しており、スクリプトが自動でコンパイルして使います
(T6–T8 のウィンドウ音声スコープ検証用)。

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
| 既定出力が `kilde Monitor` のまま戻らない | `kilde audio monitor teardown`。状態は `~/.kilde/monitor-state.json` に保存されている |
| サマリの `ミックスできなかった音声バッファ` が 0 でない | 入力デバイスが非対応フォーマット (Float32 以外) を返している。`MicStream.init` の `output.audioSettings` (Float32 / 48k / 2ch) の統一が効いているか |
| mic の first-PTS 差が大きい | マイクを SCK より先に開始しているか (`Recorder.recordAndFinalize()` の順序) |

## 6. 残課題

| # | 内容 | 状態 |
|---|------|------|
| 1 | **S10: 会議アプリ実地検証** (Zoom / Teams / Chrome Meet で `--preset meeting`) | 未実施 — issue #2 |
| 2 | `feature/m1-cli-mvp` を `main` へマージ | 済 (PR #1) |
| 3 | `Tests/KildeCoreTests` の作成 | issue #5 |
| 4 | CI (`.github/workflows`) で `swift build` + 単体テスト | issue #6 |
| 5 | 長時間 (10 分級) の A/V ドリフト測定 | issue #3 |
| 6 | 旧 OS (14/15) での S7 / S8 / S9 挙動の確認 | issue #4 |
| 7 | `LICENSE` (MIT) の追加 | issue #21 |
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
