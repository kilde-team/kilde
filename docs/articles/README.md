# docs/articles — kilde の紹介記事

issue #158 の記事原稿。公開先は次の 3 本構成:

| ファイル | 公開先 | 読者 | 内容 |
|---|---|---|---|
| `1-zenn-screencapturekit-app-audio.md` | Zenn (技術記事) | macOS / Swift エンジニア | ScreenCaptureKit でアプリ単位のシステム音声を録る実装の勘所 |
| `2-zenn-speechanalyzer-transcribe.md` | Zenn (技術記事) | macOS / Swift エンジニア | macOS 26 の SpeechAnalyzer で会議録音を文字起こしする |
| `3-note-private-meeting-minutes.md` | note | 会議の議事録に困っている人 | 機密性の高い会議をクラウドに上げずに議事録化する |

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
- note 原稿の先頭にある «この記事について» ブロックは内部注記。
  公開版からは除いてある
- 記事を修正するときは、保存用原稿と公開版の両方を更新する

## 更新時の確認事項

- kilde のバージョン・挙動の表記が記事執筆時点 (2026-09-28) とずれていないか
  (特に文字起こしの対応 macOS 版。現在は macOS 26 以降)
- スクリーンショットを入れる場合は実在の会議サービスのロゴ・ウィンドウ名を
  映さない (kilde-site#1 と同じ App Store 審査対策)
- 外部リンク (kilde.site / App Store / Apple ドキュメント) のリンク切れ
- 記事 2 冒頭の前回記事リンクが記事 1 の公開 URL を指すこと
- Apple の商標表記: QuickTime Player などは識別のために言及するのみ
