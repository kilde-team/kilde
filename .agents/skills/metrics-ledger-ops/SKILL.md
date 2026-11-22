---
name: metrics-ledger-ops
description: >-
  Use this skill when updating the measurement ledgers of kilde: the ASC weekly
  ledger (docs/appstore/metadata/metrics.md), the IAP monthly ledger and KPI
  definitions (docs/metrics.md), fixing measurement windows for metadata change N,
  finalizing via Sales Report, and recording "no data / not decidable" honestly
  (never fabricating numbers).
---

# 計測台帳運用 (ASC 週次台帳 / IAP 台帳)

App Store の計測台帳の記入・確定手順。正本は 2 つ:

- **KPI 定義・月次台帳・IAP 台帳**: [docs/metrics.md](../../../docs/metrics.md) (issue #159 / #598)
- **ASC メタデータ変更前後の週次台帳**: [docs/appstore/metadata/metrics.md](../../../docs/appstore/metadata/metrics.md) (issue #160)

**数値の正本は Firebase コンソールと App Store Connect で、台帳はその記録**。
台帳自体が数値を生成しない。

## 1. いつ使うか

- メタデータ変更 (変更 N) の反映後、前後比較の週次表を記入するとき
- 月次の振り返り (docs/metrics.md「月次の振り返り手順」。月初の第 1 月曜推奨)
- IAP 台帳への月次追記 (Sales Report の確定後)
- mas-watch.yml の «承認済み — metrics 記入» issue の対応

## 2. 変更 N の計測期間の固定方法

台帳に新しい変更を書くときは、次の 3 点を**その行に明記**する (先例: 変更 1〜6):

1. **反映日** = バージョンの承認・公開日。**JST の日付に加えて時刻も記録する**
   (iTunes Lookup の `currentVersionReleaseDate` の UTC ISO 表記。
   例: `2026-11-19T22:10:58Z` = JST 11-20 07:10)。公開日の日次値は**公開前後が
   混在する日**なので、週次表に含めるときは «気づき» にその旨を注記する
2. **基準期間** = «前の計測対象変更の反映日» 〜 «今回の反映日前日»
   (今回より前の最後の計測対象変更。What's New のみの版は計測対象外なので飛ばす)。
   **前の変更と同じ JST 日に反映された場合は基準期間が成立しない**
   (比較終了日の前日が反映日より前になる) — «基準期間なし・判定不可» と明記し、
   始まりが終わりより後の窓を作らない
3. **比較終了日** = 反映日 + 4 週間。ただし**その窓に次の変更が入るなら、
   比較は次の変更の反映日前日までで打ち切る** (変更 2 が変更 3 で 10-02 打ち切り、
   変更 4 が変更 5 で 11-19 打ち切りの前例)。窓がほぼ潰れたら «実質 1 日» と
   明記し、以後は合成効果として読む («読み方の注意» の条項)

What's New のみ更新の版は**計測期間を設けない** (計測対象 = 説明 / キーワード /
サブタイトル / スクショ / App Preview は不変)。主に見る指標も変更の種類で決める:
動画 → ユニークページ閲覧と CVR (変更 4)、キーワード → 検索経由と CVR (変更 6)。

## 3. Sales Report での確定手順 (IAP 台帳)

前月分の確定は**翌月月初**に行う (地域ごとに翌日 5am PT まで配信。JP はその後)。

1. ASC API の Sales Report を呼ぶ (docs/metrics.md「取得方法」)。クエリは
   **`filter[...]` 形式** (docs/metrics.md と同じ) で、
   **`Accept: application/a-gzip` ヘッダーが必須** (無いと API が拒否する):

   ```
   GET https://api.appstoreconnect.apple.com/v1/salesReports?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY&filter[vendorNumber]=85006198&filter[reportDate]=YYYY-MM-DD
   Accept: application/a-gzip
   ```
2. **月次の値は前月 1 日〜末日の各日付で `reportDate` を変えて呼び、
   日次 TSV を集計して作る** (API は 1 回で 1 日分)。末日分が揃ってから台帳に
   記入する
3. kilde の行だけを抜く — **2 つのフィルタを併用する** (docs/metrics.md「取得方法」):
   **アプリ本体**は SKU `kilde-mas`、**IAP** は SKU が `kilde.` で始まる行
   (Product Type Identifier **IA1 / IA1-M / FI1**)。IAP 行を `kilde-mas` だけで
   絞ると、購入があった月も販売 0 と記録してしまう。DL 系は **F1 / F3 / F7**
   (F1 = 初回 DL の代理指標 — ASC 分析の «初回ダウンロード» とは定義が異なる
   近似値。トレンド用)
4. `Developer Proceeds` の通貨は行ごとの `Currency of Proceeds` で読む
   (常に USD ではない。換算が必要なら通貨ごとに分けて明示的に変換)
5. 台帳の 1 行として追記: 販売列・F1 列・転換率は**すべて当月の値**で揃える
   (分子と分母の窓をずらさない)。取得日と未配信区間を«気づき»に併記する
   (2026-11 行の前例: «11-18 以降はレポート未配信»)
6. 母数が小さいときは率で判断しない — «サンプル N 件で統計的な判定は不可» と書き、
   判定できる母数になるまで追う。**«2%» 出口条件の判定に使う分母は ASC 分析
   (App Analytics) の «初回ダウンロード»** (正本 — docs/metrics.md 指標 6)。
   Sales Report の F1 は定義の異なる代理指標のため、F1 比は**トレンド値**として
   扱い、出口判定の分母には使わない («ASC 側» とだけ書くと Sales Report で
   判定してしまうので、どこを見るかを明記する)

## 4. GA4 の現状と「データなし・判定不可」のルール

- **GA4 Data API への自動取得は現在閉じている** (2026-11-19 実測 — issue #598 / #611):
  共有 OAuth クライアントに `analytics.readonly` スコープが未登録、サービス
  アカウント経路も不通。**オーナーが GA4 プロパティ (555463514) へ SA Viewer を
  追加するまで再開しない** (#611 で待ち。再開を勝手に試みない)
- 代替は GA4 コンソール (kawai@muse.ai) からの手動読み取りのみ
- **取得できない値は捏造しない**。台帳には `未取得` / `データなし` / `判定不可` と
  明記し、理由 (取得経路が閉じている等) と取得日を 1 行で添える
  (2026-11 の月次台帳行が書式の前例)。«前月と同じはず» という推測値や、
  妥当そうな近似値を記入しない
- «計測の限界» (docs/metrics.md) の注意も守る: `recordings_bucket` の分布は
  «ユーザー × 値» の行で行合計をユニーク数として読まない、CLI / Homebrew チャネルは
  計測されない、`pro_*` は MAS 版のみ、など

## 5. 検証

- 記入した行は**取得方法・取得日・窓**が他の人が追試できる形になっていること
  (どの画面 / どの API を見たかを書く)
- ASC 分析 (App Analytics) の値は CSV エクスポートか API
  (`analyticsReportRequests` — 2026-11-19 に生成開始済み) で取る。
  **API は生成設定 以降の日にしか値が無い** — それより前の窓 (変更 1〜3 など) は
  ASC 分析の CSV エクスポートで取得する (API で過去窓を取れると誤解して
  日次データの欠けた台帳を確定しない)
- 台帳の編集は PR で行い、数値の出所 (issue / run / レポート名) を PR 本文に書く

## 6. 禁止事項

- 数字の捏造・推測値の記入 (取得できなければ «未取得» と書く)
- 定義と異なる窓での比較 (月混在の累計と当月値の併記、基準期間の読み替え)
- App Privacy ラベルや IAP 申告の変更を台帳作業についでに行う
  (申告変更は依頼者の指示が前提 — 本スキルのスコープ外)
- GA4 自動取得の再実装・再試行 (#611 の再開条件を満たすまで)
