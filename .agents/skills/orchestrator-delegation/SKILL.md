---
name: orchestrator-delegation
description: >-
  Use this skill when the Orchestrator decomposes a kilde task across domains
  (GUI / distribution (direct + MAS) / engine pin / metrics & ops), delegates
  implementation or investigation to workers, writes delegation briefs, and runs
  the final cross-layer integration gate before declaring anything done.
---

# Orchestrator 委任・統括プレイブック (kilde)

高推論モデル (Orchestrator) が判断・設計・最終監査に集中し、実装や調査を
ワーカーへ安全に委任するための運用手順。
正本: [AGENTS.md](../../../AGENTS.md) (§1〜§6 の運用ルール) と
[CLAUDE.md](../../../CLAUDE.md) §3〜§5 (地図と地雷)。本スキルはそれらを**前提**にする —
矛盾するときは正本のほうに従う。

## 1. いつ使うか

- 1 issue を複数の領域に分割して並行作業させるとき (例: pin 更新 + ドキュメント更新)
- ワーカー (サブエージェント / 別セッション) に実装・調査を委任するとき
- ワーカーからの成果物を受け取り、完了判定を下すとき (最終統合ゲート)

単一ファイルの小修正や即答できる調査は委任せず Orchestrator が直接行う。

## 2. ドメイン分割と担当パス

kilde は次の 4 ドメインで構成される。ワーカーごとに**担当パスを非重複**で割る。

| ドメイン | 主な対象パス | 専門領域と正本 |
|---|---|---|
| **GUI** | `gui/Sources/`、`gui/Resources/`、`gui/project.yml` (pin 以外の設定) | SwiftUI/AppKit の地雷は CLAUDE.md §5 (NSStatusItem + NSPopover の手動管理、`AppDelegate.shared`、録画モデルの持ち主、Debug バンドル ID 分離など) |
| **配布 (直接 + MAS)** | `scripts/release/`、`.github/workflows/release.yml` + `mas.yml`、`homebrew/Formula/kilde.rb`、`docs/RELEASE.md`、`docs/appstore/` | 手順の正本は docs/RELEASE.md。配布経路のランブックは `.agents/skills/direct-distribution-gate/` と `.agents/skills/mas-release-gate/` |
| **エンジン pin** | `gui/project.yml` の kilde-cli-swift `exactVersion` + `release.yml` の `ref:` の **対** | 必ず同じ PR で揃える (AGENTS.md §4)。**エンジン本体の変更は本リポジトリでしない** — kilde-team/kilde-cli-swift 側の issue へ切り出す (AGENTS.md §1) |
| **計測・運用** | `docs/metrics.md`、`docs/appstore/metadata/metrics.md`、`docs/release-notes/`、`docs/launch/` | 台帳運用は `.agents/skills/metrics-ledger-ops/`。数字の捏造禁止 |

## 3. 委任ブリーフの必須要素

ワーカーへの指示には必ず次を含める (抜けると作業が規約から外れる):

1. **目的と完了条件** — issue 番号と、issue 本文の受け入れ条件をそのまま引用する
   (`gh issue view <N>` をワーカーに読ませる)。完了条件は AGENTS.md §1 どおり
   受け入れ条件が正
2. **担当パスと禁止パス** — 上の表のどのパスを触るか / 触らないかを明記。
   `CLAUDE.md`・`AGENTS.md`・workflow 定義・`gui/Sources/` を触ってよいかも明示する
   (本リポジトリではドキュメント運用上 CLAUDE.md は変更しないのが原則)
3. **作業場所と開始手順** — AGENTS.md §2 どおり:
   着手宣言 → `git worktree add ../kilde-<N> -b feature/<N>-<slug> origin/main` →
   worktree 内で実装。**メイン作業コピーでは実装しない**。main への直接 push も禁止
4. **該当する拘束ルール** — GUI 変更なら CLAUDE.md §5、配布なら docs/RELEASE.md と
   該当スキル、計測なら docs/metrics.md の定義、ドキュメントは日本語で
   «なぜそうしたか» を書くこと (AGENTS.md §2.2)
5. **期待する検証と返却形式** — AGENTS.md §3 の検証コマンドとその結果、
   変更ファイル一覧、意図しない差分が無いことの確認、残課題・リスク
6. **ファイル衝突の明記** — `gui/project.yml` や `release.yml` を触る変更なら、
   着手宣言と PR 本文の両方にその旨を書く (AGENTS.md §2.3)

## 4. Orchestrator の最終統合ゲート (完了前の必須確認)

**ワーカーの成果物をそのまま完了扱いにしない。** 受け取ったら Orchestrator 自身が
次を点検する:

1. **差分とスコープ確認** — `git status` / `git diff origin/main` で、意図しない
   ファイル (ビルド成果物・録画ファイル・`.env`・一時ディレクトリ) が混入していないか。
   issue のスコープ外の改善が入っていたら別 issue に切り出す (AGENTS.md §1)
2. **層間の整合チェック** — AGENTS.md §4 と §7 (SSoT) の突合:
   - pin を変えた → `gui/project.yml` の `exactVersion` と `release.yml` の `ref:`
     が同じ PR で同じ revision を指すか
   - 配布物名・バージョンを変えた → `homebrew/Formula/kilde.rb` と tap の更新計画があるか
   - リリース手順に影響する変更 → docs/RELEASE.md / docs/DEVELOPMENT.md を
     同じ PR で更新したか
   - ドキュメントのリンク切れは無いか (追加したファイルへの相対パス)
3. **検証の実行** — AGENTS.md §3 の既定コマンドを Orchestrator 自身が再実行する
   (ワーカーの報告だけでは通したことにしない)。ドキュメントのみの変更でも
   リンク切れと記載の整合を確認する
4. **Git 運用の確認** — main への直接コミット / push が無いこと、
   1 issue = 1 ブランチ = 1 PR であること。PR 本文に `Closes #N` と検証結果があること

## 5. 禁止事項

- ワーカーの報告を検証なしに完了扱いにしない (最終責任は Orchestrator にある)
- 同じファイルを複数ワーカーへ同時編集させない (ブリーフにファイル所有権を書く)
- エンジン (kilde-cli-swift) の変更を本リポジトリの PR に混ぜない
- worktree ルールの適用をワーカーに省略させない — ワーカーも AGENTS.md §2 に従う
