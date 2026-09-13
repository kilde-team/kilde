# kilde — マネタイズ戦略 調査メモ

- Date: 2026-09-14
- Status: draft (依頼者の「マネタイズのアイデアと成功事例の調査」依頼に対する
  調査結果を文書化したもの。意思決定はまだ未定)
- 性質の注意: **本文中の価格・収益数値はすべて 2026-09-14 時点の Web 調査に基づく**。
  SaaS の価格は頻繁に変わるため、意思決定のタイミングで公式ページを再確認すること

## 1. この文書について

kilde を個人開発として継続する上でのマネタイズ方針の判断材料とするため、
同種アプリ (画面録画 / 音声録音 / 会議 AI ノート / OSS 収益化) の成功事例を
調査・整理した。対象 issue: #104。

## 2. 成功事例調査

### 2.1 買い切り + アップデート課金型 (Mac ユーティリティの王道)

| アプリ | 価格 (2026-09 時点) | モデル | 示唆 |
|---|---|---|---|
| Screen Studio | $29/月 or $108/年 | 元は買い切り → 完全サブスクに移行、lifetime は廃止 | 個人開発 (Adam Pietrasiak 氏) で**初月 $30k** と大成功したが、サブスク移行は大きな不評を買い、安価な競合 (Screen Charm、Matte 等) が乱立する口実を与えた |
| CleanShot X | $29〜35 買い切り + 更新 $19/年 (任意) | 買い切り + 任意の更新プラン | 「永久に使えるが更新は継続課金」は Mac 圏で最も受けが良い妥協点。Setapp 収載でも二重に収益化 |
| Audio Hijack (Rogue Amoeba) | $69、メジャーアップグレード $29 | 買い切り、バージョンごとに課金 | **「Mac の任意の音声を録る」ニッチ utility が 20 年以上売れ続けている実証**。kilde の音声面に最も近い先例 |

### 2.2 コア無料 + AI / クラウド課金型 (2026 年の支配的パターン)

| アプリ | 無償範囲 | 有償 | 特徴 |
|---|---|---|---|
| Loom | 録画・共有 | Starter / Business | フリーミアムで数十万ユーザー → **Atlassian が $975M で買収 (2023)** |
| Otter.ai | 月 300 分 | $8.33〜$19.99/ユーザー/月 | 会議 AI ノート市場の中堅 |
| Fireflies.ai | 制限付き | $10〜$19/シート/月 | 会議ボット型の代表 |
| tl;dv | 録画無制限 | Pro $18/月〜 | 無償層が最も太い |
| Raycast | ランチャー全体 | Pro $8〜10/月 (AI クレジット制) | 「コアは永久無料、AI だけ課金」を明言 |
| Warp | ターミナル全体 | $20/月 (AI 専用) | 有償プランを AI 機能のみに絞る方針 |

### 2.3 OSS 由来の収益化 (kilde と同じ出発点)

| 事例 | モデル | 結果 |
|---|---|---|
| Cap (OSS 画面録画) | **open core**: 録画は OSS 無償・セルフホスト可。商用利用権とクラウド/AI 機能が Cap Pro 約 $8/月 | OSS でありつつ Loom の半額で課金する、**kilde に最も近い構図** |
| Plausible Analytics | OSS + ホステッド版 | 2 人で $1M ARR → 5 人で $3.1M ARR (外部資金なし) |
| Obsidian | コア無償 + Sync $4/月 + 商用ライセンス $50/年 (現在は任意) | 「本体は無料、便利さとサポートに課金」 |
| Kap | 無償 OSS (MIT)、収益化なし | 19k star でも持続可能性の道がなく開発は緩慢 — **収益化しない場合の対照例** |

## 3. kilde の位置づけと差別化

kilde が刺さる隙間 (Section 2 の事例との対応):

- **QuickTime ができない「システム音声 + マイクのミックス録音」を 1 コマンドで** —
  従来の解は Audio Hijack ($69) か BlackHole + Audio MIDI Setup 手動構成 + QuickTime/OBS
  という面倒な組み合わせしかなかった (DESIGN.md §1 と同旨)
- **会議録画**という最重要ユースケースは、2026 年に最も金が動いている領域
  (Otter / Fireflies / tl;dv は $10〜19/ユーザー/月で稼いでいる)
- **「Ctrl+C でも必ずファイナライズ」の信頼性**と**ローカル録画 (会議にボットを
  入れない)** は、クラウド型競合に対するプライバシー・信頼上の差別化になる
- 汎用の美麗デモ録画 (Screen Studio の土俵) は Red Ocean。kilde は
  「開発者・技術者向けの会議・音声録画 utility」という **Audio Hijack 型ニッチ**にいる

## 4. 提案 — フェーズ別マネタイズ戦略

ロードマップ (M1〜M3) に紐づけた段階的な案。各フェーズの判断は依頼者が行う。

### Phase 1 (現在〜M2): 収益化ではなく導線を築く

- CLI は**永久無償 OSS** と明言し、GitHub Sponsors を設置するだけ
- Homebrew tap (issue #24 相当) と Releases 署名が fan-out の武器
- Show HN / Reddit (r/macapps) / 日本語圏 (Zenn・Qiita) でローンチして star を貯める。
  star 数と Homebrew インストール数が後の販売資産

### Phase 2 (M3 GUI リリース): open core 二層化 (Cap モデル)

- KildeCore + CLI = OSS 無償のまま
- **kilde GUI = 有償**。価格は CleanShot 型「$29〜39 買い切り + 1 年更新込み、
  以降 $19/年 (任意)」を推奨 (§2.1 参照 — 完全サブスクへの移行は不評の定番)
- 商用利用は有償ライセンスに (Obsidian / Cap 流。「個人は無償、商用 $50/年」でも可)

### Phase 3: Pro サブスク ($8〜12/月) — AI レイヤーで LTV を上げる

- 録った会議の**文字起こし・要約・共有リンク**を Pro に。Raycast / Warp と同じ
  「コア無料、AI だけ課金」の現行スタンダード
- 売り文句は「**会議にボットを入れない。録音はローカル、AI 処理だけクラウド**」—
  Fireflies たちに対する明確な差別化
- AI コストを避けたい下位プランには BYO API key (ユーザーの OpenAI/Anthropic キー)、
  ホスト型を上位プランにする選択肢もある

### Phase 4 — 補助戦線

- Setapp 収載: リリース直後に約 30K imp の初期露出が得られる (CleanShot も採用)。
  収益分配は利用シェア制なので、直接販売との併用が前提
- 長期視点: Audio Hijack が証明するように、代替不能な音声 utility は
  **買い切りで 20 年売れ続ける**。急がずメジャーバージョン課金で細く長く

## 5. 避けるべきパターン (事例から裏付けあり)

1. **CLI の有償化** — 導線と信頼が死ぬ (Phase 1 の設計と矛盾)
2. **完全サブスク一本化** — Screen Studio の移行不評が教訓。買い切り+更新の
   CleanShot 型が Mac utility 圏では最も安全
3. **収益化ゼロのまま継続** — Kap の二の舞。GUI (M3) のモチベーション維持にも悪影響

## 6. 現実的な期待値

- フリーミアムの有償転換率は 2〜4% が相場。つまり収益は無償ユーザー数に比例し、
  **Phase 1 (導線構築) の比重が実際は一番大きい**
- 個人開発で生活が成り立つのは上位一握り。副業規模で始めて、M3 GUI の手応えで
  踏み込む深さを決めるのが現実的

## 7. 参照リンク (2026-09-14 閲覧)

- Screen Studio: https://screen.studio/ 、創業者インタビュー (初月 $30k):
  https://www.youtube.com/watch?v=1XZtGmMljPM
- CleanShot X 購入ページ: https://cleanshot.com/buy
- Audio Hijack: https://rogueamoeba.com/audiohijack/
- Loom 分析 (Sacra): https://sacra.com/c/loom/
- 会議 AI ノート比較 (Otter / Fireflies / tl;dv):
  https://www.umevo.ai/blogs/ume-all-posts/otter-vs-notta-vs-fireflies-vs-tl-dv-the-ultimate-2026-comparison-for-meeting-transcription
- Cap (OSS Loom alternative): https://cap.so/
- Plausible ($1M ARR OSS SaaS): https://plausible.io/blog/open-source-saas
- Obsidian 料金: https://obsidian.md/pricing
- Raycast 料金: https://www.raycast.com/pricing
- Warp 料金: https://www.warp.dev/pricing
- Kap: https://getkap.co/
- Setapp の効用: https://aicheatcode.substack.com/p/grow-your-mac-app-with-setapp-get
- フリーミアム転換率 2-4%:
  https://medium.com/@sohail_saifi/the-economics-of-developer-tools-why-everything-moved-to-freemium-a1a990eacbe8
