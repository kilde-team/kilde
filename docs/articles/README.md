# docs/articles — kilde の紹介記事

issue #158 で公開した記事 3 本と、issue #312 で追加した公開前の原稿 6 本:

| ファイル | 公開先 | 読者 | 内容 | 状態 |
|---|---|---|---|---|
| `1-zenn-screencapturekit-app-audio.md` | Zenn (技術記事) | macOS / Swift エンジニア | ScreenCaptureKit でアプリ単位のシステム音声を録る実装の勘所 | 公開済み |
| `2-zenn-speechanalyzer-transcribe.md` | Zenn (技術記事) | macOS / Swift エンジニア | macOS 26 の SpeechAnalyzer で会議録音を文字起こしする | 公開済み |
| `3-note-private-meeting-minutes.md` | note | 会議の議事録に困っている人 | 機密性の高い会議をクラウドに上げずに議事録化する | 公開済み |
| `4-devto-screencapturekit-app-audio-en.md` | dev.to | 英語圏の macOS / Swift エンジニア | 記事 1 の英語版 | 原稿 (#312) |
| `5-devto-speechanalyzer-transcribe-en.md` | dev.to | 英語圏の macOS / Swift エンジニア | 記事 2 の英語版 | 原稿 (#312) |
| `6-devto-private-meeting-minutes-en.md` | dev.to (第一候補) | 英語圏の利用者 | 記事 3 の英語版 (クラウドに上げない議事録) | 原稿 (#312) |
| `7-qiita-screencapturekit-app-audio.md` | Qiita | macOS / Swift エンジニア | 記事 1 のクロスポスト | 原稿 (#312) |
| `8-qiita-speechanalyzer-transcribe.md` | Qiita | macOS / Swift エンジニア | 記事 2 のクロスポスト | 原稿 (#312) |
| `9-note-mac-meeting-recording-howto.md` | note | 会議の録音に困っている人 | «QuickTime では会議の相手の声が録れない» を解消する how-to | 原稿 (#312) |

英語版 (4〜6) は Show HN / Product Hunt ローンチ (issue #157) の英語圏読者の
着地先を想定している。

## 公開済み記事

- [ScreenCaptureKit で「アプリ単位のシステム音声」を録る — macOS の画面収録 API の勘所](https://zenn.dev/takezou621/articles/a7f3df15b3a9ff) (Zenn)
- [macOS 26 の SpeechAnalyzer で会議録音を文字起こしする — ファイルから PCM を流し込むときの注意](https://zenn.dev/takezou621/articles/7a8de3ca6ccb59) (Zenn)
- [機密性の高い会議を、クラウドに上げずに議事録にする](https://note.com/quiet_lilac7877/n/nf58dbb6e6a76) (note)

いずれも kilde の利用・実装を題材にした紹介記事で、末尾に kilde.site への導線を置いてあり、
記事 1・2 の末尾には Mac App Store へのリンクも置いてある (issue #158 のスコープ)。

## 原稿と公開版の扱い

- Zenn 2 本の Markdown はリポジトリ内の保存用原稿。front matter の
  `published: false` はこのリポジトリからの意図しない再公開を防ぐため維持する。
  公開版は上記 URL の Zenn エディタで管理する
- 英語版 3 本 (4〜6) も同様に `published: false` で保存する原稿
  (4・5 は dev.to 形式の YAML front matter、6 は dev.to を第一候補とした共通
  Markdown)。各ファイル先頭の «この原稿について» ブロックは内部注記なので、
  公開時に削除する (dev.to の front matter は YAML 形式 — `key: value` — で書く)
- 記事 4・5 は翻訳版として canonical を付けていない (言語違いの canonical
  指定は英語ページが検索結果から外れるおそれがあるため)。
  翻訳の出自は本文冒頭の «English version of my Zenn article» 注記で示す
- 記事 6 は note 版の実質的な改稿 (翻訳) なので canonical を付けていない。
  公開先を最終決定するときに要否を判断する
- 記事 7・8 (Qiita クロスポスト) は Zenn 版と同一本文。公開するときは
  Qiita の記事設定 «canonical URL» に Zenn 版の URL を設定する
  (手順は各ファイル先頭の注記ブロックに書いてある)。
  **Zenn 版を修正したときはこの 2 ファイルも見直す**
- note 原稿 (3・9) の先頭にある «この記事について» ブロックは内部注記。
  公開版からは除いてある
- 記事を修正するときは、保存用原稿と公開版の両方を更新する

## 公開時のチェックリスト (issue #312 追加分)

- 英語版 4・5 は前後編なので、公開時に相互のリンクを公開 URL で張る
- 記事 6 の公開先確定 (dev.to / Medium / kilde.site blog) と canonical の要否
- 記事 7・8 の canonical URL 設定 (Zenn 版の URL)
- 英語版の機能表記が公開時点の仕様とずれていないか
  (文字起こしは macOS 26+、要約は Apple Intelligence 対応 Mac、
  対応環境は Apple Silicon / macOS 14+、トラック分離時のみ話者ラベル)

## 更新時の確認事項

- kilde のバージョン・挙動の表記が記事執筆時点 (#1〜3: 2026-09-28、
  #4〜9: 2026-10-06) とずれていないか (特に文字起こしの対応 macOS 版。
  現在は macOS 26 以降)
- スクリーンショットを入れる場合は実在の会議サービスのロゴ・ウィンドウ名を
  映さない (kilde-site#1 と同じ App Store 審査対策)
- 外部リンク (kilde.site / App Store / Apple ドキュメント) のリンク切れ
- 記事 2 冒頭の前回記事リンクが記事 1 の公開 URL を指すこと
- Apple の商標表記: QuickTime Player などは識別のために言及するのみ
