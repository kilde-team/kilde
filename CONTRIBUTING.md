# kilde へのコントリビューション

kilde に興味を持っていただきありがとうございます。バグ報告・機能要望・PR を歓迎します。

プロジェクトは 2 リポジトリに分かれています (issue #115):

- **本リポジトリ (takezou621/kilde, public)** — メニューバーアプリ (`gui/`)、
  リリース署名と配布 (workflow・Homebrew formula)、ドキュメント
- **[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
  (private)** — 録画エンジン (`KildeCore`) と `kilde` CLI のソース。テストと CI も
  同リポジトリが正本です

このファイルは入口の要約です。詳細な手順は次のドキュメントが正本です
(内容が食い違った場合はそちらを優先してください)。

- GUI のビルド・権限・トラブルシュート: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- リリースと配布: [docs/RELEASE.md](docs/RELEASE.md)
- ブランチ / PR / レビュー対応の運用ルール: [AGENTS.md](AGENTS.md)
- 設計と、その根拠になった検証結果: [docs/DESIGN.md](docs/DESIGN.md) / [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)

## issue を立てる

- **バグ報告**: macOS のバージョン、チップ (Apple Silicon / Intel)、`kilde doctor` の出力、
  再現コマンドを添えてください。テンプレートに必須項目としてまとめてあります。
  録画の不具合は OS バージョンと権限 (TCC) の状態で挙動が大きく変わるため、これらの情報がないと
  原因を絞り込めません
  - CLI / エンジンの不具合 (録画の挙動、オプション、終了コードなど) は
    kilde-team/kilde-cli-swift 側の issue で管理します
- **機能要望**: 用途 (どんな場面で何を録りたいか) を書いてください
- 作業はすべて issue 単位で進めます。PR を出す前に対応する issue があるか確認し、
  なければ先に issue を立ててください

## 開発環境

- macOS 14 以降 (動作検証は macOS 26 / Apple Silicon で行っています)
- Xcode (macOS 26 SDK を持つツールチェーン) と [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- GUI は kilde-team/kilde-cli-swift を **revision 固定**のパッケージ依存で参照します。
  private リポジトリのため、パッケージ解決には kilde-team メンバーの git 認証が必要です

```sh
brew install xcodegen      # 初回のみ
cd gui && xcodegen         # .xcodeproj を生成 (コミットしない)
open KildeGUI.xcodeproj    # KildeGUI スキームを Run
```

エンジンと CLI (`KildeCore` / `kilde`) のビルド・単体テスト・統合テストは
kilde-team/kilde-cli-swift 側で行います (手順は同リポジトリのドキュメントを参照)。

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

CLI の終了コード (`0` 成功 / `1` 失敗 / `2` 権限不足 / `3` デバイス・ウィンドウ不明、
オプション検証エラーは `64`) と、既定値 (`--audio system`、`--audio-tracks mixed`、
出力名 `kilde-yyyyMMdd-HHmmss.*`) はスクリプトから利用される契約です。これらの正本は
kilde-team/kilde-cli-swift 側にあり、変更する場合は同リポジトリと
[docs/DESIGN.md §6](docs/DESIGN.md#6-cli-仕様) を揃えて更新してください。

リリース周りの契約もあります: GUI と release workflow は kilde-cli-swift の **同じ
revision を参照する** (gui/project.yml の pin と release.yml の `ref`)。pin を更新するときは
両方を同じ PR で揃え、手順は [docs/RELEASE.md](docs/RELEASE.md) を参照してください。

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
