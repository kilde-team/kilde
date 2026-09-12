# kilde — macOS 画面 + 音声 録画ツール 設計書

- Version: 0.4 (draft)
- Date: 2026-09-12
- Status: M0 スパイク完了 (結果は [SPIKE-NOTES.md](SPIKE-NOTES.md))。M1 CLI MVP 実装済み —
  v0.4 で §5 / §6 / §10 を M1 実装に追従させた

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
- MOV (映像あり) / M4A (音声のみ) 出力 (H.264 / HEVC / ProRes)、AAC 音声
  (MP4 コンテナは M2 — issue #12)
- Ctrl+C での安全な停止 (ファイルが必ずファイナライズされること)
- デバイス一覧表示、権限診断

### 発展 (M2〜)

- 領域 (矩形) 指定の収録
- ✅ グローバルホットキーでの開始/停止 (`Carbon.HIToolbox`、issue #10)
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
│  swift-argument-parser       │    │  NSStatusItem + NSPopover     │
│  run() で完了まで待つ         │    │  RecordingController (#18)    │
│                              │    │   - AppDelegate が保持し、     │
│                              │    │     events を購読して表示     │
└──────────────┬──────────────┘    └──────────────┬──────────────┘
               │                                  │
               └────────────┬─────────────────────┘
                            ▼
              ┌───────────────────────────────┐
              │  KildeCore (Swift library)     │
              ├───────────────────────────────┤
              │ Recorder (セッションの指揮)     │
              │  - 状態機械・ライフサイクル      │
              │  - start()/stop()/run()/events │
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
- グローバルホットキーは KildeCore の `HotkeyMonitor` が Carbon
  (`RegisterEventHotKey` / `InstallEventHandler`) で排他的に登録する。入力監視や
  アクセシビリティ権限を要求しない。CLI はメイン RunLoop、GUI は AppKit の通常の
  イベントループで、メインスレッドに配送される押下コールバックを受ける。
- **kilde (CLI)**: 引数解析とコンソール出力 (進捗・レベルメーター) のみ。
- **KildeGUI**: 後日 Xcode プロジェクトとして作成し、KildeCore をローカル
  パッケージ依存で取り込む (署名・entitlements のため SPM 単独より容易)。

### RecorderController の状態機械

```
idle → preparing (権限/デバイス確認)
     → armed (カウントダウン, 任意)
     → recording ⇄ paused (一時停止 / 再開 — M2 #11)
     → finalizing (AVAssetWriter の完了待ち)
     → done | error
```

- すべての状態遷移はイベント駆動で、CLI はこれを表示に写像する。
- `finalizing` での失敗 (ディスク満杯等) は `error` に遷移し、部分ファイルの
  有無を明示する。
- **`preparing` / `armed` の途中で停止を要求されたら、その場で畳んで `error` に遷移する**
  (issue #56)。各ステップ (権限確認・monitor セットアップ・対象解決・ストリーム構築) の
  合間に中断点を置き、中断できない処理 (TCC ダイアログ) は停止要求と競走させて
  「待つのをやめる」。録画は 1 フレームも成立していないので `Recorder` は
  `cancelledBeforeRecording` を立て、**CLI はこれを失敗ではなく正常終了 (0) として扱う**
  (§6 — Ctrl+C は正規の停止操作)。writer を作った後で中断するときは
  `cancel(removingOutput:)` で書きかけのファイルを残さない。
  状態は `error` を使い回す — `RecorderState` に `cancelled` を足すと購読側
  (GUI・CLI・テスト) の網羅性に広く波及するため
- `paused` は「保持していて停止ではない」状態。届いたサンプルは捨て、再開時に
  その区間を writer の PTS と mixer のアンカーから同じだけ詰めるので、出力ファイルには
  一時停止区間が残らない。`paused` からも停止でき、その場合は通常どおり `finalizing`
  へ進む (一時停止したまま終了してもファイルは壊れない)。
  一時停止していた合計は `Summary.pausedDuration`、現在の状態は `Progress.isPaused`
  と `stateChanged(.paused)` で購読側に伝わる。

> **実装 (issue #8 / M2):** `Recorder` は状態遷移・進捗・完了・失敗を
> `events: AsyncStream<RecorderEvent>` で配信する。`start()` は非ブロッキングで、
> 同期 `run()` は `start()` の完了待ちラッパとして残している (CLI 互換。
> この経路では progress イベントを流さず、CLI は従来どおり `progress()` を
> ポーリングする)。GUI は `start()` + `events` 購読を使う。

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

- **既定はミックスダウン** (`--audio-tracks mixed`、音声ソースが 2 つ以上のとき):
  KildeCore 自前の `AudioMixer` が全ソースを 1 本のステレオトラックに合成する
  (v0.3 で想定していた `AVAudioEngine` は使っていない)。会議の「相手の声 +
  自分の声」が 1 トラックに入るため、どのプレイヤーでも両方聞こえる。
  - 各ソースの CMSampleBuffer を interleaved Float32 にデコードし、
    48kHz / 2ch に変換する (線形補間リサンプル、mono は両 ch へ展開、3ch 以上は先頭 2ch)
  - **PTS アンカー**: 最初に届いたバッファの PTS を基準に、各バッファを
    アンカー相対のフレーム位置に置く。ギャップは無音で埋め、出力済み範囲と
    重なる部分は捨てる (全体が古いバッファは無視)
  - 全ソースのデータが揃った範囲を 1024 フレームずつ加算し、[-1, 1] にクリップして出力する
  - **遅延ソース**: 最遅ソースが 2 秒以上遅れたら、その区間は無音として先へ進む (ストール防止)
  - **初回データ待ち**: アンカーから 3 秒経っても一度もデータが来ないソースは
    断念 (`abandoned`) し、残りのソースだけで合成する
  - **flush**: 停止時に `flush()` でチャンク境界に満たない末尾 (最大 ~21ms) と
    初回データ待ちで保留されていたデータを吐き切ってから `finish()` する
  - 非数値 PTS のバッファは捨て、デコードできないバッファは `decodeFailures` として
    数えてサマリで警告する
- 音声ソースが 1 つのとき、または `--audio-tracks separate` のときはミキサーを
  通さず、ソースごとのトラックにそのまま書く。
- `--audio-tracks separate` でソースごとのトラック分離 (編集向け)。
  このモードでは一般プレイヤーが先頭トラックしか再生しない点を表示時に注意。

### 録音 (音声のみ) モード (`--no-video`)

- **SCK ネイティブ (既定)**: `.audio` 出力のみを登録した SCStream で音声のみ
  取得 (S8 で実証)。マイクもシステム音声もドライバ追加なしで動作し、
  音は通常どおりスピーカーから聞こえ続ける。`--window` 併用で
  **特定アプリの音声だけ**を録音できる (S9 で実証)。
- **BlackHole 経由 (オプション)**: `--audio device:BlackHole` で従来型
  ループバック。`--monitor` でマルチ出力デバイスの作成/復元を自動化。
- 出力: M4A (AAC)。映像トラックは書かない。

### ライタと A/V 同期

- `AVAssetWriter` (コンテナ: 映像ありは MOV、音声のみは M4A。MP4 は M2 — #12)。
- `startSession(atSourceTime:)` を「最初に到着した映像サンプルの PTS」
  (音声のみモードは最初の音声 PTS) で呼び、アンカーより前の音声 PTS は
  ドロップする (`MovieWriter.Anchor`)。
- 出力する音声トラックごとに「映像との first-PTS 差」を記録し、`rec` のサマリに出す
  (`MovieWriter.firstPTSOffsets` は書き込み先ラベルがキー。mixed では `mixed` トラックの差になる)。
  これが同期の健全性指標で、マイクは起動遅延ぶん +0.3s 前後までを想定内とする
  (マイクを SCStream より先に起動して吸収 — SPIKE-NOTES F-D)。
  長時間録画でのドリフトは `scripts/drift-test.sh` で計測する (手順と結果は SPIKE-NOTES F-E)。
  2026-09-12 の 15 分計測 (BlackHole ループバック) では映像↔音声が最大 −12 ms、
  AVCapture 経路と SCK 経路の差が +0.1 ms (傾き +0.01 ms/分) で、許容の目安 ±40 ms に収まった。
  **実マイクのクロックでの計測は未実施** (検証機に音響経路が無いため — issue #3)。
  補正方式は現時点で不要と判断している。

### 停止の確実性 (最重要 UX)

- SIGINT / SIGTERM / SIGHUP をハンドルし、即座にキャプチャを停止 →
  `finishWriting` を待ってから終了する。**プロセス異常終了時を除き、
  ファイルが壊れた状態で残らないこと**を最優先要件とする。
- `--duration 30s` での自動停止も同じ経路を通る。
- 映像ありモードで停止までに映像を 1 フレームも取得できなかった場合は、空の出力を
  cancel・削除して終了コード 1 で失敗する。ディスプレイの消灯・ロック中に開始すると
  SCK が映像を出さないことがあるため、ファイルのない空振りを成功扱いしない。

## 6. CLI 仕様

M1 実装 (`kilde --help` / `kilde <subcommand> --help`) と一致させている。

```
kilde rec [<出力パス>]                     録画 / 録音の開始 (Ctrl+C で安全に停止)
kilde devices [--no-windows]              ディスプレイ / ウィンドウ / オーディオ機器の一覧
kilde doctor                              権限と環境の診断 (不足していれば権限を要求)
kilde audio monitor [status|setup|teardown]
                                          マルチ出力デバイス "kilde Monitor" の管理 (既定 status)
kilde inspect <file>                      録画ファイルのトラック構成と音声レベル (RMS / peak)
kilde config [show|set|unset|path]        設定ファイル ~/.kilde/config.json の表示・変更 (既定 show)
```

`audio monitor` の操作は位置引数 (`--setup` / `--teardown` 形式ではない)。

### `kilde rec` オプション (M1)

| オプション | 既定 | 説明 |
|-----------|------|------|
| `[<出力パス>]` / `--output, -o <path>` | 自動生成 | 既定 `kilde-yyyyMMdd-HHmmss.mov` (音声のみは `.m4a`)。既定名は原子的に予約し、同名があれば拡張子の前へ `-2`〜`-999` を付けて既存録画を保護する (全て埋まっていれば録画開始前に失敗)。明示パスは従来どおり既存ファイルを上書きする。保存先は `KILDE_OUTPUT_DIR` > 設定 `outputDirectory` > カレントディレクトリ (前二者が存在しないディレクトリなら録画開始前に終了コード 1)。位置引数と `-o` は同時指定不可。`~` は展開する |
| `[<出力パス>]` / `--output, -o <path>` | 自動生成 | 既定 `kilde-yyyyMMdd-HHmmss.mov` (音声のみは `.m4a`)。保存先は `KILDE_OUTPUT_DIR` > 設定 `outputDirectory` > カレントディレクトリ (前二者が存在しないディレクトリなら録画開始前に終了コード 1)。位置引数と `-o` は同時指定不可。`~` は展開する |
| `--display <番号>` | `0` | 収録ディスプレイ (`kilde devices` の番号)。範囲外は終了コード 3。`--window` を 1 つだけ指定したときは無視される (そのウィンドウ単体を収録するため)。**`--window` を複数指定したときは合成先のディスプレイとして効く** — 指定したディスプレイの外にあるウィンドウが混ざっていると、黙って黒く写るのを避けるため録画前に終了コード 1 (M2 — #13)。(`all` は M2 — #12) |
| `--window <windowID\|文字列>` | なし | ウィンドウ単位で収録。windowID の完全一致、またはタイトル / bundleID の部分一致 (大文字小文字を区別しない)。複数ヒット時は面積が最大のもの。見つからなければ終了コード 3。音声もそのアプリにスコープされる。**複数回指定可 (M2 — #13)**: 2 つ以上指定するとそのウィンドウ群をまとめて 1 本に収録する。このとき出力はディスプレイ全体の大きさになり (ウィンドウごとに切り出されるわけではない)、対象外の領域は黒で埋まる |
| `--exclude-app <bundleID>` | なし | ディスプレイ収録から指定アプリを除外する (M2 — #13)。**映像だけでなくそのアプリのシステム音声も出力に入らない** (SCK のフィルタは音声にも適用される — SPIKE-NOTES F-F)。音を出しているアプリ (会議アプリ・ブラウザ等) を除外すると、その音声も失われる点に注意。bundleID の**完全一致** (大文字小文字は区別しない。除外は「写っていないはず」を期待する操作で、取り違えても画面を見るまで気づけないため部分一致にしていない)。複数回指定可。実行中に見つからなければ終了コード 3。`--window` / `--no-video` / `--preset meeting` とは併用不可 (いずれも収録対象を選ぶ指定で、除外と矛盾するため)。`--region` とは併用可 |
| `--region <x,y,w,h>` | なし (ディスプレイ全体) | ディスプレイの一部だけを収録 (ポイント座標、左上が原点 — M2 #9)。H.264 の制約で幅・高さは偶数へ切り捨てる (`sourceRect` も同じ大きさに揃えるので引き伸ばされない)。ディスプレイの範囲外は終了コード 1、形式不正と 2 ポイント未満は 64。`--window` / `--no-video` / `--preset meeting` とは併用不可 (meeting は対話でウィンドウを選ぶため) |
| `--audio <source>` | `system` (設定 `defaultAudioSources`) | `system` / `mic` / `device:<名前 or UID>` / `none`。複数回指定可。`device:` は入力デバイスの UID 完全一致または名前の部分一致。`none` は他ソースと併用不可、`--no-video` とも併用不可 |
| `--audio-tracks <mixed\|separate>` | `mixed` (設定 `audioTracks`) | 音声ソースが複数のとき 1 トラックに合成 (既定) か、ソースごとにトラック分離か |
| `--no-video` | off | 録音 (音声のみ) モード。出力は M4A |
| `--monitor` | off | 録画中だけ "kilde Monitor" を自動 setup し、終了時に teardown する。手動 setup 済みの Monitor には触れない。BlackHole 未導入なら終了コード 3、復元に失敗したら WARNING を出して終了コード 1 |
| `--duration <dur>` | なし | `30` (秒) / `30s` / `5m` / `1h` / `1.5m`。経過で自動停止 (SIGINT と同じ経路) |
| `--codec <c>` | `h264` (設定 `codec`) | `h264` / `hevc` / `prores` |
| `--hdr` | off | HDR で収録する (M2 — #16)。`SCStreamConfiguration` の HDR プリセットを OS で選ぶ (macOS 26 は HDR10 メタデータ付きの `captureHDRRecordingPreservedSDRHDR10`、15 は `captureHDRStreamLocalDisplay`)。HEVC **Main10** + PQ で書き出し、色域はプリセットのバッファに従う (26 は BT.2020、15 は Display P3。マトリクスは色域が P3 でも BT.2020 — SPIKE-NOTES F-H)。`--codec hevc` 以外との併用と `--no-video` との併用は終了コード 64。**macOS 14 以前、または HDR 非対応ディスプレイでは SDR にフォールバックし、理由を結果表示に出す** (黙って SDR にすると「HDR で録れたつもりのファイル」ができるため)。この通知は stdout の `⚠ HDR: …` 行で、**`cleanupWarnings` (stderr の `WARNING:` 行 + 終了コード 1) とは別扱い** — 録画自体は成功しているので**終了コードは 0 のまま**。**macOS 26 では HDR10 メタデータ付きの録画プリセット (`captureHDRRecordingPreservedSDRHDR10`) を使う** — SDR 範囲の見え方を保ち、HDR10 メタデータが付く (issue #76)。どちらの方式で録れたかは結果表示の `HDR: …` 行に出る。CI の SDK の壁はランナーを macos-26 に上げて解消 (PR #81) |
| `--format <mov\|mp4>` | `mov` (M2 — #12) | 映像ありのときの出力コンテナ。**出力パスの拡張子が `.mp4` なら自動で mp4** (明示した `--format` が優先)。MP4 に ProRes は入れられないため、`--format mp4 --codec prores` は終了コード 64 (設定ファイル由来の codec との組合せは 1)。`--no-video` とは併用不可 (音声のみは M4A 固定)。既定の出力名の拡張子もコンテナに従う |
| `--fps <n>` | 指定なし (SCK 既定。設定 `fps`) | 上限フレームレート。1 以上 (0 以下は終了コード 64 — 以前は黙って無視していた) |
| `--cursor` / `--no-cursor` | 写り込む (設定 `showsCursor`) | カーソルを写し込むか。`--cursor` は設定 `showsCursor: false` をその回だけ打ち消す用 (M1 の `--no-cursor` はそのまま使える) |
| `--countdown <sec>` | `0` | 開始前カウントダウン。hotkey (CLI 引数) との併用は引数検証エラー (終了コード 64)、設定 `hotkey` との組合せは終了コード 1 で拒否 — 待機モードではカウントダウンが待機開始前に消費され、録画の開始を守れなくなるため |
| `--preset meeting` | なし | `--audio system --audio mic` + mixed。`--window` 未指定なら on-screen ウィンドウを面積順に列挙して対話選択 (空欄 Enter = ディスプレイ全体)。EOF (非対話実行) と 3 回連続の無効入力は終了コード 1 で中止。明示した `--audio` / `--audio-tracks` はプリセットより優先。プリセットは設定ファイルより優先。`--region` とは併用不可 |
| `--hotkey <key>` | なし (設定 `hotkey`) | `cmd+shift+r` 形式のグローバルホットキーで開始 / 停止。指定時は録画ファイルを作らず待機し、待機中の Ctrl+C は成功 (0) で終了する。録画開始後のホットキーと Ctrl+C はどちらも `Recorder.stop()` で安全に停止する。`--countdown` との併用不可 (上記参照) |

### 設定ファイル (`~/.kilde/config.json`, M2 — #14)

`kilde rec` の既定値を変える。CLI と GUI (M3) で共有するため、読み込みと解決は
KildeCore (`ConfigStore` / `RecordSettings`) にある。値は CLI 引数と同じ文字列表現。
保存先ディレクトリは `KILDE_CONFIG_DIR` で差し替えられる。絶対パスか `~` 始まりのみ
受け付け (`outputDirectory` と同じ基準 — GUI はカレントディレクトリが `/` になるため)、
相対パスは設定・monitor state の読み書き前に終了コード 1 で拒否する。

| キー | 型 | 対応するオプション |
|------|----|------------------|
| `outputDirectory` | 文字列 (絶対パスか `~` 始まり。相対パスは GUI と共有できないため不可) | 出力パス省略時の保存先 |
| `defaultAudioSources` | 文字列の配列 (`["system", "mic"]`、`["none"]` で音声なし) | `--audio` |
| `audioTracks` | `mixed` / `separate` | `--audio-tracks` |
| `codec` | `h264` / `hevc` / `prores` | `--codec` |
| `fps` | 1 以上の整数 | `--fps` |
| `showsCursor` | 真偽値 | `--cursor` / `--no-cursor` |
| `hotkey` | `cmd+shift+r` 形式の文字列 | `--hotkey`。cmd / shift / opt / ctrl と英数字、F1〜F12、主要キーに対応 (fn はハードウェアにインターセプトされるため不可) |

- 優先順位: **CLI 引数 > `--preset` > 環境変数 > 設定ファイル > 既定値**。
  環境変数は `KILDE_OUTPUT_DIR` (録画の保存先) と `KILDE_CONFIG_DIR`
  (`config.json` と `monitor-state.json` の保存先。未設定・空文字なら `~/.kilde`。
  相対パスは不可)。
  環境変数は `KILDE_OUTPUT_DIR` (保存先) のみ。ホットキーは
  **`--hotkey` > 設定 `hotkey` > 待機モードなし** (プリセットと環境変数は関与しない)
- ファイルが無ければすべて既定値。壊れた JSON・未知のキー (typo)・不正値は、黙って既定値に
  倒さず `kilde rec` を録画開始前に終了コード 1 で止める (「設定したのに効かない」を防ぐ)
- `kilde config set <key> <value>` は値を検証してから書く (不正値・未知のキーは終了コード 64)。
  `defaultAudioSources` はカンマ区切り (`kilde config set defaultAudioSources system,mic`)。
  名前にカンマを含むデバイスは JSON 配列 (`'["device:A, B","mic"]'`) で指定し、`show` もその場合だけ
  JSON 配列で表示する (表示をそのまま `set` に戻せる)。
  `kilde config unset <key>` で既定値に戻す。`kilde config show` は未設定の項目に既定値を併記する
- 手編集のファイルも `set` と同じ基準で検証する (値の前後の空白も不正)。`ConfigStore.save()` も
  保存前に検証する (不正値を書くと次回の `kilde rec` が自分の書いたファイルで失敗するため)
- 壊れたファイルに対する `set` / `unset` は、空の設定で上書きせずに失敗する (他の設定を黙って
  失わないため)。手で直すか削除してから再実行する (`kilde config path` で場所を表示)
- 設定と保存先の検証は `--preset meeting` の対話と `--countdown` より前に行う。
  既定の出力名の時刻は、その後の録画開始時点で取り直す

### 使用例

```sh
# 画面 + システム音声 (BlackHole 不要・ゼロセットアップ)
kilde rec demo.mov

# システム音声 + マイク (トラック分離)
kilde rec --audio system --audio mic --audio-tracks separate demo.mov

# BlackHole 経由で「聞きながら録る」
kilde audio monitor setup       # マルチ出力デバイス "kilde Monitor" を作成
kilde rec --audio device:BlackHole demo.mov   # "BlackHole 2ch" に部分一致
kilde audio monitor teardown    # 元の既定出力へ戻す
# (上の 3 行は kilde rec --monitor --audio device:BlackHole demo.mov と同じ)

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

# ターミナルにフォーカスがなくても cmd+shift+r で開始 / 停止
kilde rec --hotkey cmd+shift+r out.mov
```

### コンソール出力

- 録画中: `REC mm:ss | ファイルサイズ | ソース別ピーク` を 0.5 秒ごとに 1 行で更新する。
  映像ありモードで開始から 10 秒間映像フレームが来なければ、消灯・ロックの可能性を
  stderr に 1 回だけ警告する。
  一時停止中 (M2 #11) は先頭が `PAUSED` になり、経過時間は止まる — 一時停止した区間を
  差し引いた値なので、表示が出力ファイルの長さと一致する。
  一時停止 / 再開の操作は `p` キー (端末がある場合) と `SIGUSR1` のどちらでもトグルできる。
- 停止後: 一時停止した合計があれば `一時停止: 合計 N.Ns`、
  映像・音声トラックごとの appended / dropped 件数、映像との first-PTS 差
  (mixed ではトラックが `mixed` の 1 本なのでソース別には出ない)、
  ファイルパスとサイズ、解像度と長さ、音声トラックごとの RMS / peak を出力する。
  ミックスできなかった音声バッファがあれば警告する。
- エラーは stderr に `ERROR: ...`、後始末の失敗 (monitor の復元失敗) は `WARNING: ...`。

### 終了コード

| コード | 意味 |
|-------|------|
| `0` | 成功。**Ctrl+C / SIGTERM / SIGHUP / `--duration` による停止も、ファイナライズが完了すれば 0**。**録画が始まる前 (準備中) の停止も 0** — ファイルは作られず「録画は開始されませんでした」とだけ出す (issue #56) |
| `1` | その他の失敗 (`KilError.failed`: ファイナライズ失敗、映像ありモードの 0 フレーム、monitor の復元失敗、meeting の選択中止など) |
| `2` | 権限不足 (画面収録 / マイク) |
| `3` | デバイス・ウィンドウ・ディスプレイが見つからない (BlackHole 未導入を含む) |
| `64` | 引数・オプションの検証エラー (swift-argument-parser の既定。`validate()` の `ValidationError` と未知のオプション) |

v0.3 までは「`130` 割り込み」としていたが、v0.4 で廃止した。Ctrl+C は kilde の
正規の停止操作であり、ファイルが正常にファイナライズされたのなら成功 (0) として
返す方がスクリプトから扱いやすい。統合テスト T10 がこの挙動 (SIGINT → exit 0 と
再生可能なファイル) を保証する。

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
2. **モニタ維持**: `kilde audio monitor setup` は CoreAudio の
   aggregate device API で「既定出力 + BlackHole」のマルチ出力デバイス
   "kilde Monitor" を作成し既定出力に設定。**非公開の `stacked` フラグが
   必須** (SPIKE-NOTES F-C)。`kilde audio monitor teardown` で作成物を削除し元の既定出力へ復元。
   録音セッション中の自動 setup/teardown (`--monitor` フラグ) もサポート。
3. **録音 (音声のみ) モードでの位置づけ**: SCK ネイティブ経路が確立したため
   BlackHole は必須ではなくなった (S8)。`--audio device:BlackHole` の
   明示指定、旧 OS フォールバック、他ツール連携のためのオプション経路。
4. **アプリ別収録**: アプリ単位の音声分離は SCK 単体では不完全なため、
   BlackHole と (将来の) アプリ別出力ユーティリティの組み合わせで案内する。
   M2 で `excludingApplications` の音声への効きを検証する。

## 9. GUI (M3) 概要

- メニューバー UI: `NSStatusItem` + `NSPopover` を AppDelegate で手動管理、
  中身は SwiftUI (macOS 26 実機で SwiftUI `MenuBarExtra` の `.window` パネルが
  開かないことを切り分け済み — 詳細は issue #17 の PR)。アイコンの状態反映
  (待機/録画中 + 経過時間)。
- ポップオーバー: ディスプレイ・音声ソース選択、Rec/Stop、出力先指定、
  レベルメーター、録音結果の通知 (Finder reveal)。

> **実装 (issue #18):** 録画の状態は AppDelegate が持つ `RecordingController` にあり、
> `Recorder.start()` + `events` を購読して状態・経過時間・ソース別ピークを出す。
> ポップオーバー (`ContentView`) は表示と操作の受け渡しだけなので、閉じても録画は続く。
> 選択 (収録対象・音声ソース・トラック方針・保存先) は KildeCore の `RecordRequest` が
> `RecordSettings.apply()` を通して `RecordOptions` にする — CLI と同じ解決規則・同じ
> `Recorder`。設定ファイルは初期値として読み、「既定にする」を押したときだけ書き戻す
> (GUI の操作で CLI の既定を黙って変えないため)。保存先の既定は `~/Movies`
> (GUI はカレントディレクトリが `/`)。録画中の終了は停止 → ファイナライズを待ってから
> (待たずに終了する猶予は設けない — writer が作られる瞬間は状態イベントから判別できず、
> 未ファイナライズのファイルを残しうるため。準備中に停止が効かない問題は issue #56)。
> ウィンドウ一覧のサムネイルは `DisplayCatalog.windowThumbnails` (SCScreenshotManager)。
>
> **出力名の例外**: 既定名 `kilde-yyyyMMdd-HHmmss.*` は秒までしか持たないため、止めてすぐ
> 録り直すと同じ名前になり、`MovieWriter` が既存ファイルを消してしまう。出力パスを省略した
> 場合 (CLI の `rec` / GUI の `makeOptions` とも) 既定名は **`open(O_CREAT|O_EXCL)` で原子的に
> 予約**され、衝突時は `kilde-yyyyMMdd-HHmmss-2.mov` のように連番 (`-2`〜`-999`) に退避する
> (全て埋まっていれば録画を始めずに失敗する)。予約は 0 バイトのファイルを作り、
> `MovieWriter` は自分が予約したファイルだけを置き換える — GUI と CLI が同じ秒に
> 同じ保存先で始めても、どちらかが他方の録画を消すことはない (issue #59)。
> 明示パス (`--output` / 位置引数) は従来どおり上書きする。
- グローバルホットキー (開始/停止)。CLI と設定 (出力先・既定ソース) を共有
  (`~/.kilde/config.json` と `KildeCore.ConfigStore` / `RecordSettings` — §6、#14 で実装済み)。
- 権限の初回ガイドを GUI で丁寧に出す (CLI の `doctor` と同一ロジック)。

> **実装 (issue #20):** 録画完了は `UNUserNotificationCenter` で通知し、クリックすると
> `NSWorkspace.activateFileViewerSelecting` で Finder に該当ファイルを選択表示する
> (`RecordingNotifier`)。移動・削除されていたら親ディレクトリを開く。
> 通知は macOS 側に残り**アプリを終了して起動し直した後にクリックされうる**ので、
> 対応表 (メモリ) だけに頼らずファイルパスを通知自身の `userInfo` に持たせる。
>
> **許可状態は自前で持たない。** 起動時に 1 回 `requestAuthorization` するだけで、
> 通知を出すときは判定せずに投げる — 未許可なら `add` が黙って捨てるので実害が無く、
> 状態も競合も持たずに済む。一度はキャッシュする実装にしたが、`getNotificationSettings`
> が非同期である以上「短い録画が旗の立つ前に終わって通知が捨てられる」という
> **別の消え方を作るだけ**だった。なお `add` 自体も非同期 (XPC) なので、
> 「録画中にアプリを終了」経路ではプロセスが先に落ちて通知が届かないことがある。
>
> 通知に出す長さは **progress の最終値から取らない** — progress は 0.5 秒周期なので
> 短い録画では 1 度も届かず `00:00` になる。**`.recording` に入った時刻から
> `.finalizing` に入った時刻まで**を測り、`Summary.pausedDuration` を差し引く。
> 起点を `start()` ではなく `.recording` にするのは準備フェーズ (権限確認・デバイス解決・
> ストリーム構築。issue #70 のとおり数秒かかることがある) を長さに混ぜないため、
> 終点を `.finalizing` にするのは writer の finish が収録ではないため。
> 「最近の録画」は保存先を `kilde-` 接頭辞 + `mov`/`mp4`/`m4a` で走査し、更新時刻順に
> 5 件出す。セッション履歴を持たないので **CLI で録ったファイルも同じ一覧に出る**。
> `-o` で別名を付けた録画は拾えないが、補助表示なので取り違えるより取りこぼす方を選ぶ。
>
> ホットキーは CLI と同じ `HotkeyMonitor` / `HotkeySettings.resolve` を使い、設定も同じ
> `hotkey` キーに書く (GUI で設定すると `kilde rec` も待機モードで起動する)。保存前に
> `HotkeyParser` で検証する — 不正な値を書くと CLI が起動時にエラーになり、GUI からも
> 直せなくなるため。**開始可否の判定は `RecordingSetup.startBlockReason` に集約し、
> 開始ボタンとホットキーの両方がそこを通る。** 判定を UI の `disabled` に置くと、
> ボタンを経由しないホットキーが素通りし、**列挙中でも録画を始められる経路ができる** —
> issue #70 で実測したとおり `SCShareableContent` の列挙と録画開始が競合すると両方が
> 無期限にブロックするので、これは実害のある穴になる。
> ログイン時起動は `SMAppService.mainApp`。`.requiresApproval` のときは承認が要る旨を
> 案内する (登録できたのに起動しない、と見えないため)。

> **実装 (issue #19):** 権限の状態は `PermissionsModel` が持ち、判定は CLI の `doctor` と
> 同じ `KildeCore.Permissions` を使う (GUI 側で独自に判定すると、`doctor` が「あり」と言うのに
> GUI が止まる — あるいはその逆 — が起きるため)。**その構成に要る権限だけ**を求める:
> 画面収録は `RecordRequest.usesScreenCapture` (映像あり、またはシステム音声あり)、
> マイクは既定マイクまたは入力デバイスを選んだとき。足りなければ `ContentView` が案内を出し、
> 「録画開始」を無効にする。macOS 15 以降は許可済みの画面収録権限が定期的に再確認されて
> 失効しうる (F4) ため、ポップオーバーを開くたびと**開始の直前**に取り直す (SCK のエラーではなく
> 案内で止めるため)。画面収録の許可はプロセスを再起動するまで `CGPreflightScreenCaptureAccess()`
> に反映されないので、要求後は再起動を促す文面に変える。
>
> **「SCK を使う構成か」の判定は GUI 側に書かない** (issue #72)。`RecordOptions` と
> `RecordRequest` がそれぞれ `usesScreenCapture` を持ち、`Recorder` の権限判定・
> SCStream の構築・`PermissionsModel.needsScreen`・`RecordingSetup.startBlockReason` が
> すべてそこを通る。2 つの型は語彙が違う (`audioSources` と `captureSystemAudio`) ので
> 定義を 1 箇所にはできず、`RecordRequestTests` が全組み合わせで両者の一致を縛っている。
> 集約前は 4 箇所に書き写されており、コメントで「手で揃える」と指示されていた。

## 10. リポジトリ構成と開発プロセス

```
kilde/
├── Package.swift            # SPM: KildeCore (library) + kilde (executable)
├── Sources/
│   ├── KildeCore/           # UI 非依存のコア (CLI / GUI 共用)
│   │   ├── Capture/         # SCStream / AVCaptureSession ラッパ、サンプル変換
│   │   ├── Devices/         # ディスプレイ・ウィンドウ列挙、CoreAudio 機器、kilde Monitor
│   │   ├── Input/           # HotkeyMonitor、ホットキー待機と開始/停止の状態管理
│   │   ├── Recording/       # Recorder (セッションの指揮)、MovieWriter、AudioMixer
│   │   └── Support/         # 権限、エラーと終了コード、ファイル検証、ユーティリティ
│   └── kilde/               # CLI (引数解析と表示のみ) + Info.plist (リンカで埋め込み)
├── Tests/KildeCoreTests/    # 単体テスト (権限不要・CI で実行 — issue #5)
├── scripts/
│   ├── integration-test.sh  # 実録画の統合テスト T1〜T12 (要権限・音量、ローカルのみ)
│   └── soundapp.swift       # 統合テスト用の「音を鳴らすウィンドウ」アプリ
├── gui/                     # M3: メニューバー GUI (XcodeGen project.yml が正本で
│                            #   .xcodeproj は生成物 — 骨格は #17、録画 UI は #18 以降)
├── docs/                    # DESIGN.md / SPIKE-NOTES.md / DEVELOPMENT.md
├── CLAUDE.md / AGENTS.md    # AI エージェント向けの作業指示
└── README.md
```

- v0.3 で予定していた `Tests/SmokeTests/` (要権限の録画スモーク) は
  `scripts/integration-test.sh` に置き換えた (権限が必要なため CI には載せない)。
- Swift 6 相当・SPM。依存は `swift-argument-parser` のみで始める。
- **ローカル統合テスト**: `scripts/integration-test.sh` — 実際に録画・音声再生を
  行い、出力ファイルのトラック構成と RMS を機械検証する (T1〜T12、権限と
  音量が必要、所要 ~2 分)。テスト用の音鳴らしウィンドウアプリ
  (`scripts/soundapp.swift`) を同梱。
  T11 (GUI のビルド・起動・終了) は xcodegen 未導入 / kilde-dev 証明書なし /
  KildeGUI 起動中の環境では SKIP する (docs/DEVELOPMENT.md §4 の T11 参照)。
- CI: GitHub Actions で `swift build` / `swift test` (単体のみ。スモークは
  手動マトリクス)。
- ロードマップ:
  - **M0**: 技術スパイク (§11) — **完了** (SPIKE-NOTES.md)
  - **M1**: CLI MVP (§3 の MVP 範囲) — 実装済み (ミックスダウン、`--monitor` を含む)。
    仕上げ (単体テスト・CI・実地検証) は issue #2〜#7
  - **M2**: Recorder のイベント駆動化、領域指定、ホットキー、一時停止、
    複数ディスプレイ / MP4、アプリ除外、設定ファイル、passthrough、HDR (issue #8〜#16)
  - **M3**: GUI (issue #17〜#20)
  - **配布 & OSS**: LICENSE、英語 README、署名・notarization、Homebrew、Releases (issue #21〜#25)

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

- ライセンス: **MIT** (確定。`LICENSE`。BlackHole は依存として組み込むわけではなく
  ユーザに導入してもらう形なのでライセンス衝突はない)
- README (日英)、CONTRIBUTING (`CONTRIBUTING.md`)、Issue/PR テンプレート (`.github/`)。
- セマンティックなタグ付け + Release Notes。Homebrew tap は別リポジトリ。

---

## 用語

- **SCK / ScreenCaptureKit**: macOS 標準の画面収録フレームワーク。
- **BlackHole**: OSS の仮想オーディオドライバ (ループバック)。出力を入力に
  抜けることでシステム音声を録音可能にする。
- **TCC**: macOS のプライバシー権限機構 (Transparency, Consent, Control)。
- **マルチ出力デバイス**: 複数の出力先に同時に音を出す仮想デバイス。
  「スピーカーで聞きながら BlackHole にも流す」ために使う。
