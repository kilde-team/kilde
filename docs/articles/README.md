# docs/articles — kilde の紹介記事 (下書き)

issue #158 の下書き置き場。公開先は次の 3 本構成:

| ファイル | 公開先 | 読者 | 内容 |
|---|---|---|---|
| `1-zenn-screencapturekit-app-audio.md` | Zenn (技術記事) | macOS / Swift エンジニア | ScreenCaptureKit でアプリ単位のシステム音声を録る実装の勘所 |
| `2-zenn-speechanalyzer-transcribe.md` | Zenn (技術記事) | macOS / Swift エンジニア | macOS 26 の SpeechAnalyzer で会議録音を文字起こしする |
| `3-note-private-meeting-minutes.md` | note | 会議の議事録に困っている人 | 機密性の高い会議をクラウドに上げずに議事録化する |

いずれも kilde の利用・実装を題材にした紹介記事で、
末尾に kilde.site と Mac App Store への導線を置いてある (issue #158 のスコープ)。

## 公開手順

1. **Zenn 2 本**: front matter つきの Markdown。`published: false` で置いてあるので、
   内容を確認して `published: true` に変えてから Zenn の GitHub 連携リポジトリ
   (使っていれば `articles/` にコピー) か、Zenn のエディタに本文をコピペして公開する。
   `topics` は 5 個まで有効
2. **note 1 本**: front matter はない。本文を note のエディタに貼り、
   見出し構成を note の UI に合わせて調整する。先頭の «この記事について» ブロックは
   note の書き出し時には外してよい (リポジトリ側の注記)
3. 公開したら URL をこの README に追記し、issue #158 の受け入れ条件を満たす

## 公開前の確認事項

- kilde のバージョン・挙動の表記が記事執筆時点 (2026-09-28) とずれていないか
  (特に文字起こしの対応 macOS 版。現在は macOS 26 以降)
- スクリーンショットを入れる場合は実在の会議サービスのロゴ・ウィンドウ名を
  映さない (kilde-site#1 と同じ App Store 審査対策)
- 外部リンク (kilde.site / App Store / Apple ドキュメント) のリンク切れ
- Apple の商標表記: QuickTime Player などは識別のために言及するのみ
