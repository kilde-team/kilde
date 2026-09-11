# kilde — macOS 画面 + 音声 録画ツール 設計書

- Version: 0.3 (draft)
- Date: 2026-09-11
- Status: M0 スパイク完了 → 結果は [SPIKE-NOTES.md](SPIKE-NOTES.md) を参照

## 1. 背景・目的

macOS 標準の QuickTime Player による画面収録は**システム音声を録音できない**。
既存の回避策は BlackHole (OSS 仮想オーディオドライバ) + Audio MIDI Setup での
マルチ出力デバイス手動構成 + QuickTime/OBS という組み合わせで、手順が煩雑で
ノウハウが必要。

**目的:** 画面 + システム音声 (+ マイク) を「ワンコマンド / ワンクリック」で
録画できる OSS アプリケーションを提供する。

**代表ユースケース (最優先):** Zoom / Google Meet (Chrome) / Microsoft Teams
等の Web 会議の**録画 (映像 + 音声)** と**録音 (音声のみ)**。会議の
「相手の声 (システム音声)」と「自分の声 (マイク)」の両方を、聞きながら・
参加しながら録れることを保証する。

**開発方針:** コア機能を CLI としてまず完成させ、その後同じコアライブラリを
使うメニューバー GUI アプリへ発展させる。

## 2. 前提となる技術的事実

設計の出発点として重要な事実 (詳細は §11 のスパイクで検証する):

| # | 事実 | 設計への影響 |
|---|------|------------|
| F1 | ScreenCaptureKit (macOS 12.3+) は `capturesAudio` により**システム音声を画面と同時に取得できる** (macOS 13+) | システム音声だけなら BlackHole は不要。ゼロセットアップで録画可能 |
| F2 | BlackHole が真価を発揮するのは「モニタしながら録音」「アプリ別ルーティング」「マルチチャンネル」 | BlackHole はオプションとして第一級サポートするが、必須にはしない |
| F3 | 画面収録とマイク入力はそれぞれ TCC 権限 (システム設定のプライバシー) が必要。CLI でも初回はシステムダイアログが出る | `kilde doctor` での権限診断、初回体験の設計が必須 |
| F4 | macOS 15 以降、画面収録権限は定期的に再確認される仕様になった | CLI を恒常的に使う場合の運用への影響を検証が必要 |
| F5 | マイク・BlackHole 等の入力デバイスは `AVCaptureDevice` 経由で `deviceUniqueID` 指定して取得できる | 追加のキャプチャスタックを導入せず AVFoundation で統一 |
| F6 | ~~ScreenCaptureKit は音声のみの取得ができず、映像とセットになる (想定)~~ → **反証された** (S8)。`.audio` 出力のみ登録すれば音声のみ取得可能 | **録音 (音声のみ) モードも BlackHole 不要**。macOS 26 で実証済み (旧 OS は要検証) |
| F7 | macOS 14+ ではアプリ/ウィンドウ単位の収録で「そのアプリの音声のみ」を取得できる | **確定** (S9)。収録対象ウィンドウの音声のみ入り、他アプリの音は完全に除外される。通知音を除いた会議録画・録音がネイティブで可能 |

**音声アーキテクチャの方針 (M0 スパイク後、v0.3 で更新):**

- **すべての基本経路を ScreenCaptureKit ネイティブに統一** (録画・録音両方)。
  システム音声は SCK が受動的にタップするため、音は通常どおりスピーカーから
  鳴り続け (モニタ維持が自動)、ウィンドウ単位なら音声もそのアプリにスコープ
  される (通知音カット)。
- BlackHole はオプション経路: (a) 旧 OS でのフォールバック、
  (b) `--audio device:` での明示的なデバイス録音、(c) 他ツールとの
  ルーティング連携。`--monitor` によるマルチ出力デバイスの自動設定
  (非公開 `stacked` フラグ使用、SPIKE-NOTES F-C) もサポートする。

## 3. スコープ

### MVP (M1 — CLI)

- ディスプレイ全体 / **ウィンドウ単位**の収録 (会議アプリのウィンドウだけ等)
- 音声ソース: システム音声 / マイク / 任意の入力デバイス (BlackHole 等) を選択・併用
- 複数音声ソースを **1 トラックにミックス (既定)** / トラック分離 (オプション)
  — 会議の「相手 + 自分」の声がどのプレイヤーでも両方聞こえる
- **録音 (音声のみ) モード**: SCK ネイティブでドライバ不要。
  `--window` 併用で特定アプリの音声だけを録音 (通知音カット)
- 会議プリセット (`--preset meeting`)
- MOV/MP4/M4A 出力 (H.264 / HEVC)、AAC 音声
- Ctrl+C での安全な停止 (ファイルが必ずファイナライズされること)
- デバイス一覧表示、権限診断

### 発展 (M2〜)

- 領域 (矩形) 指定の収録
- グローバルホットキーでの開始/停止
- 録画の一時停止/再開
- GUI (メニューバーアプリ) (M3)

### Non-goals (当初)

- ライブストリーミング配信 (OBS 領域)
- 動画編集機能
- Windows / Linux 対応
- スクリーンショット (既存 `screencapture` で十分)

## 4. 全体アーキテクチャ

```
┌─────────────────────────────┐    ┌─────────────────────────────┐
│  kilde (CLI)                 │    │  KildeGUI (M3, メニューバー) │
│  swift-argument-parser       │    │  SwiftUI + MenuBarExtra      │
└──────────────┬──────────────┘    └──────────────┬──────────────┘
               │                                  │
               └────────────┬─────────────────────┘
                            ▼
              ┌───────────────────────────────┐
              │  KildeCore (Swift library)     │
              ├───────────────────────────────┤
              │ RecorderController (ファサード) │
              │  - 状態機械・ライフサイクル      │
              ├───────────────┬───────────────┤
              │ CaptureSession│ DeviceCatalog  │
              │  SCStream     │  ディスプレイ   │
              │  AVCapture    │  オーディオ     │
              ├───────────────┼───────────────┤
              │ RecorderWriter│ AudioRouter    │
              │  AVAssetWriter│  BlackHole 検出│
              │               │  モニタ設定     │
              └───────────────┴───────────────┘
```

- **KildeCore**: 純粋な Swift パッケージ (SPM)。CLI/GUI で共用するすべての
  ロジックを持つ。UI に依存しない。
- **kilde (CLI)**: 引数解析とコンソール出力 (進捗・レベルメーター) のみ。
- **KildeGUI**: 後日 Xcode プロジェクトとして作成し、KildeCore をローカル
  パッケージ依存で取り込む (署名・entitlements のため SPM 単独より容易)。

### RecorderController の状態機械

```
idle → preparing (権限/デバイス確認)
     → armed (カウントダウン, 任意)
     → recording
     → finalizing (AVAssetWriter の完了待ち)
     → done | error
```

- すべての状態遷移はイベント駆動で、CLI はこれを表示に写像する。
- `finalizing` での失敗 (ディスク満杯等) は `error` に遷移し、部分ファイルの
  有無を明示する。

## 5. キャプチャパイプライン

### 映像

```
SCShareableContent.current → 対象ディスプレイ選択
SCStream(contentFilter, configuration)
  → SCStreamFrameOutput (CMSampleBuffer)
  → AVAssetWriterInput (H.264 / HEVC / ProRes, 圧縮フィードバックで
     遅延に応じ品質を自動調整)
```

- 設定項目: FPS (既定 60 上限として実測で追従)、カーソル写り込み、
  色空間 (HDR ディスプレイは P10/HLG 対応をスパイクで確認)。
- ディスプレイ単位 / ウィンドウ単位 (`desktopIndependentWindow`) の
  `SCContentFilter` を使い分け。ウィンドウ収録時に音声もそのウィンドウの
  アプリに絞れるかは S9 で検証する (矩形領域指定は M2)。

### 音声

並行して最大 3 系統を持てる:

| ソース | 取得経路 | 備考 |
|--------|---------|------|
| system | SCStream の `capturesAudio` | マイク権限不要 (要検証 F1/F3) |
| mic | `AVCaptureDeviceInput` (内蔵マイク等) | マイク TCC 権限 |
| device:* | `AVCaptureDeviceInput` (`deviceUniqueID` 指定) | BlackHole、USB オーディオ等 |

- **既定はミックスダウン** (`--audio-tracks mixed`): `AVAudioEngine` で全
  ソースを 1 本のステレオトラックに合成する。会議の「相手の声 + 自分の声」が
  1 トラックに入るため、どのプレイヤーでも両方聞こえる。
  SCStream 音声は CMSampleBuffer → AVAudioPCMBuffer 変換してグラフに接入。
- `--audio-tracks separate` でソースごとのトラック分離 (編集向け)。
  このモードでは一般プレイヤーが先頭トラックしか再生しない点を表示時に注意。

### 録音 (音声のみ) モード (`--no-video`)

- **SCK ネイティブ (既定)**: `.audio` 出力のみを登録した SCStream で音声のみ
  取得 (S8 で実証)。マイクもシステム音声もドライバ追加なしで動作し、
  音は通常どおりスピーカーから聞こえ続ける。`--window` / `--match` 併用で
  **特定アプリの音声だけ**を録音できる (S9 で実証)。
- **BlackHole 経由 (オプション)**: `--audio device:BlackHole2ch` で従来型
  ループバック。`--monitor` でマルチ出力デバイスの作成/復元を自動化。
- 出力: M4A (AAC)。映像トラックは書かない。

### ライタと A/V 同期

- `AVAssetWriter` (コンテナ: MOV 既定 / MP4 選択可)。
- `startSession(atSourceTime:)` を「最初に到着した映像サンプルの PTS」で
  呼び、音声はそれ以降の PTS のみ書く。SCStream 系と AVCapture 系は
  クロックが異なるため、**最初の音声 PTS とのオフセットを測定して補正**する
  (長時間録画でのドリルトはスパイクで実測検証 §11)。

### 停止の確実性 (最重要 UX)

- SIGINT / SIGTERM / SIGHUP をハンドルし、即座にキャプチャを停止 →
  `finishWriting` を待ってから終了する。**プロセス異常終了時を除き、
  ファイルが壊れた状態で残らないこと**を最優先要件とする。
- `--duration 30s` での自動停止も同じ経路を通る。

## 6. CLI 仕様

```
kilde rec      録画の開始 (Ctrl+C で停止)
kilde devices  ディスプレイ / オーディオデバイスの一覧
kilde audio    オーディオ設定 (monitor サブコマンド)
kilde doctor   権限・環境の診断
```

### `kilde rec` オプション (M1)

| オプション | 既定 | 説明 |
|-----------|------|------|
| `--display <id\|main\|all>` | `main` | 収録ディスプレイ (`kilde devices` の ID) |
| `--window <id\|名称>` | なし | ウィンドウ単位で収録 (会議アプリのウィンドウ等)。`--display` と排他 |
| `--audio <source>` | `system` | `system` / `mic` / `device:<名前>` / `none`。複数回指定可 |
| `--audio-tracks <mixed\|separate>` | `mixed` | 複数音声ソースをミックス (既定) か トラック分離か |
| `--no-video` | off | 録音 (音声のみ) モード。出力は M4A |
| `--monitor` | off | BlackHole マルチ出力デバイスを録音セッションに紐付けて自動 setup/teardown |
| `--output, -o <path>` | 自動生成 | 既定 `kilde-YYYYMMDD-HHmmss.mov` (音声のみは `.m4a`) |
| `--fps <n>` | 60 (最大) | 上限fps |
| `--codec <c>` | `h264` | `h264` / `hevc` / `prores` |
| `--duration <dur>` | なし | 例 `30s`, `5m` で自動停止 |
| `--cursor / --no-cursor` | 写り込み | カーソルの写り込み |
| `--countdown <sec>` | 0 | 開始前カウントダウン |
| `--preset <p>` | なし | `meeting`: ウィンドウ対話選択 + `--audio system --audio mic` + ミックス |

### 使用例

```sh
# 画面 + システム音声 (BlackHole 不要・ゼロセットアップ)
kilde rec demo.mov

# システム音声 + マイク (トラック分離)
kilde rec --audio system --audio mic demo.mov

# BlackHole 経由で「聞きながら録る」
kilde audio monitor --setup     # マルチ出力デバイス "kilde Monitor" を作成
kilde rec --audio device:BlackHole2ch demo.mov
kilde audio monitor --teardown  # 元の既定出力へ戻す

# 会議 (Zoom / Google Meet / Teams) を録画 — 双方向の声を 1 トラックに
kilde rec --preset meeting 会議.mov
#   (--window で会議ウィンドウを選択 → 音声もそのアプリにスコープ、
#    system + mic + ミックス。通知音は入らない)

# 会議アプリの音声のみ録音 (他アプリの音は除外される)
kilde rec --no-video --window zoom 会議.m4a

# マイクだけで音声録音 (ドライバ不要)
kilde rec --no-video --audio mic メモ.m4a

# 30 秒だけ HEVC で
kilde rec --duration 30s --codec hevc out.mov
```

### コンソール出力

- 録画中: 1 行を更新する形式で「経過時間 / ファイルサイズ / 音声レベル
  メーター」を表示。
- 停止後: パス / 解像度 / fps / 長さ / トラック構成を出力。
- 終了コード: `0` 成功 / `2` 権限不足 / `3` デバイス不明 / `130` 割り込み。

## 7. 権限・セキュリティ・配布

- 初回実行時に画面収録 (システム音声を含む場合も含む、要検証) とマイクの
  TCC ダイアログが出る。`kilde doctor` は状態を確認し、不十分なら
  システム設定の該当画面を開く手順を表示する。
- CLI の配布: GitHub Releases + Homebrew tap (formula)。
  BlackHole 利用者には `brew install --cask blackhole-2ch` を案内
  (アプリ側からの自動インストールは行わない — ドライバ導入の副作用が
  大きいため、明示的なユーザ操作とする)。
- GUI は Hardened Runtime + Notarization を必須とする。公式ビルドのみへの
  案内。CLI も Developer ID 署名を出す (アドホック署名だと TCC の
  再プロンプトが増えるため)。

## 8. BlackHole 連携の詳細 (advanced)

1. **検出**: `kilde devices` で名前/UID から BlackHole 系デバイスを認識し、
   通常デバイスと区別して表示。
2. **モニタ維持**: `kilde audio monitor --setup` は CoreAudio の
   aggregate device API で「既定出力 + BlackHole」のマルチ出力デバイス
   "kilde Monitor" を作成し既定出力に設定。**非公開の `stacked` フラグが
   必須** (SPIKE-NOTES F-C)。`--teardown` で作成物を削除し元の既定出力へ復元。
   録音セッション中の自動 setup/teardown (`--monitor` フラグ) もサポート。
3. **録音 (音声のみ) モードでの位置づけ**: SCK ネイティブ経路が確立したため
   BlackHole は必須ではなくなった (S8)。`--audio device:BlackHole2ch` の
   明示指定、旧 OS フォールバック、他ツール連携のためのオプション経路。
4. **アプリ別収録**: アプリ単位の音声分離は SCK 単体では不完全なため、
   BlackHole と (将来の) アプリ別出力ユーティリティの組み合わせで案内する。
   M2 で `excludingApplications` の音声への効きを検証する。

## 9. GUI (M3) 概要

- SwiftUI `MenuBarExtra`。アイコンの状態反映 (待機/録画中 + 経過時間)。
- ポップオーバー: ディスプレイ・音声ソース選択、Rec/Stop、出力先指定、
  レベルメーター、録音結果の通知 (Finder reveal)。
- グローバルホットキー (開始/停止)。CLI と設定 (出力先・既定ソース) を共有。
- 権限の初回ガイドを GUI で丁寧に出す (CLI の `doctor` と同一ロジック)。

## 10. リポジトリ構成と開発プロセス

```
kilde/
├── Package.swift          # SPM: KildeCore + kilde (CLI)
├── Sources/
│   ├── KildeCore/         # §4 のモジュール群
│   └── kilde/             # CLI エントリポイント
├── Tests/
│   ├── KildeCoreTests/    # 状態機械・設定パース・命名規則等の単体テスト
│   └── SmokeTests/        # 3 秒録画 → ファイル存在/長さ/トラック検証 (要権限)
├── gui/                   # M3: Xcode プロジェクト (KildeCore を参照)
├── docs/DESIGN.md
└── README.md
```

- Swift 6 相当・SPM。依存は `swift-argument-parser` のみで始める。
- **ローカル統合テスト**: `scripts/integration-test.sh` — 実際に録画・音声再生を
  行い、出力ファイルのトラック構成と RMS を機械検証する (T1〜T10、権限と
  音量が必要、所要 ~2 分)。テスト用の音鳴らしウィンドウアプリ
  (`scripts/soundapp.swift`) を同梱。
- CI: GitHub Actions で `swift build` / `swift test` (単体のみ。スモークは
  手動マトリクス)。
- ロードマップ:
  - **M0**: 技術スパイク (§11) — **完了** (SPIKE-NOTES.md)
  - **M1**: CLI MVP (§3 の MVP 範囲)
  - **M2**: ミックスダウン、モニタ自動化、領域指定、ホットキー
  - **M3**: GUI

## 11. M0 スパイク検証リスト (実施済み — 結果の詳細は SPIKE-NOTES.md)

| # | 検証項目 | 確認すること | 結果 |
|---|---------|-------------|------|
| S1 | SCK のシステム音声 | `capturesAudio` で音声トラックが取れるか、必要な権限、サンプリングレート/チャンネル設定 | ✅ |
| S2 | クロック同期 | SCStream 映像/音声と AVCapture 音声の PTS 整合。長時間 (10 分) でのドリフト量 | ✅ (ドリフトは M1 課題) |
| S3 | 書き込み経路 | SCK サーフェス → AVAssetWriter での H.264/HEVC 書き込みと圧縮フィードバックの挙動。`SCRecordingOutput` (macOS 14+) を使うべきかの判断 | ✅ (macOS 26 の注意点あり) |
| S4 | マルチ出力デバイス | CoreAudio aggregate API での "kilde Monitor" 作成/削除/既定切替が安定して行えるか | ✅ (`stacked` フラグ必須) |
| S5 | シグナル処理 | SIGINT 受信時に必ず finishWriting が完了するか (強停止とのタイムアウト協定) | ✅ |
| S6 | 権限の実挙動 | system 音声のみでマイク権限が不要か。macOS 15+ での再プロンプト頻度。未権限時の SCK エラーの形 | ✅ (未許可時の形は未観察) |
| S7 | 環境差異 | 対象 OS (13/14/15/26)、Intel/Apple Silicon での差。最低対応を 14 にできるか | ⚠️ macOS 26 のみ |
| S8 | SCK 音声のみ取得の可否 | `capturesAudio` を映像なしで使えるか。不可なら「録音モードのシステム音声 = BlackHole 必須」が確定する | ✅ **可能だった** |
| S9 | ウィンドウ/アプリ単位の音声 | `SCContentFilter` で単一アプリ/ウィンドウ収録時に**そのアプリの音声のみ**取得できるか (macOS 14+)。可能なら通知音を除いた会議録画・録音が実現でき、録音モードから SCK 経路も生える | ✅ **スコープ有効** |
| S10 | 会議アプリ実地検証 | Zoom / Teams / Chrome (Google Meet) 使用中に (a) マイクを会議アプリと同居して収録できるか (b) システム音声に相手の声が入るか (c) 録音ファイルの音量・同期を実測 | ⏳ 手動検証が残項目 |

| # | 検証項目 | 確認すること |
|---|---------|-------------|
| S1 | SCK のシステム音声 | `capturesAudio` で音声トラックが取れるか、必要な権限、サンプリングレート/チャンネル設定 |
| S2 | クロック同期 | SCStream 映像/音声と AVCapture 音声の PTS 整合。長時間 (10 分) でのドリフト量 |
| S3 | 書き込み経路 | SCK サーフェス → AVAssetWriter での H.264/HEVC 書き込みと圧縮フィードバックの挙動。`SCRecordingOutput` (macOS 14+) を使うべきかの判断 |
| S4 | マルチ出力デバイス | CoreAudio aggregate API での "kilde Monitor" 作成/削除/既定切替が安定して行えるか |
| S5 | シグナル処理 | SIGINT 受信時に必ず finishWriting が完了するか (強停止とのタイムアウト協定) |
| S6 | 権限の実挙動 | system 音声のみでマイク権限が不要か。macOS 15+ での再プロンプト頻度。未権限時の SCK エラーの形 |
| S7 | 環境差異 | 対象 OS (13/14/15/26)、Intel/Apple Silicon での差。最低対応を 14 にできるか |
| S8 | SCK 音声のみ取得の可否 | `capturesAudio` を映像なしで使えるか。不可なら「録音モードのシステム音声 = BlackHole 必須」が確定する |
| S9 | ウィンドウ/アプリ単位の音声 | `SCContentFilter` で単一アプリ/ウィンドウ収録時に**そのアプリの音声のみ**取得できるか (macOS 14+)。可能なら通知音を除いた会議録画・録音が実現でき、録音モードから SCK 経路も生える |
| S10 | 会議アプリ実地検証 | Zoom / Teams / Chrome (Google Meet) 使用中に (a) マイクを会議アプリと同居して収録できるか (b) システム音声に相手の声が入るか (c) 録音ファイルの音量・同期を実測 |

## 12. OSS としての運営

- ライセンス: **MIT 案** (要確定。BlackHole は依存として組み込むわけではなく
  ユーザに導入してもらう形なのでライセンス衝突はない)
- README (日英)、CONTRIBUTING、Issue/PR テンプレート。
- セマンティックなタグ付け + Release Notes。Homebrew tap は別リポジトリ。

---

## 用語

- **SCK / ScreenCaptureKit**: macOS 標準の画面収録フレームワーク。
- **BlackHole**: OSS の仮想オーディオドライバ (ループバック)。出力を入力に
  抜けることでシステム音声を録音可能にする。
- **TCC**: macOS のプライバシー権限機構 (Transparency, Consent, Control)。
- **マルチ出力デバイス**: 複数の出力先に同時に音を出す仮想デバイス。
  「スピーカーで聞きながら BlackHole にも流す」ために使う。
