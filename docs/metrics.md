# 定着 KPI の定義と月次ダッシュボード (issue #159)

フェーズ 2 (#161) の出口条件 «月間アクティブ (録画完了) 1,000 人・App Store の
評価 30 件» を測るための定義と手順。**数値の正本は Firebase コンソールと
App Store Connect で、このファイルは定義・手順・月次台帳**。ASC のメタデータ
変更前後の計測台帳は別ファイルの
[appstore/metadata/metrics.md](appstore/metadata/metrics.md) (issue #160)。

## KPI の定義

| # | 指標 | 定義 | 見る場所 | 目標 |
|---|---|---|---|---|
| 1 | 月間録画完了ユーザー数 | 過去 30 日に `recording_complete` を 1 回以上送ったユーザー数 | Firebase コンソール → アナリティクス → イベント → `recording_complete` (ユーザー数) | **1,000** (#161 の出口条件) |
| 2 | 定着率 (録画完了 3 回以上のユーザー率) | ユーザー プロパティ `recordings_bucket` が `3_5` / `6_9` / `10_plus` のユーザーの割合。**分母は `recordings_bucket` が設定されたユーザー全体** (アプリを起動したことがあるユーザー。0 回のユーザーは `0` に入る)。分母は `(not set)` 行を除く値の行合計で数える (分布は «ユーザー × 値» の行 — «計測の限界» 参照。cubic レビュー指摘で明記) | Firebase コンソール → ユーザー プロパティ → `recordings_bucket` の分布 | 未定 — ベースラインを 3 か月取ってから決める |
| 3 | 文字起こし利用率 | 過去 30 日に `transcription_complete` を送ったユーザー数 ÷ 同じ窓で `recording_complete` を送ったユーザー数 | Firebase コンソール → イベントのユーザー数 (両イベント) | 未定 (同上) |
| 4 | App Store の評価数 | MAS 版の評価 (レーティング) の累計件数 | App Store Connect → 分析 (概要の App Store 評価) と「評価とレビュー」(星別の件数) | **30** (#161 の出口条件) |
| 5 | チャネル別の内訳 | `recording_complete` の `channel` パラメータとユーザー プロパティ `distribution_channel` (`mas` / `direct`) の分布 | Firebase コンソール (イベントのパラメータ / ユーザー プロパティ) | 目標なし (参考値) |
| 6 | Pro 転換ファネル (参考) | `pro_upsell_view` → `pro_purchase_start` → `pro_unlocked` の各ユーザー数 (0.27.0 以降。**エピック #174 の出口条件 «有料転換 2%» の正本は ASC の IAP 販売数 ÷ DL** — GA4 側はアプリ内ファネルの相対的な離脱を読むために使う) | Firebase コンソール → イベント (各イベントのユーザー数) | **2%** (#174 の出口条件。判定は ASC 側で) |
| 7 | Pro 機能の利用 (参考) | `summary_complete` を 1 回以上送ったユーザー数 ÷ 同じ窓で `transcription_complete` を送ったユーザー数 (0.27.0 以降。要約は Pro の本体機能で、転換後の価値を測る基礎)。0.28.0 からは第二弾 Pro «フォローアップの下書き» の `followup_complete` ユーザー数も同じ窓で記録する。0.29.0 の第三弾 Pro «カスタム指示» は既存の `summary_*` / `followup_*` に乗る。0.38.0 からは第四弾 Pro «書き起こしの質問応答» の `qa_complete` ユーザー数も同じ窓で記録する。0.39.0 からは第五弾 Pro «ライブラリ横断の質問応答» の `library_qa_complete` ユーザー数も同じ窓で記録する。0.40.0 からは第六弾 Pro «質問応答の連続対話» の `qa_chat_complete` ユーザー数も同じ窓で記録する。0.41.0 からは第七弾 Pro «書き起こしの翻訳» の `translation_complete` ユーザー数も同じ窓で記録する (登録済みディメンションのみの規約 — issue #456。`qa_*` / `library_qa_*` / `qa_chat_*` / `translation_*` のパラメータも `processing_time` と `error_kind` のみ) | Firebase コンソール → イベント (各イベントのユーザー数) | 未定 (指標 3 と同じくベースライン取得後) |

## 送っているイベントとユーザー プロパティ

実装は `gui/Sources/UsageAnalytics.swift`。**セルフテストと Debug 構成では
送らない** (AppDelegate.sendsUsageToFirebase、issue #219)。

- イベント: `app_open`、`recording_complete` (パラメータ: `recording_length`、
  `channel`)、`transcription_start` / `transcription_complete` / `transcription_fail` /
  `transcription_cancel` / `transcription_retry` (パラメータ: `recording_length`、
  `processing_time`、`error_kind`)、`summary_start` / `summary_complete` /
  `summary_fail` / `summary_skip` (0.27.0〜。パラメータは文字起こしと同じ
  `recording_length`・`processing_time`・`error_kind`)、`followup_start` /
  `followup_complete` / `followup_fail` (0.28.0〜。第二弾 Pro «フォローアップの
  下書き› の利用。パラメータは `processing_time`・`error_kind`)、
  `qa_start` / `qa_complete` / `qa_fail` (0.38.0〜。第四弾 Pro «書き起こしの
  質問応答» の利用。パラメータは `followup_*` と同じ `processing_time`・
  `error_kind` — 新しいカスタム ディメンションは不要)、
  `library_qa_start` / `library_qa_complete` / `library_qa_fail` (0.39.0〜。
  第五弾 Pro «ライブラリ横断の質問応答» の利用。パラメータは `qa_*` と同じ
  `processing_time`・`error_kind` — 新しいカスタム ディメンションは不要)、
  `qa_chat_start` / `qa_chat_complete` / `qa_chat_fail` (0.40.0〜。第六弾 Pro
  «質問応答の連続対話» の利用 — **追質問だけ**を数え、初問は `qa_*` /
  `library_qa_*` が数える。両シート (単一録画・ライブラリ横断) 共通のイベント名 —
  «どのシートか» は初問のイベントで分かる。パラメータは `qa_*` と同じ
  `processing_time`・`error_kind`。`qa_chat_fail` の `error_kind` は両シートの
  コード (`qa.*` / `libraryQA.*`) を写像する)、
  `translation_start` / `translation_complete` / `translation_fail` (0.41.0〜。
  第七弾 Pro «書き起こしの翻訳» の利用。パラメータは `qa_*` と同じ
  `processing_time`・`error_kind` — 新しいカスタム ディメンションは不要。
  `translation_fail` の `error_kind` は **`translateErrorKind` の列挙が正本**
  (`license_required` / `empty_transcript` / `unsupported_environment` /
  `cancelled` / `engine_error` / `model_error` — 翻訳には «質問» が無いため
  `qaErrorKind` のうち `empty_question` は発生しない部分集合。語彙そのものは
  登録済みディメンションの `error_kind` に使える値だけ)、
  `pro_upsell_view` /
  `pro_purchase_start` / `pro_purchase_cancel` / `pro_purchase_pending` /
  `pro_purchase_fail` / `pro_unlocked` / `pro_restore_fail` (0.27.0〜。**MAS 版のみ
  発火** — 直接配布版は Pro 無料開放で購入 UI が存在しないため。パラメータは
  `error_kind` のみ)、`transcript_export` / `transcript_copy` (0.32.0〜。
  ライブラリでの文字起こしの持ち出し — «どの形式で書き出されたか» と «コピーの
  単位» を見る。パラメータは `format` (`txt` / `srt` / `vtt`) と `kind`
  (`whole` / `segment`)。**どちらも新しいパラメータのため GA4 のカスタム
  ディメンション登録が必要** — 下の «初回セットアップ» と «実施記録» を参照。
  未登録の間は GA4 の制約で直近 30 分の値しか見られない)、
  `spotlight_open` (0.33.0〜。Spotlight の結果からアプリを開いた —
  «Spotlight という入口が使われているか» を見る。**パラメータなし**のため
  カスタム ディメンション登録は不要。どの録画を開いたかは «名前やパスを送らない»
  契約により載せない)、`reminder_export` (0.34.0〜。要約のアクションアイテムを
  リマインダーへ書き出した — «要約をタスク管理に流す導線が使われているか» を
  見る。**パラメータなし**のためカスタム ディメンション登録は不要 (spotlight_open
  と同じ)。項目の文面・件数・どの録画からかは «名前やパスを送らない» と
  «値は列挙に閉じる» の両契約により載せない)
- **Pro / 要約系のパラメータは登録済みディメンション (`error_kind` /
  `recording_length` / `processing_time`) のみを使う** (issue #456) — 新しい
  カスタム定義の登録は不要。`pro_unlocked` は権利の false→true 遷移だけで
  発火し、起動時の初回判定で «既に購入済み» だった場合 (再インストール等) は
  数えない
- ユーザー プロパティ: `distribution_channel` (`mas` / `direct`)、
  `recordings_bucket` (`0` / `1` / `2` / `3_5` / `6_9` / `10_plus` — 端末内で数えた
  累計録画完了回数の区分。`0` は «まだ録っていない» で、起動した全ユーザーが
  分布に入る)

プライバシーの制約 (PRIVACY.md «収集する情報»): 区分値のみで、録画の内容・
ファイル名・保存先・生の秒数・生の回数は送らない。

## 初回セットアップ (Firebase コンソール。1 回だけ)

コンソールでカスタム定義を登録する (**登録しないとパラメータ・プロパティの
値別の内訳がレポートに出ない** — 未登録のまま見られるのは直近 30 分の値だけ)。

1. Firebase コンソール → アナリティクス → カスタム定義
2. ユーザー プロパティとして `distribution_channel` と `recordings_bucket` を登録
3. カスタム ディメンション (イベント スコープ) として `channel`、`recording_length`、
   `processing_time`、`error_kind` を登録
4. 0.32.0 追加分: カスタム ディメンション (イベント スコープ) として `format`
   (`transcript_export` の書き出し形式) と `kind` (`transcript_copy` のコピー単位) を
   登録する。**2026-11-05 時点で未登録** — コンソール作業は ASC の CSV エクスポートと
   同じく人間の作業のため、依頼者に依頼する (issue #493 の完了報告に記載)。登録の
   前提条件は下の «検知用イベントの経緯» と同じ: GA4 は端末から受信済みのパラメータ
   しか選べないため、0.32.0 の配布ビルドが 1 件以上イベントを送る必要がある

### 実施記録 (2026-09-28 〜 09-29。09-29 に 6/6 完了)

GA4 プロパティ `555463514` に **6 件すべて登録済み**:

| 表示名 | スコープ | 対象 | 登録日 |
|---|---|---|---|
| Distribution channel | ユーザー | `distribution_channel` | 2026-09-28 |
| Recordings bucket | ユーザー | `recordings_bucket` | 2026-09-28 |
| Recording length | イベント | `recording_length` | 2026-09-28 |
| Processing time | イベント | `processing_time` | 2026-09-28 |
| Channel | イベント | `channel` | 2026-09-29 |
| Error kind | イベント | `error_kind` | 2026-09-29 |

**検知用イベントの経緯** (同じ作業をするときの注意): `channel` と `error_kind` は
0.8.2 以降の配布ビルドが初送信のため、GA4 の UI は **端末から受信済みの
パラメータしか選べない**。そこで Measurement Protocol で検知用イベント
(`custom_definition_setup`、両パラメータを含む) を送ったが、**2026-09-28 午前の
初回送信は GA4 に届いていなかった** — Firebase MP は未知の `app_instance_id` に
対して 2xx を返した上で黙って破棄する (イベント一覧に現れないことで判明)。
同日夜、インストール済み MAS 版アプリのコンテナから実在の `app_instance_id`
を取得して再送し、リアルタイム レポートで到達を確認。**パラメータがカスタム
定義の選択肢に現れたのは到達から約 19 時間後 (2026-09-29 15 時頃)**。実在の
インスタンス ID を使うため合成データ 1 件は開発者の端末に帰属するが、月次の
数値に影響しない規模。`app_instance_id` はアプリコンテナの
`Application Support/Google/Measurement/com.google.gmp.measurement.plist` の
`/google/measurement/app_instance_id` から取得する (**32 桁 16 進・ハイフン無し**。
`/debug/mp/collect` で形式を検証してから `/mp/collect` へ送ること)。

**API secret `issue159-setup` は 2026-09-29 に削除済み** (2 件の登録確認後)。

Admin API での事前登録は試みたが不可だった — カスタム定義の作成に必要な
OAuth スコープは `analytics.edit` だが、gcloud / OAuth Playground が使う共有
OAuth クライアントはこのスコープについて Google の審査を通っておらず
(401 `disabled_client`)、自分で OAuth クライアントを登録・審査するコストに
見合わない。将来やり直すときは独自クライアントの登録から始めること
(cubic レビュー指摘でスコープ名の誤記 `analytics.admin` を `analytics.edit` に修正)。

## IAP 販売数と DL の月次台帳 (エピック #174 の判定材料)

Pro 転換率 «有料転換 2%» (issue #174 の出口条件) の正本は «ASC の IAP 販売数 ÷ DL»
(指標 6 参照)。その転記先をここに新設した (issue #598、2026-11-19)。
転記手順と #174 出口条件の判定欄を issue #635 (2026-11-24) で整備した。

### 取得方法 (ASC API の Sales Report。手動エクスポート不要)

**App Store Connect API** の Sales Report を使う (`asc-submit` リポジトリの
`asc_submit.auth.make_token` で JWT を作り `salesReports` を呼ぶ):

```
GET https://api.appstoreconnect.apple.com/v1/salesReports
  ?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY
  &filter[vendorNumber]=85006198&filter[reportDate]=YYYY-MM-DD
Accept: application/a-gzip
```

- 日次 TSV (gzip) が返る。**kilde 関連の行だけを抜く**: SKU `kilde-mas` と
  IAP の Product Type Identifier **IA1 / IA1-M / FI1** (SKU に `kilde.` が付く行のみを
  対象にするため、同じベンダー番号の別アプリの行は混入しない。接尾辞 `-M` は Mac、
  接尾辞無しの `IA1` は iOS — kilde は MAS のみなので現状観測されるのは `IA1-M`。
  `FI1` も Mac の IAP 区分のひとつで、無料/有料を表すものではない — 現状の kilde では
  未観測だが、フィルタに含めて将来の集計漏れを防ぐ)。DL 系で観測される区分は **F1 = 無料アプリの DL トランザクション**
  (初回 DL の代理指標)、**F3 = 無料アプリの再 DL トランザクション** (kilde-mas の行で
  実在を確認)、**F7 = 無料アプリのアップデート**。ASC 分析の
  «初回ダウンロード (ユニークデバイス)» とは定義が異なる近似値 — トレンド用
- IAP の行は `Units` (個数) と `Customer Price` / `Developer Proceeds` を持つ。
  **`Developer Proceeds` の通貨は行の `Currency of Proceeds` で読む** (常に USD では
  ない。USD 換算の合計が必要な場合は通貨ごとに分けてから明示的な変換を行う)。
  レポートは **地域ごとに翌日 5am PT まで**
  に配信される (JP はそのあと)。月次の転記は翌月初に «前月の末日分が揃ってから» 行う
  (GA4 月次の手順と同じタイミングでよい)
- 2026-11-19 時点で ASC 分析 (App Analytics) API のレポート生成を
  `analyticsReportRequests` で開始済み — «表示 / ページ閲覧» 系の指標は生成後に
  [appstore/metadata/metrics.md](appstore/metadata/metrics.md) の週次表へ転記する

### 対象 IAP

| Product ID | 種別 | 内容 |
|---|---|---|
| `kilde.pro` | 非消耗型 | kilde.pro (買い切り ¥2,800)。MAS 版のみ。2026-10-28 販売開始 |
| `kilde.tip.small` / `kilde.tip.medium` / `kilde.tip.large` | 消耗型 | 応援チップ (issue #171)。2026-10-20 販売開始 |

### 転記手順 (issue #635、2026-11-24 整備)

1 行を記入するときは次の 4 点を揃える。**取得できた数字だけを書く** — 取得できない
値は «未記入 (ASC 転記待ち)» など理由つきで空欄にし、推測値・無断の換算値を
書かない (metrics-ledger-ops スキル §4 «データなし・判定不可» のルール)。

1. **取得元**: 販売数・売上は **ASC API の Sales Report** (上の «取得方法»。
   SKU 別に `Units` と `Developer Proceeds` を数え、売上は `Currency of Proceeds`
   ごとに分けて記す)。初回 DL は **ASC 分析 («初回ダウンロード») が正本**で、
   CSV エクスポートを要する取得はオーナー作業のため «未記入 (ASC 転記待ち)» と
   明記して先に進める。代理指標の **F1 (Sales Report)** はトレンド読み用の列として
   **継続して記入する** (issue #598 の経緯どおり) — 正本 «初回ダウンロード» を
   取得できた月も F1 列を正本値で差し替えず、**«気づき» に正本値を併記する**
   (F1 で置き換えると分母の定義が月ごとに混ざる。判定欄の分母は常に
   ASC 分析 «初回ダウンロード» で統一 — metrics-ledger-ops スキル §3)
2. **集計窓**: 販売列・初回 DL 列・転換率は **すべて当月 (前月 1 日〜末日) の値**で
   揃える (販売だけを累計にすると転換率の分母と分子の窓がずれる。累計を見たいときは
   «気づき» に併記する)。**時間基準は太平洋時間 (PT)** — Sales Report も ASC 分析の
   レポート日も PT 基準のため、JST で窓を切ると 1 日ずれる (metrics-ledger-ops
   スキル §3)。確定は **翌月初** («前月の末日分が揃ってから»。レポートは地域ごとに
   翌日 5am PT までの配信)
3. **記入日**: 行を書いた日を «記入日» 列に残す (追試できるようにするため —
   metrics-ledger-ops スキル §5)。窓が未確定のうちに書いた行は «暫定» と明記し、
   翌月初の確定時に**同じ行を上書きして**確定する (月ごとに 1 行を保つ)
4. **母数が小さいときの読み方 (pooled 規約)**: 判定に使う初回 DL 母数 (分母の正本は
   ASC 分析 «初回ダウンロード»。正本が «未記入 (ASC 転記待ち)» の間は判定自体が
   未成立) が **100 件未満のうちは、その月の転換率を #174 の判定に使わない**
   (1 件の動きで率が大きく動く)。率そのものは **Pro 販売開始を起点にした
   pooled (累計) 比**を参考値として «気づき» に併記し、判定欄 (下の
   «#174 出口条件の判定欄») は «判定不可» とする。**pooled の窓も «集計窓» と
   同じく PT で切る** — 0.26.0 の公開は 2026-10-27T22:27:41Z (= PT 10-27 の午後) で
   厳密な開始は **PT 10-27** (PT 10-27 の日は公開前の数時間を含む — «気づき» に
   注記する。既録の累計値は issue #598 が PT reportDate の 10-28〜 で数えた実測で、
   次回確定時に開始を PT 10-27 に揃え直す)。母数が **100 件以上**になってから
   当月窓の率で «達成 / 未達成» を判定する (判定の分母は常に ASC 分析
   «初回ダウンロード» — F1 比はトレンド値で判定には使わない)

### 月次台帳

| 月 (当月窓) | 記入日 | kilde.pro 販売 | チップ販売 small / medium / large (計) | 売上 (Developer Proceeds, 通貨別) | 初回 DL (当月) | 転換率 (pro ÷ 初回 DL, 当月) | 気づき |
|---|---|---|---|---|---|---|---|
| 2026-11 | 2026-11-19 (**暫定** — 翌 12 月初に確定上書き) | 1 | 0 / 0 / 0 (計 0) | USD 15.29 (kilde.pro 1 件のみ。チップの売上は 0) | F1 18 件 (11-01〜17。11-18 以降はレポート未配信)。**ASC 分析 «初回ダウンロード» は未記入 (ASC 転記待ち)** | 5.6% (1/18、F1 代理分母)。**判定不可 — 正本分母 (ASC 分析) が未取得**。pooled 参考: 1/20 = 5.0% (F1 の 10-28〜11-17 累計、PT reportDate — issue #598 実測) | **初の有料転換** — kilde.pro が 2026-11-15 に米国ストアで 1 件 (Customer Price $17.99 / `Currency of Proceeds` USD の $15.29、Sales Report 実測 2026-11-19 取得、issue #598)。チップは 0 件。判定欄は下の «#174 出口条件の判定欄» |

**計測の注意**: F1 はトランザクション単位のため «MAS 初回 DL» の真の分母は
ASC 分析側 («初回ダウンロード») で置き換える。GA4 の `pro_unlocked` と突合すると
きは «pro_unlocked は権利の false→true 遷移のみ» (上の «送っているイベント» 参照)
のため、再インストール分が Sales Report の F1 に乗っても pro_unlocked に乗らない
ズレが生じる — 月次の気づきに併記する。

### #174 出口条件の判定欄 («有料転換 2%» — ASC の kilde.pro 販売数 ÷ MAS 初回 DL)

#174 本文の «IAP 販売数» は、この判定では **kilde.pro の販売数**を指す
(チップ `kilde.tip.*` は寄付で Pro 転換ではないため分子に数えない)。
分母は ASC 分析 «初回ダウンロード» (正本 — «転記手順» 1)。
判定は «転記手順» の 4 (pooled 規約) に従い、**母数 ≥ 100 になるまでは
«判定不可» で更新し続ける** — 率が 2% を上回っていても判定としては書かない。

| 判定日 | 判定 | 根拠 (母数と出典) |
|---|---|---|
| 2026-11-24 | **判定不可 (正本分母未取得)** | 判定に使う正本分母 (ASC 分析 «初回ダウンロード») が CSV エクスポートを要するため «未記入 (ASC 転記待ち)» で、率の判定自体が未成立。参考 (判定には使わない — «転記手順» 1・4): 代理指標 F1 は当月 18 件 (2026-11-01〜17 PT reportDate、Sales Report 実測 2026-11-19、issue #598 — 11-18 以降はレポート未配信で暫定)、Pro 販売開始窓の累計 20 件で、いずれも «転記手順» 4 の母数要件 (≥ 100) に届かない 2 桁。次の判定は 2026-12 月初 (11 月分の確定時) に正本分母の取得を合わせて行う |

## 月次の振り返り手順 (毎月 1 回。月初の第 1 月曜を推奨)

前月分のレポートが確定してから行う (ユーザー プロパティの反映は数時間〜
1 日遅れるため、1 日の朝にやると前月末分が欠ける恐れがある)。
GA4 と台帳の締め全体の順序は下の «月次締めチェックリスト» を参照 (issue #639)。

1. Firebase コンソール → イベント: 過去 30 日の `recording_complete` と
   `transcription_complete` のユーザー数を記録する (指標 1・3)
2. ユーザー プロパティ: `recordings_bucket` の分布から、**`(not set)` 行を除く
   全値の行合計を分母に** `3_5` / `6_9` / `10_plus` の合計の割合を定着率として
   記録する (指標 2。分布は «ユーザー × 値» の行 — «計測の限界» 参照)
3. ユーザー プロパティ: `distribution_channel` の分布を記録する (指標 5)。
   あわせて Pro ファネル (`pro_upsell_view` / `pro_purchase_start` / `pro_unlocked`)
   のユーザー数を記録する (指標 6。**転換率そのものは ASC の IAP 販売数 ÷ DL が
   正本** — GA4 はアプリ内の離脱点を見る参考値)。Pro 機能の利用
   (`summary_complete` と `transcription_complete` のユーザー数、0.28.0 以降は
   `followup_complete` のユーザー数も) も記録する (指標 7。0.38.0 からは
   `qa_complete`、0.40.0 からは `qa_chat_complete`、0.41.0 からは
   `translation_complete` のユーザー数も)
4. App Store Connect: 評価の累計件数と平均を記録する (指標 4)。あわせて
   ASC API の Sales Report で前月の IAP 販売数と F1 を取得し、下の
   «IAP 販売数と DL の月次台帳» に «転記手順» に従って 1 行追記する
   (issue #598、2026-11-19 から。暫定行がある月は追記ではなく確定上書き)
5. [appstore/metadata/metrics.md](appstore/metadata/metrics.md) の
   ASC 週次台帳が埋まっていれば、その月の初回 DL 合計を台帳の「気づき」に添える
   (#160 の計測と混ぜすぎない — リンクするだけでもよい)
6. 下の台帳に 1 行追記し、前月との差分と気づきを書く
7. 出口条件から遠ざかっている場合は、対処の issue を起票する
   (施策の候補はロードマップの #157 / #158 など)

## 月次締めチェックリスト (月末〜月初の締め順序 — issue #639、2026-11 月次から運用)

月初の振り返り (上の «月次の振り返り手順»。エピック #161 / #174 の必須確認) の
**前に**、前月分の台帳をこの順序で締める。原則は «取得できた数字だけを書く» —
取得できない項目は理由つきで «未記入 (取得待ち)» / «未取得» と明記して先に
進める (未取得を締めのブロックにしない。下の «未取得項目の扱い (共通規約)»)。

| # | 項目 | 取得元 | 集計窓 | 記入先 | 未取得時の扱い |
|---|---|---|---|---|---|
| 1 | IAP 販売数月次台帳の当月行 (kilde.pro・チップ別・売上・F1) | ASC API の Sales Report (このファイルの «IAP 販売数と DL の月次台帳» → «取得方法»。自動取得可 — レポートは地域ごとに翌日 5am PT まで配信) | 当月 1 日〜末日 (PT 基準) | «IAP 販売数と DL の月次台帳» の当月行 (暫定行は翌月初に «転記手順» どおり確定上書き) | «未記入 (Sales Report 未取得)» + 未配信の日付を «気づき» に明記 |
| 2 | 初回 DL の正本 (ASC 分析 «初回ダウンロード») | ASC 分析 UI の CSV エクスポート (オーナー作業) | 当月 | 同台帳 «初回 DL (当月)» 列 | «未記入 (ASC 転記待ち)» — この間は #174 の判定自体が未成立 («転記手順» 4) |
| 3 | GA4 月次行 (録画完了ユーザー・定着率・文字起こし利用率・mas/direct の内訳) | Firebase コンソールの手動読み取り («月次の振り返り手順» 1〜3。GA4 Data API による自動取得は SA Viewer 追加待ちで不通 — issue #611) | イベント系は «過去 30 日»。前月 1 日〜末日に読み替えた場合は «気づき» に窓を明記 | «月次台帳» の当月行 | «未取得» + 理由 (2026-11 行に記録済みの経緯 — Data API のスコープ拒否と SA Viewer 追加待ち) |
| 4 | ASC 週次表の当月分 (ユニーク表示・うち検索経由・ページ閲覧・初回 DL・再 DL・CVR) | ASC 分析 UI の CSV エクスポート (オーナー作業。初回 DL・再 DL だけは Sales Report の F1 / F3 で代理記入できる — appstore/metadata/metrics.md «変更 3 後 / 変更 4 後» 表の前例) | 週次 (月〜日) | [appstore/metadata/metrics.md](appstore/metadata/metrics.md) の週次表 | «未取得» と理由 (ユニーク系指標は ASC 分析 CSV が正本のため代理は不可) |
| 5 | 評価件数 (累計) | iTunes Lookup API (id 6812783176、country=jp / us ほか主要ストア。ASC 分析の正本との突合はオーナー確認) | 累計 (月初締め時点) | «月次台帳» の «評価数 (累計)» 列 | 前月の値と確認日を «気づき» に残す |

### 締めの順序

1. 翌月初に Sales Report で前月末日分の配信を確認し、IAP 台帳の暫定行を
   «転記手順» に従って確定上書きする
2. GA4 月次行を «月次台帳» に追記する («月次の振り返り手順» 1〜3)
3. 評価件数を iTunes Lookup で確認して «月次台帳» に記入する
4. ASC 週次表と初回 DL の正本 (オーナー作業分) は «未記入 (ASC 転記待ち)» を
   理由つき明記して先に進める
5. 判定欄を更新する (下の «#161 出口条件の判定欄» と
   «IAP 販売数と DL の月次台帳» 内の «#174 出口条件の判定欄») —
   **母数と未取得項目を明記する**
6. 判定が «未達成» なら対処の issue を起票する («月次の振り返り手順» 7 と同じ)

### 未取得項目の扱い (共通規約)

- 未取得は «未記入 (取得待ち)» / «未取得» と**理由つき**で書く (何が・なぜ
  取得できないか — «オーナー作業待ち» / «レポート未配信» / «権限待ち» を
  区別する)
- 推測値・無断の換算値を書かない (metrics-ledger-ops スキル §4
  «データなし・判定不可» のルール)
- 未取得の項目が残る月は、判定欄に «達成 / 未達成» と書かない —
  «判定不可 (母数未取得)» とする
- 母数 < 100 の率は pooled (累計) 比を参考値として併記し、当月窓の率での
  判定は «判定不可» («転記手順» 4 の既存規約。#161 の MAU 判定でも母数を
  明記する)

### #161 出口条件の判定欄 («録画完了MAU 1,000・評価 30 件» — 雛形)

2 条件の内訳: «録画完了MAU 1,000» は指標 1 (過去 30 日の `recording_complete`
ユーザー数。Firebase コンソールの手動読み取り。GA4 Data API による自動取得は
issue #611 の SA Viewer 追加待ちで不通)、«評価 30 件» は指標 4 (MAS 版の評価の
累計件数。iTunes Lookup で主要ストアを確認できる)。**雛形であり、2026-11 月次
振り返り (月初) に初回記入する — 本版 (0.52.0) では実測値を埋めない**。

| 判定日 | 録画完了MAU (母数) | 評価数 (累計) | 判定 | 根拠 (未取得項目と理由) |
|---|---|---|---|---|
| (2026-11 月次振り返り時に記入) | 未記入 (GA4 コンソール読み取り待ち) | (iTunes Lookup で月次締め時に記入) | 判定不可 (MAU 未取得) | MAU はオーナーのコンソール読み取り (または issue #611 の自動取得再開) を待つ。評価数は iTunes Lookup で取得可 — 2026-11-19 時点で主要 10 ストア 0 件 (2026-10 行の実績) |

«録画完了MAU 1,000» は母数そのものが目標値のため、MAU 未取得のうちは判定を
書かない。«評価 30 件» は累計件数の直接比較で単独判定できるが、**未取得が
ある条件は «判定不可» と明記**し、両条件の進捗を 1 行で読める形を保つ。

## 月次台帳

| 月 | 録画完了ユーザー (30 日) | 定着率 (3 回以上) | 文字起こし利用率 | 評価数 (累計) | mas / direct | 気づき |
|---|---|---|---|---|---|---|
| 2026-10 | 1 | 20% (1/5) | 100% (1/1) | 0 | mas 2 / direct 0 | 初回計上 (窓は 2026-09-03 〜 10-02、2026-10-03 集計)。`recording_complete` は 4 件 / 1 名で `channel=mas` のみ — 0.8.2 以降の配布ビルドから届いているが、現時点のサンプルは開発者端末とみられる規模。`recordings_bucket` の分布 0: 2 / 1: 1 / 2: 1 / 3_5: 1 は **ユーザー × 値の行数** で、bucket が進んだユーザーは複数行に現れる — 行合計 5 はユニークではなく、ユニークは 2 名 (`distribution_channel` の mas 2 名と一致、うち 3_5 以上が 1 名なのでユニーク基準の定着率は 1/2)。20% は «(not set) 行を除く全値の行合計を分母» というこのドキュメントの定義どおりの値 ((not set) 行を含めると分母 12 で 8.3%)。(not set) 列には窓内の全 7 名が現れる — プロパティ設定前のイベントも (not set) に計上されるためで、«旧バージョンのままのユーザー» 限定の値ではない。評価は 0 件 — ASC にログインできないため公開の iTunes Lookup API (ストア表示と同じ値) で主要 10 ストアを確認、すべて 0 (ASC 分析 UI との突合は次回月次で)。0.8.3 を 2026-09-29、0.8.4 を 2026-10-03 (JST) に公開 — 次回は 0.8.4 (録画の自停止修正入り) の効果を見る。ASC 週次台帳 ([appstore/metadata/metrics.md](appstore/metadata/metrics.md)) はまだ未記入 |
| 2026-11 | 未取得 | 未取得 | 未取得 | 0 (iTunes Lookup jp / us で 2026-11-19 確認) | 未取得 | 台帳記入を 2026-11-19 に試みたが、**GA4 Data API への自動取得経路が閉じていた**ため断念 (issue #598)。①gcloud の共有 OAuth クライアントは `analytics.readonly` スコープが未登録で同意画面が 403 `restricted_client` («初回セットアップ» の `analytics.edit` 401 と同根の制約)、②GA4 Data API は `cloud-platform` スコープのトークンを `ACCESS_TOKEN_SCOPE_INSUFFICIENT` で拒否、③kawai@muse.ai に参照できる GCP プロジェクトが無くサービスアカウント経路も不通。**代替案**: GA4 コンソール (kawai@muse.ai、2026-11-19 に権限付与済み) から «月次の振り返り手順» の 1〜3 を手動で読み取り転記するか、GA4 プロパティ 555463514 にサービス アカウントを Viewer として追加すれば次回から自動化できる。参考: 同日の ASC Sales Report で **2026-11-01〜17 の MAS 初回 DL 相当 (F1) 18 件・kilde.pro 初販売 1 件** を確認 (下の «IAP 販売数と DL の月次台帳»)。なお同じ Sales Report の F1
(初回 DL 代理) を月ごとに既知分だけで数えると 9 月 1 件 (9-25 のみ) / 10 月 17 件 /
11 月 18 件 (11-17 まで、月末未確定) となる — **窓が未確定の暫定値**で、F1 はユニーク DL
ではないため、増加の «方向» を読む以上のことはしない |

## 計測の限界と読み方の注意

- **CLI / Homebrew チャネルは計測されない** (PRIVACY.md «kilde コマンドラインは
  解析を行いません» — 方針として変えない)。指標 5 の内訳は GUI の 2 チャネルのみ。
  CLI の規模は GitHub Release の `kilde-<version>-macos.zip` (CLI を同梱。
  Homebrew formula の `url` もこの zip を指すため、`brew install` /
  `brew upgrade` のダウンロード数も含まれる — cubic レビュー指摘) の
  ダウンロード数が代理指標になる
- **`recordings_bucket` は生涯累計**の区分なので、«3 回以上» には «今月は
  録っていない人» も含まれる (インストール済みユーザーの深さの指標)。
  «今月 3 回以上録ったユーザー率» の厳密な値はユーザー単位の生データが必要で、
  BigQuery エクスポート (未設定) が要る。まずは近似として使う
- **GA4 のユーザー プロパティの分布表は «ユーザー × 値» の行** になる —
  `recordings_bucket` が進んだユーザーは複数の値の行に現れるため、
  行合計をユニーク ユーザー数として読まない (2026-10 の台帳では
  行合計 5・ユニーク 2 名。cubic レビュー指摘で注記を追加)。«設定された
  ユーザー全体» を分母にする指標 2 の定義は、行合計ベース (このドキュメントの
  手順どおり) とユニーク ベースで値がずれる — 台帳には手順どおりの値を記入し、
  ユニーク基準の値を気づきに併記する
- **旧バージョン (0.8.1) のカウンタからの移行**: 0.8.1 の **MAS 版**が評価依頼の
  ために数えていた «15 秒以上の録画完了» カウンタを、この機能の初回起動時に
  1 回だけ `recordings_bucket` の基礎に引き継ぐ (評価依頼は MAS 専用機能のため、
  **直接配布版には対応する履歴が無く 0 から始まる** — 生涯累計として完全に
  成立するのは MAS 版ユーザーとこれ以降の新規ユーザー)。15 秒未満の録画は
  数えられていないため移行端末の累計は僅かに下振れする (短い録画が `3_5` の
  境界を跨ぐ程度と読み替えて許容 — 下振れは «定着している» 側への上振れより
  安全)。0.8.2 以降の完了はすべて数える
- 定着率 (指標 2) の分母は «起動したことがあるユーザー全体» なので、流入が
  増える月は比率が下がる側に動く (新規はまず `0` に入るため)。伸びしろの
  大きさとして読み、月初の施策判断はトレンドで行う
- Firebase のレポートは日次で確定する。前日比のような短周期の変動で判断しない
- **App Privacy ラベルは変更不要** — 追加したイベント・プロパティは区分値のみで、
  2026-09-23 に申告済みの «製品の操作» (analytics 目的・トラッキングなし) の
  枠内。PRIVACY.md も同じ内容に更新済み (2026-09-28 確認、issue #159)
- 指標 4 の «評価数» は MAS 版のみ。直接配布版には評価の場が無い (Sparkle で
  更新される) ので、出口条件の «評価 30 件» は MAS 版だけで測る
- **Pro の購入系イベント (`pro_*`) は MAS 版のみ** (直接配布版は Pro 無料開放で
  購入 UI が存在しない)。`pro_upsell_view` は «ロック行が表示された» 回数で、
  パネルを開くたびに数える (impression)。0.26.0 〜 0.26.x は Pro 関連イベントが
  無いため、ファネルの暗黒期間になる — 0.27.0 以降のデータだけで読む
- 要約系 (`summary_*`) は両チャネルで発火する。直接配布版は Pro 無料開放のため
  `summary_skip` の `pro_required` は原則 MAS 版でしか現れない
