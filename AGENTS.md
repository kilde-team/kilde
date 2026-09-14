# AGENTS.md — kilde で作業する AI エージェントへの指示

このファイルは Codex CLI をはじめとするコーディングエージェントが、このリポジトリで
作業するときに**毎回自動で従う**ルールです。依頼者は「issue #5 を実装して」のような
短い指示しか出さない前提で、ここに書かれた観点を省略せずに実行してください。

プロダクトの背景・地図・踏んではいけない地雷は [CLAUDE.md](CLAUDE.md) に、
人間向けの GUI ビルド手順は [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) に、
リリース手順は [docs/RELEASE.md](docs/RELEASE.md) に、設計の根拠は
[docs/DESIGN.md](docs/DESIGN.md) / [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
にあります。**作業前に CLAUDE.md §3〜§5 を必ず読むこと。**

このリポジトリは **GUI・リリース配布・ドキュメント** を担う (issue #115 / #118)。
録画エンジン (`KildeCore`) と CLI のソース・テスト・CI は
**[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
(private)** にあり、その運用ルールは同リポジトリの `AGENTS.md` / `CLAUDE.md` が正本。

## 1. 作業の単位は GitHub issue

- 作業は必ず GitHub issue (https://github.com/takezou621/kilde/issues) に紐づける。
  依頼に issue 番号があれば `gh issue view <N>` で本文を読む。番号がなく機能名だけの
  依頼なら `gh issue list --search "<キーワード>"` で該当 issue を探し、見つからなければ
  受け入れ条件を含む issue を先に作ってから着手する
- **録画エンジン / CLI の変更依頼は本リポジトリでは実装しない** —
  kilde-team/kilde-cli-swift 側の issue に切り出す。本リポジトリの issue は
  GUI (`gui/`)、リリース workflow、`scripts/release/`、Homebrew formula、
  ドキュメントが対象
- issue 本文の **背景 / スコープ / 受け入れ条件** がそのまま完了の定義。受け入れ条件を
  すべて満たすまで「完了」と報告しない。満たせない項目があれば理由を PR に書く
- issue のスコープ外の改善を見つけたら、その PR には入れず別 issue を起票する

## 2. ブランチと PR (main への直接 push 禁止)

### 並行開発 — worktree 必須 (バッティング防止。2026-09-11 の合意)

複数の AI セッションが並行して issue を実装する前提で運用する。以下を毎回守る:

1. **着手を宣言してから始める**。他の並行セッションに「issue #N を取る」ことを通知する
   (Claude 間は cross-session メッセージ、人間には着手報告)。
   **すでに誰かが着手を宣言している issue には手を出さない** — 別の issue を選ぶ
2. **1 issue = 1 worktree = 1 ブランチ**。実装は必ず専用 worktree で行う:

   ```sh
   git fetch origin
   git worktree add ../kilde-<issue番号> -b feature/<issue番号>-<slug> origin/main
   cd ../kilde-<issue番号>
   ```

   共有のメイン作業コピー (`~/dev/kilde`) では実装しない — ブランチ切替・
   ビルド成果物 (.build)・権限プロンプトが並行セッションと衝突するため
3. **ファイルの衝突に注意する**。既に出ている PR が触れるファイル
   (例: `gui/project.yml`、`release.yml`) を自分の変更も触れる可能性がある場合は、
   着手宣言と PR 本文の両方に明記する
4. **PR マージ後は後始末する**。後始末は必ずメイン作業コピーに戻ってから行う
   (worktree 内で実行すると、自分の足元のディレクトリを削除してしまう):

   ```sh
   cd ~/dev/kilde                              # メイン作業コピーへ
   git worktree remove ../kilde-<issue番号>   # 未コミットが残る場合は --force を検討
   git switch main && git pull --ff-only      # マージ済み状態をローカル main へ反映
   git branch -d feature/<issue番号>-<slug>   # pull 前だと「not fully merged」で失敗する
   git fetch --prune
   ```

### ブランチと PR の手順

1. ブランチは上記 worktree 作成時に切る
   (`feature/<issue番号>-<slug>`、例: `feature/118-cli-removal-distribution`)。
   既存ブランチが指定された場合はそれに従う
2. コミットメッセージは**英語**・命令形の要約行 (既存履歴に合わせる)。
   コードコメントとドキュメントは**日本語**で、特に回避策は「なぜそうしたか」を書く
3. PR は `gh pr create --base main` で作成する。本文には必ず:
   - `Closes #<issue番号>`
   - 変更の要約と、受け入れ条件ごとの充足状況
   - §3 の検証結果 (実行したコマンドと結果をそのまま貼る)
   - 仕様に影響する変更なら DESIGN.md / DEVELOPMENT.md / RELEASE.md を
     同じ PR で更新した旨
4. PR を作ると cubic と CodeRabbit の AI レビューが自動で走る。指摘は
   `gh api graphql` の reviewThreads で取得し、妥当なものは修正、妥当でないものは
   理由を添えて見送る。すべて処理してから完了報告する。
   - **cubic の指摘は、対応を終えたら修正したものも含めて必ず各レビュー・コメント
     (インラインスレッド) に返信してから resolve する。黙って resolve しない。**
     返信には「妥当 / 妥当でない」の判定と、修正したコミットの SHA または反論・見送りの理由を書く。
     cubic は返信の内容をフィードバックとして受け取るので、判定理由は具体的に書く
   - 全スレッドを処理したら、cubic のレビュー本体への返信として PR にコメントを 1 件投稿し、
     指摘ごとの対応結果 (修正 / 反論 / 見送り + コミット SHA) を一覧にする。
     コメントの冒頭にはレビューの URL (`…/pull/<PR>#pullrequestreview-<ID>`) を書く
   - CodeRabbit の指摘も同じ手順 (スレッドに返信してから resolve) で扱う
   - 修正を push すると cubic が再レビューすることがある。新しい指摘が付いたら同じ手順を繰り返す
   - `cubic.yaml` の `resolve_threads_when_addressed: true` により、cubic は対応済みと判断した
     スレッドを自動で resolve することがある。**自動 resolve されたスレッドにも同じ内容を返信する**
     (resolve 済みでも返信できる)。下の一覧クエリは未解決のみを返すので、`select(.isResolved|not)` を
     外して cubic のスレッドのうち自分の返信がないものも確認する

   ```sh
   # 未解決スレッドの一覧 (id / ファイル / 本文)
   gh api graphql -f query='query{repository(owner:"takezou621",name:"kilde"){pullRequest(number:<PR>){reviewThreads(first:100){nodes{id isResolved path line comments(first:1){nodes{author{login} body}}}}}}}' \
     --jq '.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved|not)'
   # スレッドへの返信 → resolve
   gh api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{id}}}' \
     -f t=<スレッドID> -f b="妥当です。修正しました (<SHA>)。…"
   gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t=<スレッドID>
   # レビュー本体への返信 (対応結果の一覧)
   gh pr comment <PR> --body "…"
   ```
5. `--force` push、`main` への直接コミット、他人のブランチの書き換えはしない

## 3. 変更後に必ず行う検証

このリポジトリには Swift パッケージが無いため、`swift build` / `swift test` は
対象外 (エンジンのビルド・テストは kilde-team/kilde-cli-swift 側)。

```sh
cd gui && xcodegen && xcodebuild -resolvePackageDependencies \
  && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI \
       -configuration Debug build CODE_SIGNING_ALLOWED=NO   # GUI ビルド (既定の検証)
bash -n scripts/release/sign.sh                             # sign.sh を触ったとき
ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")'   # release.yml を触ったとき (YAML 検証)
# 導入されていれば actionlint も通す (未導入なら YAML 検証のみでよい)
if command -v actionlint >/dev/null; then actionlint .github/workflows/release.yml; fi
```

- **録画の挙動に関わる検証 (実録画の統合テスト・GUI セルフテスト) は、
  kilde-team/kilde-cli-swift 側のスイートと並行実行しない**
  (画面収録・マイクの権限とスピーカー音量が衝突する)。実行前に必ず依頼者に宣言し、
  手順は docs/DEVELOPMENT.md §3 (セルフテスト) を使う
- ドキュメントだけの変更なら GUI のビルドは不要。リンク切れと記載の整合を確認する
- release.yml / sign.sh を変えたときは、**タグを打たない workflow_dispatch の dry-run**
  で確認することを依頼者に勧める (手動実行は Release を作らない設計 — docs/RELEASE.md)

## 4. 設計との整合

- **GUI と release workflow の pin は同じ revision を指す** (`gui/project.yml` と
  `release.yml` の `ref:`)。更新するときは同じ PR で必ず揃える (docs/RELEASE.md)。
  片方だけの更新はレビューで差し戻す
- **release workflow は手動実行で Release を作らない** (dry-run 固定)。この設計を
  変えるときは docs/RELEASE.md を同時に更新する
- **成果物名 `kilde-<version>-macos.zip` は Homebrew formula の `url` と結合している**。
  変えるときは `homebrew/Formula/kilde.rb` と tap (takezou621/homebrew-kilde) の
  更新を同じリリースサイクルで揃える
- GUI コードの地雷は CLAUDE.md §5 (`NSStatusItem` + `NSPopover` の手動管理、
  `AppDelegate.shared`、録画モデルの持ち主、audio-input entitlement、kilde-dev 証明書)。
  やむを得ず変える場合は、理由を CLAUDE.md と docs/DEVELOPMENT.md に追記する
- エンジンの地雷と並行性の規約は kilde-team/kilde-cli-swift の `CLAUDE.md` が正本。
  GUI から KildeCore を呼ぶ側の規約 (Recorder を MainActor で包まない、UI フレームワークに
  触る判定は呼び出し側) もそちらに従う
- CLI の終了コード (`0` / `1` / `2` 権限 / `3` デバイス不明) と既定値
  (`--audio system`, `--audio-tracks mixed`, 出力名 `kilde-yyyyMMdd-HHmmss.*`) は
  契約 — **正本は kilde-team/kilde-cli-swift と DESIGN.md §6**。README / DEVELOPMENT.md の
  記載はそちらと一致させ、食い違いを見つけたらこのリポジトリの PR で直す

## 5. 完了報告の形式

作業を終えたら、依頼者に次を簡潔に報告する:

- PR の URL と `Closes #N`
- 受け入れ条件のチェックリスト (満たしたもの / 満たせなかったものと理由)
- 実行した検証コマンドと結果 (GUI ビルドの成否、実録画テストを実施したならその結果)
- AI レビュー指摘の処理結果 (修正 / 反論 / 未対応の件数)
- 依頼者に実機で確認してほしいことがあれば、具体的なコマンド
  (リリース関連の変更なら workflow_dispatch の dry-run と、必要な secrets の設定も伝える)

## 6. 環境の注意

- ビルドと検証は **macOS (Apple Silicon, Xcode 26 SDK)** で行う。
  Linux やヘッドレス環境では GUI のビルドもパッケージ解決も通らない
- GUI は kilde-team/kilde-cli-swift (private) をパッケージ依存で参照するため、
  パッケージ解決には kilde-team メンバーの git 認証が必要
- `gh` は takezou621 アカウントで認証済み。cubic のレビューは
  takezou621 組織で実行される (a23s-inc 組織は使わない)
- 検証に使う音声・録画ファイルはリポジトリにコミットしない
  (セルフテストは `KILDE_GUI_SELFTEST_OUTPUT` で一時ディレクトリへ出せる)
