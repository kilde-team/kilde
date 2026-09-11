# kilde

macOS 向けの OSS 画面 + 音声 録画ツール。

QuickTime Player の画面収録では録れない**システム音声を含めた録画**を、
ワンコマンドで実現します。コア機能は CLI として提供し、その後
メニューバーアプリ (GUI) へ発展させます。

## 特徴 (計画)

- 🖥️ 画面 + システム音声をゼロセットアップで録画 (ScreenCaptureKit ネイティブ)
- 🎤 マイク・任意の入力デバイス (BlackHole 等) との同時録音・トラック分離
- ⌨️ CLI ファースト (`kilde rec demo.mov`)、その後 GUI
- 🛡️ Ctrl+C でもファイルが必ずファイナライズされる安全な停止

## ステータス

🚧 設計フェーズ — [docs/DESIGN.md](docs/DESIGN.md) を参照。

## ライセンス

MIT (予定)
