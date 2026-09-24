# App Store Connect のローカライズメタデータ (issue #137)

App レコード (`com.takezou621.KildeGUI`, Apple ID `6812783176`) の App Store
表示用テキストの正本。ASC 側で直接編集するとリポジトリと乖離するため、
**変更はまずここで行い、ASC へ転記する**。

## 対応ロケールとファイル

| ロケール | ファイル | 状態 |
|---|---|---|
| 日本語 (ja) | [metadata-ja.md](metadata-ja.md) | 0.3.0 で審査通過・配信中の ASC 登録内容を転記 (2026-09-23) |
| 英語 (en-US) | [metadata-en.md](metadata-en.md) | issue #137 で新規作成、2026-09-23 に ASC へ登録 (0.4.0 から) |
| 簡体字中国語 (zh-Hans) | [metadata-zh-Hans.md](metadata-zh-Hans.md) | issue #137 で追加、2026-09-23 に ASC へ登録 (0.4.0 から) |
| 韓国語 (ko) | [metadata-ko.md](metadata-ko.md) | issue #137 で追加、2026-09-23 に ASC へ登録 (0.4.0 から) |
| スペイン語 (es-ES) | [metadata-es.md](metadata-es.md) | issue #137 で追加、2026-09-23 に ASC へ登録 (0.4.0 から) |

## ASC の現状 (2026-09-23 時点)

- **ja は ASC が先にあった**。#137 で書いた metadata-ja.md は ASC の登録内容と別物だったため、
  ASC の文面に合わせて書き直した (名前 `Kilde`、サブタイトル・キーワードは 0.3.0 の審査通過版、
  説明は 0.4.0 用に Firebase Analytics の開示と MAS 版の設定保存先を反映したもの)。ja の名前だけ「先頭を `kilde` に統一」の方針から外れているが、配信中の
  アプリ名を変えると検索・認知に影響するため、変える場合は別途判断する
- en-US / zh-Hans / ko / es-ES は 0.4.0 (提出準備中) に登録済み。説明は各ファイルの 80 桁の
  折り返し改行を段落内でつないで転記した (ASC は改行をそのまま表示するため)
- **キーワード欄の残数表示は文字数で数える** (ja は 71 文字 / 180 バイトで 0.3.0 が受理・審査
  通過)。下の「100 バイト」はそれより厳しい安全側の目安として残す
- App Privacy は Firebase Analytics に合わせて「おおよその場所・デバイス ID・製品の操作
  (いずれもアナリティクス目的、ユーザに関連付けない、トラッキングなし)」で公開済み
- **0.4.0 の ja スクリーンショットは `../screenshots/` の現行 5 枚に差し替えた**。0.3.0 に
  登録されていたのはそれ以前のモックで、05 は「どう終わっても」の見出しと直接配布版にしか無い
  アップデート欄、01 は「保存先の選択は CLI の既定値としても共有」、05 は「データ収集なし」を
  含んでいた。ASC にアップロードするときは 1 枚ずつ順に上げる (まとめて上げると並び順が崩れる)

## ASC での追加手順

1. App Store Connect → 対象 App → 「App情報」→「ローカライズ」→「編集」
2. 「言語を選択」で **簡体字中国語 (簡体) / 韓国語 / スペイン語 (スペイン)** を追加
   (スペイン語は「スペイン」と「ラテンアメリカ」がある。まず es-ES のみ —
   拡大したくなったらラテンアメリカへ同じ文面を流用する)
3. 各ロケールに「アプリ名」「サブタイトル」「説明」「キーワード」を転記する
   (上限: 名前 30 / サブタイトル 30 / キーワード **100 バイト** / 説明 4000)。
   **転記前に各ファイルの文字数を機械で確認すること** (CodeRabbit レビュー指摘:
   en の名前が 31 文字で超過していた)。**キーワード欄だけは文字数でなく
   UTF-8 バイト長** が上限 (Apple の App Store Connect リファレンス:
   "You can provide up to 100 bytes of content") — 日本語・韓国語・中国語は
   1 文字 3 バイト、スペイン語のアクセント付き文字は 2 バイト。
   `python3 -c 'import re;print([len(x.encode("utf-8")) for x in re.findall(r"```text\n(.*?)\n```", open("metadata-ja.md").read(), re.S)])'`
   のように 5 つのコードブロックの中身のバイト数を一覧で確認する
   (出力の 4 番目がキーワード — 100 以下を確認する)。プロモーションテキストは
   正本が無いため入力しない (任意項目 — 使う場合はまずここにセクションを足してから転記する)
4. 「プライバシーポリシーの URL」「サポート URL」は**ロケールごとに**
   入力する (どちらもローカライズ可能な項目 — Apple のヘルプ:
   Support URL は "required and can be localized"。プライバシーポリシーの
   URL は言語を追加するたびに入力を求められる)。同じ URL を使う場合も
   各ロケールの入力欄に同じ値を入れる。既存ロケールの設定値は
   App 情報の言語を切り替えて確認する
5. 保存 → 次のバージョン提出時に反映される

## 注意

- **Apple の製品・サービス名を入れない** (Guideline 5.2.5)。en-US のサブタイトル
  `Record what QuickTime can't` で 0.4.0 (5) がリジェクトされた (2026-09-23、issue #179)。
  「QuickTime では録れない」のような比較は「標準の画面収録では録れない」
  (en: "the built-in screen recording") のような一般表現で書く。
  転記前に下のコマンドが何も出力しないことを確認する。**これは既知の名前の機械チェックで網羅ではない**
  (Apple の製品・サービス名は多い)。文面を変えたら、比較・訴求に Apple の製品名を
  使っていないかを人の目でも確認する (CodeRabbit レビュー指摘)

  ```sh
  # ASC に転記するコードブロックの中身だけを見る (見出しの「App Store」を拾わないため)
  python3 -c 'import re,glob;pat=re.compile(r"quicktime|facetime|imovie|final cut|garageband|keynote|siri|icloud|airdrop|airplay|iphone|ipad|apple ?(tv|watch|music|vision|pay)|app store",re.I);[print(f,m.group()) for f in sorted(glob.glob("metadata-*.md")) for b in re.findall(r"```text\n(.*?)\n```",open(f).read(),re.S) for m in pat.finditer(b)]'
  ```
- **スクリーンショットはロケールごとに独立**。未登録のロケールは ASC が
  別ロケールのものをフォールバック表示する。現行の 5 枚は日本語 UI の
  モック (`../README.md` §2) なので、当面は ja のみ登録し、他ロケールは
  フォールバックに任せる。ローカライズ済みスクリーンショットは
  フォローアップ (モックの `tools/panel.py` の文言差し替えで作れる)
- 「新着情報」(What's New) はバージョンごとに入力するものなので、ここには
  テンプレートを置く。提出時にその版の変更点を各言語で書く
- アプリ名の先頭は全ロケールで `kilde` に統一する (brew / CLI / GitHub と
  同じ綴りで検索・参照できるようにするため)
- アプリ名は 30 文字上限。en の `kilde — Screen & Voice Recorder` は
  em dash + 両側スペースで 31 文字になるため **`kilde: Screen & Voice Recorder`**
  (ちょうど 30 文字) を使う — 他ロケールは em dash 形式のまま 30 文字以内に収まる
