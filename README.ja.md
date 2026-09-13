[English](README.md) | 日本語

# kilde

[![CI](https://github.com/takezou621/kilde/actions/workflows/ci.yml/badge.svg)](https://github.com/takezou621/kilde/actions/workflows/ci.yml)

macOS 向けの OSS 画面 + 音声 録画ツール。

QuickTime Player の画面収録では録れない**システム音声を含めた録画・録音**を、
ワンコマンドで実現します。CLI ファーストで、その後メニューバーアプリ (GUI)
へ発展させます。

## 特徴

- 🖥️ 画面 + システム音声をゼロセットアップで録画 (ScreenCaptureKit ネイティブ)
- 🎤 マイク・任意の入力デバイス (BlackHole 等) を同時録音
  - 複数ソースを **1 トラックにミックス** (既定) / トラック分離 (`--audio-tracks separate`)
- 🪟 **ウィンドウ単位の収録** — 音声もそのアプリにスコープされ、通知音など
  他アプリの音が入らない
- 🎙️ 録音 (音声のみ) モード (`--no-video`) — ドライバ追加不要
- 🛡️ Ctrl+C でもファイルが必ずファイナライズされる安全な停止
- ⌨️ グローバルホットキーで、他アプリの操作中でも録画を開始 / 停止

## インストールとビルド

- 要件: macOS 14+ (動作検証は macOS 26 / Apple Silicon)

### Homebrew

Homebrew tap は v0.1.0 のリリース後に利用可能になります。公開後は、次のどちらかで
インストールできます。

```sh
brew tap takezou621/kilde
brew install kilde

# tap から直接インストールする場合
brew install takezou621/kilde/kilde
```

Homebrew で最新の `main` ブランチをソースからビルドする場合は `--HEAD` を指定します。

```sh
brew install --HEAD takezou621/kilde/kilde
```

HEAD ビルドには macOS 26 SDK を持つツールチェーン (Xcode 26 以降) が必要です —
`captureHDRRecordingPreservedSDRHDR10` (macOS 26 の API) を参照するため、
**26 未満の SDK (Xcode 15 / 16 の両方) では `has no member` で失敗します**。
実行は引き続き macOS 14+ に対応します。旧 OS ユーザーはリリースバイナリを使ってください。

### ソースからビルド

ソースからのビルドには Swift Package Manager が必要です。

```sh
git clone https://github.com/takezou621/kilde.git
cd kilde
swift build
.build/debug/kilde doctor   # 初回は権限を確認・要求します
```

必要なら PATH に置くと、このあとの例はそのまま動きます:

```sh
ln -sf "$PWD/.build/debug/kilde" /usr/local/bin/kilde
```

- 依存: [swift-argument-parser](https://github.com/apple/swift-argument-parser)
- BlackHole 利用時: `brew install --cask blackhole-2ch`

## 使い方

```sh
# 画面 + システム音声 (既定)
kilde rec demo.mov

# 画面の一部だけを収録 (x,y,w,h のポイント座標、左上が原点)
#   幅・高さは H.264 の制約で偶数に切り捨て。ディスプレイの範囲外は終了コード 1、
#   形式不正や 2 ポイント未満はオプション検証エラー (64)
#   --window / --no-video / --preset meeting とは併用不可
kilde rec --region 0,0,1280,720 demo.mov

# 会議 (Zoom / Google Meet / Teams) を録画 — ウィンドウを選択し、
# 相手の声 + 自分の声を 1 トラックにミックス
kilde rec --preset meeting 会議.mov

# マイクも同時録音
kilde rec --audio system --audio mic out.mov

# 音声のみ (M4A)
kilde rec --no-video memo.m4a

# 特定アプリの音声のみ (他アプリの音・通知音を除外)
kilde rec --no-video --window zoom 会議.m4a

# BlackHole 経由で「聞きながら録音」
kilde rec --no-video --audio "device:BlackHole 2ch" --monitor 会議.m4a

### なぜ BlackHole は必須でないのか

kilde は ScreenCaptureKit のネイティブなシステム音声キャプチャを使うため、
通常の画面・音声録画に仮想オーディオドライバは不要です。BlackHole が必要になるのは、
録音しながら同じ音を聞きたい (monitor モード) といった特殊な経路だけです。

# ターミナルにフォーカスがなくても cmd+shift+r で開始 / 停止
# 待機中の Ctrl+C はファイルを作らず終了 (--countdown との併用は不可)
kilde rec --hotkey cmd+shift+r 会議.mov

# 既定値を設定ファイル (~/.kilde/config.json) で変更
#   KILDE_CONFIG_DIR で config.json と monitor-state.json の保存先を差し替え可能
#   (絶対パスか ~ 始まりのみ。相対パスはエラー)
#   優先順位: CLI 引数 > --preset > KILDE_OUTPUT_DIR > 設定ファイル > 既定値
#   hotkey は --hotkey > 設定 hotkey > 待機モードなし
#   ホットキーは排他登録で、先に登録したプロセスが勝つ (GUI 常駐時は GUI が握る)。
#   取れないとき、設定由来なら警告を出して即時録画へ縮退し、--hotkey 明示なら失敗する
#   不正な設定や存在しない保存先は、録画を始める前にエラー (終了コード 1)
#   rec --fps 0 のような値の誤りはオプション検証エラー (終了コード 64)
kilde config set outputDirectory ~/Movies/kilde
kilde config set defaultAudioSources system,mic
kilde config set showsCursor false   # その回だけ写したいときは kilde rec --cursor
kilde config set hotkey cmd+shift+r  # rec をホットキー待機で起動 (下記の排他に注意)
kilde config show                    # 現在値と既定値 (unset <key> で既定に戻す / path でファイルの場所)

設定キーは `outputDirectory` / `defaultAudioSources` / `audioTracks` / `codec` /
`fps` / `showsCursor` / `hotkey` の 7 種 (英語版 README と同じ一覧)。

kilde devices      # ディスプレイ / ウィンドウ / オーディオ機器の一覧
kilde doctor       # 権限と環境の診断
kilde inspect FILE # 録画ファイルのトラック構成と音声レベル
```

## 開発

- 開発手順 (ビルド・権限・テスト・トラブルシュート): [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- 設計: [docs/DESIGN.md](docs/DESIGN.md) / M0 検証結果: [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- 統合テスト (ローカル・実録画): `scripts/integration-test.sh`
  — 権限と音量が必要、所要 ~2 分

## GUI (M3 開発中)

メニューバーアプリ (`NSStatusItem` + `NSPopover` — macOS 26 で SwiftUI
`MenuBarExtra` の `.window` パネルが開かないため AppKit で手動管理)。
録画エンジンは CLI と同じ
`KildeCore` をローカルパッケージ依存で共有する。`.xcodeproj` はコミットせず
[XcodeGen](https://github.com/yonaskolb/XcodeGen) の `project.yml` から生成する:

```sh
brew install xcodegen   # 初回のみ
cd gui && xcodegen
open KildeGUI.xcodeproj # Xcode で KildeGUI スキームを Run
```

ビルドするとメニューバーに ● アイコンが出る。クリックして収録対象 (画面 /
ウィンドウ / 音声のみ)・音声ソース・保存先を選び「録画開始」。録画中はメニューバーに
経過時間、パネルにソース別のレベルメーターが出る。パネルを閉じても録画は続く。
初期値は CLI と同じ `~/.kilde/config.json` から読む。

録画が終わると、ファイル名・長さ・サイズを通知で知らせる。通知をクリックすると
Finder で該当ファイルを選択表示する。パネルには保存先の直近 5 件が並び (**CLI で
録ったファイルも出る**)、クリックで同じく Finder に表示する。パネルでグローバル
ホットキーを設定すると、他のアプリを使っている間でも開始・停止できる。設定値は
同じ設定ファイルの `hotkey` に入るので、`kilde rec` もそれを見て待機モードで起動する。
ただし**ホットキーは排他登録で、先に登録したプロセスが勝つ** — GUI がログイン時起動で
常駐していると GUI 側が握るので、後から起動した `kilde rec` は警告を出して待機せずに
録画を始める (`--hotkey` を明示したときだけ、縮退せず理由を示して失敗する)。
なお可否の判定は分岐の直前に行うため、その後に別プロセスがキーを奪った場合は
登録エラーで終了する。実際に起きるのは 2 本をほぼ同時に起動したときで、GUI が
握っている場合は判定で捕まえられる。
ログイン時起動のチェックボックスは `SMAppService` で登録する (macOS がシステム設定での
承認を求めることがある)。

## ロードマップ

- **M0** ✅ 技術スパイク (ScreenCaptureKit の音声経路の検証)
- **M1** ✅ CLI MVP (`kilde rec / devices / doctor / audio monitor / inspect`)
- **M2** グローバルホットキー ✅、領域指定の収録 ✅、一時停止/再開
- **M3** メニューバー GUI アプリ (骨格 ✅ / 録画 UI ✅ / 権限オンボーディング ✅ /
  完了通知・最近の録画・グローバルホットキー・ログイン時起動 ✅)

## コントリビューション

バグ報告・機能要望・PR を歓迎します。[CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

## ライセンス

[MIT License](LICENSE)
