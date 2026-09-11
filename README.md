# kilde

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

## ビルドと実行

```sh
git clone https://github.com/takezou621/kilde.git
cd kilde
swift build
.build/debug/kilde doctor   # 初回は権限を確認・要求します
```

- 要件: macOS 14+ (動作検証は macOS 26 / Apple Silicon)
- 依存: [swift-argument-parser](https://github.com/apple/swift-argument-parser)
- BlackHole 利用時: `brew install --cask blackhole-2ch`

## 使い方

```sh
# 画面 + システム音声 (既定)
kilde rec demo.mov

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

kilde devices      # ディスプレイ / ウィンドウ / オーディオ機器の一覧
kilde doctor       # 権限と環境の診断
kilde inspect FILE # 録画ファイルのトラック構成と音声レベル
```

## 開発

- 開発手順 (ビルド・権限・テスト・トラブルシュート): [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- 設計: [docs/DESIGN.md](docs/DESIGN.md) / M0 検証結果: [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- 統合テスト (ローカル・実録画): `scripts/integration-test.sh`
  — 権限と音量が必要、所要 ~2 分

## ロードマップ

- **M0** ✅ 技術スパイク (ScreenCaptureKit の音声経路の検証)
- **M1** ✅ CLI MVP (`kilde rec / devices / doctor / audio monitor / inspect`)
- **M2** 領域指定の収録、グローバルホットキー、一時停止/再開
- **M3** メニューバー GUI アプリ

## ライセンス

MIT (予定)
