# ローンチ素材 (issue #157)

Show HN / r/macapps / Product Hunt への投稿に使う文案と素材の一式。
**投稿は人間が行う** (各アカウントでの操作)。このファイルは Runbook、
文案は [show-hn.md](show-hn.md) / [reddit-macapps.md](reddit-macapps.md) /
[product-hunt.md](product-hunt.md)、想定質問への回答は
[faq.md](faq.md)、投稿後の計測台帳は [metrics.md](metrics.md)。

## そろっている素材 / 足りない素材

| 素材 | 場所 | 状態 |
|---|---|---|
| 投稿文案 (3 媒体) | このディレクトリ | ✅ 本 PR で作成 |
| 想定質問への回答 | [faq.md](faq.md) | ✅ 本 PR で作成 (投稿時は最新の実態で読み替えること) |
| スクリーンショット 6 枚 (2880×1800) | `docs/appstore/screenshots/` | ✅ 既存 (#266 で再生成したもの) |
| アプリアイコン | `docs/appstore/icon/` | ✅ 既存 (SVG) |
| デモ動画 (60 秒) | — | ❌ **kilde-team/kilde-site#1 の素材待ち**。Product Hunt ではほぼ必須、Show HN では本文の最初に貼ると反応が伸びる。揃うまで投稿しない判断も可 |

Product Hunt のギャラリーは **縦横比 16:9 推奨 (最低 1270×760)**。既存スクショは
16:10 (2880×1800) のため、そのまま貼ると左右が余白になる — PH 投稿前に
16:9 へのクロップ or パディングを行うこと (投稿者の人間が実施)。

## 文面のルール

- **事実の正本は README.md / PRIVACY.md / docs/DESIGN.md**。文案はここから
  持ってきた主張だけを書く。数値 (ユーザー数・スター数) を実績として書かない
- **他社の商標を訴求に使わない** (#160 の App Store メタデータと同じ方針)。
  比較は «機能の事実» として述べる («QuickTime Player の画面収録は
  システム音声を録れない» のような技術的事実は OK — README もこの書き方)
- **将来の価格・ライセンスを保証しない** («永久無料» «ずっと OSS» は書かない —
  収益化方針は #168 で未決定。現時点の事実 «無料で使える» のみ)
- 録画の同意: 会議録音を勧める文面の近くには、README 冒頭の
  «Recording consent is your responsibility» 相当の注意を 1 行入れる
  (Reddit 本文には入れてある)

## 投稿の順序とタイミング (目安)

1. **Show HN を先に** (火〜木の米東岸朝 7〜10 時が定説)。土日の投稿は埋まりやすい
2. **r/macapps は Show HN の反応を見てから** (開発者投稿は約 30 日に 1 度の制限が
   あるため 1 発しかない。投稿直前にサブのサイドバーで最新ルールを確認)
3. **Product Hunt は最後** (火曜 00:01 PT 開始が伝統。ギャラリー・メーカー
   コメント・初動の返信体制を整えてから)
4. **同週に詰めない** — 媒体ごとの効果が計測できなくなる。目安は 1 週間間隔

各媒体のルールは変更されることがある。**投稿直前に必ず再確認**:
- Show HN: https://news.ycombinator.com/showhn.html (自己宣伝・質疑応答の作法)
- r/macapps: https://www.reddit.com/r/macapps/wiki/index (開発者投稿の頻度制限・
  フレア。確認した時点の認識: 開発者投稿は約 30 日に 1 度、2026-09 調査)
- Product Hunt: https://www.help.producthunt.com/en/ (起動日の準備チェックリスト)

## 投稿後 1 週間の計測

[metrics.md](metrics.md) の台帳に記入する。取り方:

- **投稿直後に基準値を取る**。GitHub の DL 数・スター数は**累積カウンタ**なので、
  ローンチ効果は «投稿時の基準値と 7 日後の値の差分» でしか読めない
- **GitHub Releases**: `gh api repos/kilde-team/kilde/releases --jq '.[] | {tag: .tag_name, assets: [.assets[] | {name: .name, dl: .download_count}]}'` — アセット別の DL 数。台帳には **両方** 記入する: `kilde-<version>-macos.zip` («zip» 列 — CLI バイナリを含む直接配布の代理指標) と `KildeGUI-<version>.dmg` («DMG» 列 — GUI の直接配布)
- **GitHub スター**: `gh api repos/kilde-team/kilde --jq '.stargazers_count'` — ローンチの反応の一次指標
- **Mac App Store**: App Store Connect → 分析 → «App Store のダウンロード» (日次。1〜2 日遅れで確定) — **期間値**なので基準値は不要、投稿週の値をそのまま書く
- **Homebrew**: tap に Homebrew 公式の公開アナリティクスは無い — 計測不能と考えてよい
- **サイト流入**: kilde.site にアナリティクスが入っていればそちら (未導入なら «不明» と書く) — 期間値

7 日後に同様に取得し、差分を台帳の «増分» に記入する。
#157 の受け入れ条件 «投稿後 1 週間の流入・インストール数を記録した» は
この台帳の記入をもって満たす。
