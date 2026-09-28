# ローンチ計測台帳 (issue #157)

各媒体の投稿後 1 週間の流入・インストール数を記入する台帳。
受け入れ条件 «投稿後 1 週間の流入・インストール数を記録した» はこの記入で満たす。

取り方の正本は [README.md](README.md) «投稿後 1 週間の計測»。
基準日は**投稿日から 7 日後**に揃える (媒体間で窓を揃えないと比較できない)。

## 台帳

| 投稿日 | 媒体 | 投稿 URL | 計測日 | GitHub Releases DL (`kilde-<ver>-macos.zip` / DMG) | GitHub スター (増分) | MAS DL (週) | サイト流入 | 気づき |
|---|---|---|---|---|---|---|---|---|
| | Show HN | | | | | | | |
| | r/macapps | | | | | | | |
| | Product Hunt | | | | | | | |

«GitHub Releases DL» は `kilde-<version>-macos.zip` と `KildeGUI-<version>.dmg` の
DL 数を分けて書く (zip には CLI バイナリが同梱されているため、**CLI チャネルの
代理指標は zip の DL 数** — docs/metrics.md «計測の限界» と同じ読み方)。
«MAS DL» は App Store Connect 分析の週次 «App Store のダウンロード»。
計測不能な経路 (Homebrew は公開アナリティクス無し) は «—» と書く。

## 判読の注意

- Homebrew のインストール数は公開計測が無いため常に不明 — GitHub Releases の
  zip DL 数が直接配布 (CLI 含む) チャネルの代理指標 (docs/metrics.md «計測の限界» と同じ)
- MAS DL は App Store Connect の確定が 1〜2 日遅れる。«計測日» の行に
  取得日を書くこと
- サイト (kilde.site) にアナリティクスが無ければ «不明» でよい (無いなら無いと
  書く方が、あとで導入判断に使える)
- 増分の比較は«前週の同曜日»と比べる。絶対数より、どの媒体がインストールに
  結び付いたか (質: コメントの質も «気づき» に 1 行書く) を見る
