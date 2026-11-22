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
5. **数分待つ** — **スクショ asset の処理状態は ASC のバージョン画面
   (バージョン > App Store のスクリーンショット) で目視確認する**
   (`mode=status` はバージョン・build・提出の状態を見るもので、スクショ asset の
   «処理中» は見えない)。build の `VALID` 化は `mode=status` で確認
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
- **キーの変数名を混ぜない** — notarization 用 `AC_API_KEY*` (sign.sh) と
  App Store 用 `KILDE_ASC_API_KEY*` (appstore-archive.sh) / `ASC_CI_KEY*` (mas.yml
  の secrets) は別物。同名 (`AC_API_KEY*`) を appstore-archive.sh も読んでいた頃は
  notarization 用キーが黙って使われ、アーカイブ後のエクスポートが
  "Cloud signing permission error" で落ちた (0.5.0 build 6 実測 — CLAUDE.md §5-19)。
  **現行の appstore-archive.sh は `AC_API_KEY*` を読まず、設定されていれば
  «使わない» 注意ログを出す** — エクスポートが失敗したときの原因候補は
  キーの権限 (クラウド署名は Admin) と Xcode の Apple ID サインイン切れで、
  «混線» は現行では起きない。だからといって変数名を sign.sh と «揃える» 方向に
  戻さない (事故の再現になる)
- **メタデータに他社商標を入れない** (Zoom 等の会議サービス名・BlackHole 等の製品名)。
  Guideline 2.3.7 のリスク — docs/appstore/metadata/README.md §「他社の商標を使わない」
- **審査中 (WAITING_FOR_REVIEW) の版に触らない** — 提出取り下げ (cancel-submission)
  や apply の再実行は、依頼者の明示指示がある場合のみ。二重提出や 409 を作らない
  冪等化 (issue #615) に頼りすぎない
- 提出はエージェント自身が実行し、依頼者へ回さない (AGENTS.md §6)
- `.p8` キーの中身をログや PR に出さない (safety guard が確認を挟む)
