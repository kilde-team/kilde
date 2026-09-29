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
| 2 | 定着率 (録画完了 3 回以上のユーザー率) | ユーザー プロパティ `recordings_bucket` が `3_5` / `6_9` / `10_plus` のユーザーの割合。**分母は `recordings_bucket` が設定されたユーザー全体** (アプリを起動したことがあるユーザー。0 回のユーザーは `0` に入る) | Firebase コンソール → ユーザー プロパティ → `recordings_bucket` の分布 | 未定 — ベースラインを 3 か月取ってから決める |
| 3 | 文字起こし利用率 | 過去 30 日に `transcription_complete` を送ったユーザー数 ÷ 同じ窓で `recording_complete` を送ったユーザー数 | Firebase コンソール → イベントのユーザー数 (両イベント) | 未定 (同上) |
| 4 | App Store の評価数 | MAS 版の評価 (レーティング) の累計件数 | App Store Connect → 分析 (概要の App Store 評価) と「評価とレビュー」(星別の件数) | **30** (#161 の出口条件) |
| 5 | チャネル別の内訳 | `recording_complete` の `channel` パラメータとユーザー プロパティ `distribution_channel` (`mas` / `direct`) の分布 | Firebase コンソール (イベントのパラメータ / ユーザー プロパティ) | 目標なし (参考値) |

## 送っているイベントとユーザー プロパティ

実装は `gui/Sources/UsageAnalytics.swift`。**セルフテストと Debug 構成では
送らない** (AppDelegate.sendsUsageToFirebase、issue #219)。

- イベント: `app_open`、`recording_complete` (パラメータ: `recording_length`、
  `channel`)、`transcription_start` / `transcription_complete` / `transcription_fail` /
  `transcription_cancel` / `transcription_retry` (パラメータ: `recording_length`、
  `processing_time`、`error_kind`)
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

## 月次の振り返り手順 (毎月 1 回。月初の第 1 月曜を推奨)

前月分のレポートが確定してから行う (ユーザー プロパティの反映は数時間〜
1 日遅れるため、1 日の朝にやると前月末分が欠ける恐れがある)。

1. Firebase コンソール → イベント: 過去 30 日の `recording_complete` と
   `transcription_complete` のユーザー数を記録する (指標 1・3)
2. ユーザー プロパティ: `recordings_bucket` の分布から、**全値のユーザー数の合計を
   分母に** `3_5` / `6_9` / `10_plus` の合計の割合を定着率として記録する (指標 2)
3. ユーザー プロパティ: `distribution_channel` の分布を記録する (指標 5)
4. App Store Connect: 評価の累計件数と平均を記録する (指標 4)
5. [appstore/metadata/metrics.md](appstore/metadata/metrics.md) の
   ASC 週次台帳が埋まっていれば、その月の初回 DL 合計を台帳の「気づき」に添える
   (#160 の計測と混ぜすぎない — リンクするだけでもよい)
6. 下の台帳に 1 行追記し、前月との差分と気づきを書く
7. 出口条件から遠ざかっている場合は、対処の issue を起票する
   (施策の候補はロードマップの #157 / #158 など)

## 月次台帳

| 月 | 録画完了ユーザー (30 日) | 定着率 (3 回以上) | 文字起こし利用率 | 評価数 (累計) | mas / direct | 気づき |
|---|---|---|---|---|---|---|
| (2026-10) | | | | | | 初回計上。`recording_complete` は 0.8.2 以降のビルドから |

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
