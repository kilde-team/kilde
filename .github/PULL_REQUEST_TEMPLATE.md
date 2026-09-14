Closes #

## 要約

<!-- 何を・なぜ変えたか。回避策を入れた場合はその理由も -->

## 受け入れ条件の充足状況

<!-- issue の受け入れ条件を 1 行ずつ。満たせないものは理由を書く -->

| 受け入れ条件 | 状況 |
|---|---|
|  |  |

## 検証

<!-- 実行したコマンドと結果をそのまま貼る (AGENTS.md §3)。
     本リポジトリに Swift パッケージは無い (swift build / swift test は対象外 —
     エンジンのビルド・テストは kilde-team/kilde-cli-swift 側) -->

```
cd gui && xcodegen && xcodebuild -resolvePackageDependencies \
  && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI \
       -configuration Debug build CODE_SIGNING_ALLOWED=NO   # BUILD SUCCEEDED / 失敗理由
```

```
bash -n scripts/release/sign.sh                             # sign.sh を触ったとき
ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")' || false   # release.yml を触ったとき (YAML 検証。壊れていればここで失敗する)
if command -v actionlint >/dev/null; then actionlint .github/workflows/release.yml; fi   # 導入されていれば追加で
```

<!-- 実録画を伴う検証 (GUI セルフテストなど) を行ったなら結果を書く。
     両リポジトリのテストスイートを並行実行しないこと。実行できなかった場合は
     その理由と、レビュアー / 依頼者に確認してほしい手順 (docs/DEVELOPMENT.md §3) を書く -->

## ドキュメント

<!-- 仕様 (配布の契約: pin の揃え方、secrets、zip 名、formula、GUI の挙動) への影響を確認し、
     どちらかを必ず残す (もう一方の行は削除する) -->

- 影響なし (確認した)
- 影響あり — 同じ PR で更新したドキュメント: <!-- RELEASE.md / DEVELOPMENT.md / README など -->
