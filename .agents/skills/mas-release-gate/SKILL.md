---
name: mas-release-gate
description: >-
  Use this skill when archiving, uploading, submitting, or checking the status of
  the Mac App Store (MAS) build of kilde: appstore-spec verification, the
  two-stage apply → wait → submit-only submission, key hygiene (notarization vs
  App Store keys), trademark-free metadata, and judging outcomes by actual ASC state.
---

# MAS 提出ゲート (App Store ランブック)

Mac App Store 版 (KildeGUI-AppStore ターゲット) のアーカイブ → アップロード →
メタデータ反映 → 審査提出 → 状況把握の手順。
正本: [docs/RELEASE.md §7](../../../docs/RELEASE.md) (手順) と
[docs/appstore/](../../../docs/appstore/README.md) (メタデータの文面と素材)。
実行は GitHub Actions の [MAS workflow](../../../.github/workflows/mas.yml)
(既定経路) か、フォールバックの手元 Mac コマンドで行う。

## 1. いつ使うか

- MAS 版のアーカイブ・アップロード (`upload` モード)
- メタデータ (説明 / What's New / キーワード / サブタイトル / スクショ) の反映 (`apply`)
- 審査への提出 (`submit` / `submit-only`)
- 審査結果の確認・リジェクト対応 (`status` モード、mas-watch.yml の起票 issue)

## 2. 手順

1. **spec の生成と検証** — `python3 scripts/release/appstore-spec.py --version <X.Y.Z>
   --build <N>` で spec を生成し、**内容を目視検証してから**進める:
   What's New の `<version>` セクションが metadata/*.md に書いてあること
   (無いと spec 生成がエラーになる)、5 ロケールの文面が揃っていること、
   商標チェック (`docs/appstore/metadata/README.md` の checker。他社商標ヒット 0) を通す
2. **build 番号の決定** — ASC にアップロード済みの最大値より大きい値
   (基準は «前回の提出» ではない — 未提出のアップロード済み build も超える。
   ASC の TestFlight > macOS ビルドで確認)
3. **アーカイブとアップロード** — mas.yml の `mode=upload` (冪等化済み:
   同一 build が既にあれば再利用、`VALID` 化を poll で確認)。アップロードできたかは
   **ASC の実状態**で判定する
4. **メタデータ反映** — `mode=apply`。**提出はしない**
5. **数分待つ** — ASC 側のスクショ asset の処理と build の `VALID` を確認
   (`mode=status`)
6. **提出** — `mode=submit-only` (**スクリーンショットを触らずに**提出)。
   `apply` → 数分待つ → `submit-only` の **2 段階**が正解。`submit` モードの
   «再アップロード → その場で提出» は asset が «処理中» の間
   `Asset is being processed` で拒否され続ける (0.36.0 実測・4 連敗 — issue #529)
7. **提出後の状況把握** — 提出判定は **ASC の実状態**で行う (workflow の job
   success ではなく)。mas-watch.yml が 30 分ごとにポーリングし、リジェクトなら
   Resolution Center へのリンク付き issue を起票する。審査中の版の差し替え手順
   (cancel-submission → 新 build → attach-build → submit) は docs/RELEASE.md §7

## 3. 検証

- アーカイブ内に **Sparkle.framework が無い**こと・**App Sandbox が有効**なことは
  appstore-archive.sh が検証する (スキップしない)
- 提出の成否は ASC API (`mode=status`) か ASC の画面でバージョン状態
  (WAITING_FOR_REVIEW 等) を直接確認する
- 反映後、ストア表示 (iTunes Lookup API) でメタデータが変わったことを確認できる

## 4. 禁止事項

- **MAS 版に Sparkle を混ぜない** — ストア外自己更新の仕組みとして審査で拒否される。
  `import Sparkle` は `#if !APPSTORE` の内側 (CLAUDE.md §5-15)。
  MAS ビルドの DerivedData は必ず分離
- **キーの混線をしない** — notarization 用 `AC_API_KEY*` (sign.sh) と
  App Store 用 `KILDE_ASC_API_KEY*` (appstore-archive.sh) / `ASC_CI_KEY*` (mas.yml
  の secrets) は別物。appstore-archive.sh に `AC_API_KEY*` を export したままの
  シェルで渡すとクラウド署名の権限の無いキーが黙って使われ、
  "Cloud signing permission error" で落ちる (0.5.0 build 6 実測 — CLAUDE.md §5-19)
- **メタデータに他社商標を入れない** (Zoom 等の会議サービス名・BlackHole 等の製品名)。
  Guideline 2.3.7 のリスク — docs/appstore/metadata/README.md §「他社の商標を使わない」
- **審査中 (WAITING_FOR_REVIEW) の版に触らない** — 提出取り下げ (cancel-submission)
  や apply の再実行は、依頼者の明示指示がある場合のみ。二重提出や 409 を作らない
  冪等化 (issue #615) に頼りすぎない
- 提出はエージェント自身が実行し、依頼者へ回さない (AGENTS.md §6)
- `.p8` キーの中身をログや PR に出さない (safety guard が確認を挟む)
