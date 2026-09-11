# kilde へのコントリビューション

kilde に興味を持っていただきありがとうございます。バグ報告・機能要望・PR を歓迎します。

このファイルは入口の要約です。詳細な手順は次のドキュメントが正本です
(内容が食い違った場合はそちらを優先してください)。

- ビルド・権限・テスト・トラブルシュート: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- ブランチ / PR / レビュー対応の運用ルール: [AGENTS.md](AGENTS.md)
- 設計と、その根拠になった検証結果: [docs/DESIGN.md](docs/DESIGN.md) / [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)

## issue を立てる

- **バグ報告**: macOS のバージョン、チップ (Apple Silicon / Intel)、`kilde doctor` の出力、
  再現コマンドを添えてください。テンプレートに必須項目としてまとめてあります。
  録画の不具合は OS バージョンと権限 (TCC) の状態で挙動が大きく変わるため、これらの情報がないと
  原因を絞り込めません
- **機能要望**: 用途 (どんな場面で何を録りたいか) を書いてください
- 作業はすべて issue 単位で進めます。PR を出す前に対応する issue があるか確認し、
  なければ先に issue を立ててください

## 開発環境

- macOS 14 以降 (動作検証は macOS 26 / Apple Silicon で行っています)
- Xcode (Swift 5.10 以降のツールチェーン)
- Linux などの macOS 以外の環境では `swift build` も通りません (ScreenCaptureKit などの macOS SDK が必要)

```sh
swift build                    # バイナリは .build/debug/kilde
.build/debug/kilde doctor      # 初回は権限の確認と要求
swift test                     # 単体テスト (権限不要・ヘッドレス)
scripts/integration-test.sh    # 統合テスト (実際に録画する)
```

### 統合テストの前提

`scripts/integration-test.sh` (T1〜T10) は実際に録画・録音して出力ファイルを検証するため、
次の条件を満たさないと失敗します。詳細は [docs/DEVELOPMENT.md §4](docs/DEVELOPMENT.md#4-統合テスト) を参照してください。

- ターミナル (または実行するアプリ) に**画面収録とマイクの権限**が付与されていること
- **スピーカー音量が 0 でない・ミュートでない**こと (音声シナリオが無音と判定されます)
- 所要時間は約 2 分。実行中は画面とスピーカーが占有されます

権限が必要なため、統合テストは CI では実行しません。CI (`swift build` + `swift test`) は PR ごとに自動で走ります。
**録画・デバイス・権限に関わる変更では、統合テストをローカルで実行し、その結果を PR に貼ってください。**
実行できない場合は、その旨と未実施の T 番号を PR に書いてください。

## ブランチと PR

詳細は [AGENTS.md §2](AGENTS.md#2-ブランチと-pr-main-への直接-push-禁止) を参照してください。要点は次のとおりです。

1. `origin/main` から `feature/<issue番号>-<slug>` ブランチを切る (例: `feature/5-unit-tests`)
2. コミットメッセージは**英語**で、命令形の要約行にする (既存の履歴に合わせる)
3. ドキュメントとコードコメントは**日本語**で書く。macOS 固有の回避策には**「なぜそうしたか」**を必ず残す
   (理由のない回避策は後から消されて、同じ不具合が再発するため)
4. PR は `main` 向けに作成し、テンプレートに沿って `Closes #<issue番号>`、受け入れ条件の充足状況、
   検証結果 (実行したコマンドと出力) を書く
5. `main` への直接 push と `--force` push はしない

### 変えてはいけない契約

終了コード (`0` 成功 / `1` 失敗 / `2` 権限不足 / `3` デバイス・ウィンドウ不明、オプション検証エラーは `64`) と、
既定値 (`--audio system`、`--audio-tracks mixed`、出力名 `kilde-yyyyMMdd-HHmmss.*`) はスクリプトから
利用される契約です。変更する場合は [docs/DESIGN.md §6](docs/DESIGN.md#6-cli-仕様) を同じ PR で更新してください。

## AI レビュー (cubic / CodeRabbit)

PR を作ると cubic と CodeRabbit の AI レビューが自動で走ります。

- 指摘ごとに妥当性を判断し、妥当なものは修正、妥当でないものは理由を添えて見送ります
- **対応したら、修正したものも含めて各指摘スレッドに返信してから resolve してください。**
  返信には「妥当 / 妥当でない」の判定と、修正コミットの SHA または見送りの理由を書きます。
  黙って resolve しないでください (cubic は返信内容を学習のフィードバックとして使います)
- すべて処理したら、対応結果の一覧を PR にコメントします

具体的な `gh api graphql` のコマンドは [AGENTS.md §2](AGENTS.md#2-ブランチと-pr-main-への直接-push-禁止) にあります。

## ライセンス

コントリビューションは [MIT License](LICENSE) のもとで提供されるものとします。
