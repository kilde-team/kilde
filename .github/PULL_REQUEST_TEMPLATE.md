Closes #

## 要約

<!-- 何を・なぜ変えたか。回避策を入れた場合はその理由も -->

## 受け入れ条件の充足状況

<!-- issue の受け入れ条件を 1 行ずつ。満たせないものは理由を書く -->

| 受け入れ条件 | 状況 |
|---|---|
|  |  |

## 検証

<!-- 実行したコマンドと結果をそのまま貼る (AGENTS.md §3) -->

```
swift build   # 警告の増減:
swift test    # Executed … tests, with … failures
```

統合テスト (`scripts/integration-test.sh`、録画・デバイス・権限に関わる変更では必須):

```
PASS=… FAIL=… SKIP=…
```

<!-- 実行できなかった場合は、その理由と、レビュアーに実行してほしい T 番号を書く -->

## ドキュメント

- [ ] 仕様 (CLI の引数・出力・終了コード・既定値) に影響しない
- [ ] 影響するため DESIGN.md / DEVELOPMENT.md / README を同じ PR で更新した
