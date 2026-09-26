# App Store Connect のローカライズメタデータ (issue #137 / #160)

App レコード (`com.takezou621.KildeGUI`, Apple ID `6812783176`) の App Store
表示用テキストの正本。ASC 側で直接編集するとリポジトリと乖離するため、
**変更はまずここで行い、ASC へ転記する**。

## 対応ロケールとファイル

| ロケール | ファイル | 状態 |
|---|---|---|
| 日本語 (ja) | [metadata-ja.md](metadata-ja.md) | 0.3.0〜0.6.0 審査通過版から #160 で書き直し (2026-09-26、0.8.1 提出時に反映) |
| 英語 (en-US) | [metadata-en.md](metadata-en.md) | 同上 (#160 で書き直し) |
| 簡体字中国語 (zh-Hans) | [metadata-zh-Hans.md](metadata-zh-Hans.md) | 同上 (#160 で書き直し) |
| 韓国語 (ko) | [metadata-ko.md](metadata-ko.md) | 同上 (#160 で書き直し) |
| スペイン語 (es-ES) | [metadata-es.md](metadata-es.md) | 同上 (#160 で書き直し) |

#160 の書き直しの内容: ①文字起こし・要約 (0.8.1) を前面に出す構成、
②**他社の商標 (Zoom 等の会議サービス名・BlackHole 等の製品名) を説明と
キーワードから除去**、③サブタイトルを「録って文字起こし」系に変更
(ロケールごとの新サブタイトルは各ファイル)。変更前後の効果計測は
[metrics.md](metrics.md)。

## ASC の現状 (2026-09-26 時点)

- **0.6.0 が WAITING_FOR_REVIEW** (2026-09-26 に asc-submit の API 読み取りで確認)。
  0.5.0 (6) まで承認・配信中。**審査中のバージョンのメタデータは編集できず、
  次のバージョン (0.8.1) も 0.6.0 の承認まで作成できない**ため、#160 の新文面は
  0.8.1 のバージョンを作成してから反映する
- 0.6.0 に登録済みの文面は旧文面 (キーワードに Zoom を含む) で、そのまま審査に
  通る見込み (0.4.0 / 0.5.0 が同一キーワードで承認済み)
- ja は ASC が先にあった経緯があり、名前だけ「先頭を `kilde` に統一」の方針から
  外れているが、配信中のアプリ名を変えると検索・認知に影響するため、このまま
- App Privacy は Firebase Analytics + Crashlytics に合わせて「おおよその場所・
  デバイス ID・製品の操作 (アナリティクス) + 診断のクラッシュデータ」で公開済み
- **0.5.0 のスクリーンショットは `../screenshots/` の現行 6 枚** (06 に文字起こしを
  追加、issue #155 系)。ASC にアップロードするときは 1 枚ずつ順に上げる
  (まとめて上げると並び順が崩れる)

### #160 の新文面を ASC へ反映する手順 (0.6.0 承認後)

1. `asc-submit create-version 6812783176 --version 0.8.1` で次バージョンを作成
2. `python3 scripts/release/appstore-spec.py --version 0.8.1 --build <N>` で spec を
   生成し、`asc-submit run 6812783176 --spec …` で説明・新着情報・スクリーンショット
   を反映 (提出は `--submit` を付けたときだけ)
3. **サブタイトルとキーワードは asc-submit 未対応** (2026-09-26 時点の spec は
   whatsNew / descriptions / reviewNotes / screenshots のみ。ASC API では
   キーワードが appStoreVersionLocalizations、サブタイトルが appInfoLocalizations
   に属し、後者はバージョンをまたぐ)。下の「ASC での追加手順」どおり手動で
   転記するか、asc-submit への対応追加 (takezou621/asc-submit) を先に済ませる
4. 効果計測のため、反映日を [metrics.md](metrics.md) に記録する

## ASC での追加手順 (手動転記の場合)

1. App Store Connect → 対象 App →「App情報」→「ローカライズ」→「編集」
2. 各ロケールの「アプリ名」「サブタイトル」を確認する (名前は #160 では変えていない)
3. バージョンページで各ロケールに「説明」「キーワード」を転記する
   (上限: 名前 30 / サブタイトル 30 / 説明 4000 / キーワード 100 文字)。
   **転記前に各ファイルの文字数を機械で確認すること** (CodeRabbit レビュー指摘:
   en の名前が 31 文字で超過していた)。確認コマンドは下の「キーワードの上限」参照。
   プロモーションテキストは正本が無いため入力しない (任意項目 — 使う場合は
   まずここにセクションを足してから転記する)
4. 「プライバシーポリシーの URL」「サポート URL」は**ロケールごとに**入力する
   (ローカライズ可能な項目。同じ URL を使う場合も各ロケールの入力欄へ)。
   現行値は `../README.md` §4 の表
5. 保存 → 次のバージョン提出時に反映される

## キーワードの上限は文字数で数える

ASC のキーワード欄の上限は **100 文字** (Apple の App Store Connect リファレンス
"up to 100 characters")。かつてこの README は「UTF-8 で 100 バイト」と書いていたが、
**ja の旧キーワードが 71 文字 / 180 バイトで 0.3.0 に受理され審査も通過した実績**が
あるので、文字数説が正しい。各国語のファイルには文字数とバイト数の両方を記録する。
zh-Hans / ko / es-ES の現行キーワードは、バイト基準の説明とも両立するよう
100 バイト以内にも収めてある (ja は入る語を優先して 100 文字以内にだけ収めた)。

```sh
# 5 ファイルのコードブロックの中身の文字数とバイト数を一覧 (出力の順序は各ファイルの
# セクション順 — ja なら 名前/サブタイトル/説明/キーワード/URL…)
python3 -c 'import re,glob
for f in sorted(glob.glob("metadata-*.md")):
    for b in re.findall(r"```text\n(.*?)\n```", open(f).read(), re.S):
        print(f, len(b), len(b.encode("utf-8")))'
```

## 注意

- **Apple の製品・サービス名を比較・訴求に使わない** (Guideline 5.2.5)。en-US の
  サブタイトル `Record what QuickTime can't` で 0.4.0 (5) がリジェクトされた
  (2026-09-23、issue #179)。「QuickTime では録れない」のような比較は「標準の画面
  収録では録れない」(en: "the built-in screen recording") の一般表現で書く。
  **互換性の記述** (ScreenCaptureKit / Apple Intelligence / ショートカットアプリに
  対応する旨) は比較・訴求ではないので使ってよい
- **他社の商標を使わない** (issue #160)。キーワードの Zoom は 0.4.0/0.5.0 では
  受理されたが、他社商標を検索取り込みに使うのはリスク (Guideline 2.3.7:
  キーワードへの他社アプリ名の使用禁止) なので #160 で全ロケールから除去した。
  説明も「オンライン会議」等の一般表現に置換済み。転記前に下のコマンドが
  何も出力しないことを確認する。**機械チェックは網羅ではない** — 文面を変えたら
  人の目でも確認する (CodeRabbit レビュー指摘)

  ```sh
  # ASC に転記するコードブロックの中身だけを見る (見出しの「App Store」を拾わないため)。
  # Zoom / Google / Teams 等は単語境界付き (\bmeet\b は meeting にマッチしない)。
  # kilde-team は自社の GitHub org 名なので (?<!kilde-) で除外
  python3 -c 'import re,glob
pat=re.compile(r"quicktime|facetime|imovie|final cut|garageband|keynote|siri|icloud|airdrop|airplay|iphone|ipad|apple ?(tv|watch|music|vision|pay)|app store|\bzoom\b|google|microsoft|(?<!kilde-)\bteams?\b|\bmeet\b|blackhole|\bobs\b|notion|granola|audio ?hijack|\bloom\b|screenflow|camtasia",re.I)
[print(f,m.group()) for f in sorted(glob.glob("metadata-*.md")) for b in re.findall(r"```text\n(.*?)\n```",open(f).read(),re.S) for m in pat.finditer(b)]'
  ```

- **MAS 版の GUI で使えない機能を説明に書かない** (issue #140)。monitor モード
  (BlackHole でのモニタリング) と HDR 収録は CLI (`kilde rec --monitor` / `--hdr`)
  のみの機能。#160 の文面には含めていない — GUI に設定経路を足したら戻す
- **スクリーンショットはロケールごとに独立**。未登録のロケールは ASC が別ロケールの
  ものをフォールバック表示する。現行 6 枚は日本語 UI のモック (`../README.md` §2)
  なので、当面は ja のみ登録し、他ロケールはフォールバックに任せる。
  ローカライズ済みスクリーンショットはフォローアップ (モックの `tools/panel.py` の
  文言差し替えで作れる)
- **プレビュー動画は未登録** (issue #160 のスコープのうち、kilde-site#1 の素材が
  できるまで後回し)。App Store のプレビューは 1 本だけ登録でき、登録すると
  スクリーンショットの最初の 1〜3 枚と差し替わる点に注意
- 「新着情報」(What's New) はバージョンごとに入力するものなので、ここには
  テンプレートを置く。提出時にその版の変更点を各言語で書く
  (appstore-spec.py は「What's New (<version>)」セクションを必須にする)
- アプリ名の先頭は全ロケールで `kilde` に統一する (brew / CLI / GitHub と
  同じ綴りで検索・参照できるようにするため)。ja のみ例外的に `Kilde` のまま
  (上の「ASC の現状」参照)
- アプリ名は 30 文字上限。en の `kilde: Screen & Voice Recorder` は
  em dash + 両側スペースで 31 文字になるためコロン形式 (ちょうど 30 文字) を
  使う — 他ロケールは em dash 形式のまま 30 文字以内に収まる
