---
name: direct-distribution-gate
description: >-
  Use this skill when preparing and shipping the direct-distribution (Developer ID)
  release of kilde: signing, notarization, Sparkle appcast, v* tag-driven release
  workflow, and the Homebrew formula/tap update PR — including how this path
  differs from the MAS path.
---

# 直接配布ゲート (Developer ID / Sparkle / Homebrew ランブック)

直接配布版 (Developer ID 署名 + notarization + Sparkle 自動更新 + Homebrew tap) の
リリース手順。正本: [docs/RELEASE.md](../../../docs/RELEASE.md) §1〜§6 と
「GitHub でのリリース自動化」/「CLI ソースの pin の更新」/「Homebrew tap の更新」。
起動は [.github/workflows/release.yml](../../../.github/workflows/release.yml)
(`v*` タグの push)。

## 1. いつ使うか

- `v*` タグによるリリースの実施・見送り判断
- 署名・notarization の手元検証 (`sign.sh`)
- リリース後の Homebrew formula 更新
- pin 更新 (エンジンタグの引き上げ) を含むリリース準備

## 2. 手順

1. **リリースノートを書く** — `docs/release-notes/v<VERSION>.md` (issue #283)。
   この 1 ファイルが Release 本文と appcast の更新ダイアログを両方供給する。
   **空ファイルはリリースを止める** (変換スクリプトが失敗する)。書き方は
   docs/release-notes/README.md
2. **pin の整合** — `gui/project.yml` の kilde-cli-swift `exactVersion` と
   `release.yml` の `ref:` が同じ revision を指すこと (AGENTS.md §4)。
   更新は必ず同じ PR で行い、履歴は project.yml のコメントに積む
3. **タグを打つ** — `git tag v<X.Y.Z> && git push origin v<X.Y.Z>`。
   バージョンの真実の源はこのタグ (ビルド時に Info.plist へ差し込まれる)
4. **workflow の完了確認** — 署名 secrets が不足しているとジョブは**失敗する**
   (unsigned フォールバックは廃止)。`SPARKLE_ED25519_PRIVATE_KEY` 無しでも
   appcast 生成の前で失敗する
5. **成果物の検証** — Release に upload した後、**ダウンロードした** DMG でも
   docs/RELEASE.md §6 と同じ 3 検査を繰り返す (issue #216 — upload で staple が
   失われる事故の再発防止。期待値は `accepted source=Notarized Developer ID`)。
   **Release 資産は専用のディレクトリへダウンロードし、そのパスを 3 コマンドに
   渡す** — `dist/` のローカルビルド物を検査しても upload 後の staple 欠落は
   検出できない:

   ```sh
   DMG="$HOME/Downloads/kilde-release/KildeGUI-0.48.0.dmg"   # ← ダウンロードした DMG の実パスに置き換える
   codesign --verify --strict --verbose=2 "$DMG"
   spctl --assess --type open --context context:primary-signature -vv "$DMG"
   xcrun stapler validate "$DMG"
   ```

   CLI zip も展開して `codesign --verify --strict --verbose=2 kilde` と
   `codesign -d --entitlements :- kilde` を確認し、別 macOS ユーザー環境で
   Gatekeeper / TCC を確認
6. **Homebrew tap の更新** — `homebrew/Formula/kilde.rb` (正本) の `url` と
   `sha256` を `shasum -a 256 kilde-<version>-macos.zip` で更新し、同じ内容を
   kilde-team/homebrew-kilde の PR として反映。反映後
   `brew upgrade kilde-team/kilde/kilde` で `kilde --version` を確認
   (`depends_on arch: :arm64` の行は消さない)

## 3. MAS 経路との差分 (混ぜない)

| 項目 | 直接配布 (本スキル) | MAS (`.agents/skills/mas-release-gate/`) |
|---|---|---|
| 署名 | Developer ID Application + Hardened Runtime | Apple Distribution (自動作成) + App Sandbox |
| 更新 | Sparkle 2 (appcast + EdDSA) | 無し (**Sparkle 禁止**) |
| キー | `AC_API_KEY*` (notarization) | `KILDE_ASC_API_KEY*` / `ASC_CI_KEY*` (混線禁止 — CLAUDE.md §5-19) |
| Pro の扱い | **Pro 無料開放** — 購入 UI が存在せず `pro_*` イベントも MAS 版のみ発火 (docs/metrics.md)。IAP 台帳の分子に直接配布は乗らない | kilde.pro / チップ IAP で収益化 |
| App Group | 不要 (非サンドボックス) | 必須 (`4B873Q67MK.kilde` — 録画の排他ロック) |
| バージョン揃え | `v*` タグがリリースの起点 | MAS 版はバージョン番号を直接配布に揃える提出をする (0.9.0 前例) |
| 計測 | `distribution_channel=direct`。CLI/Homebrew チャネルは計測されない (zip DL 数が代理指標) | `distribution_channel=mas`。評価数・IAP は MAS のみ |

## 4. 検証

- workflow がジョブ成功し、Release に zip (+DMG) と appcast があること。
  **appcast 無しのリリースが latest になると全ユーザーの更新チェックが 404 で壊れる**
  (SUFeedURL は latest 固定) — workflow は appcast が無いと失敗する設計
- `sparkle:version` (= `CFBundleVersion`) が前回より大きいこと (workflow が
  `GITHUB_RUN_NUMBER` を差し込む。手差しのリリースでは必ず大きくする)
- tap 更新後の `brew install` / `brew upgrade` の動作確認

## 5. 禁止事項

- unsigned / 署名無しリリースを作らない (secrets 不足はジョブを失敗させる —
  フォールバックを戻さない)
- EdDSA 署名を staple の前に打たない (staple が DMG を書き換えるため Sparkle が
  検証に失敗する — CLAUDE.md §5-12。sign.sh の順序を変えるときは理由を書く)
- 証明書・秘密鍵 (.p12 / .p8) をリポジトリへコミットしない、ログに出さない
- 手動実行 (workflow_dispatch) で Release を作ろうとしない (常に dry-run —
  設計を変えるときは docs/RELEASE.md を同時に更新する)
- appcast のリリースノートに `sparkle:releaseNotesLink` (GitHub ページへの誘導) を
  戻さない (v0.8.1 までの失敗 — 更新ダイアログが GitHub UI 全体を読み込む)
