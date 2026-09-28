# リリースノート (curated 変更履歴)

リリースごとの変更履歴を `v<VERSION>.md` (例: `v0.8.2.md`) という名前の markdown で
このディレクトリに置きます。リリース PR に含めてコミットしてください。

このファイルは 2 箇所に展開されます (issue #283):

1. **GUI の更新ダイアログ (Sparkle)** — `scripts/release/sign.sh` が
   `scripts/release/render-release-notes.py` で HTML に変換し、appcast の
   `<description sparkle:format="html">` に埋め込みます
2. **GitHub Release の本文** — `release.yml` が本文の先頭に組み込みます
   (従来の「Release 作成後に本文へ手動追記」は不要です)

対応する markdown 記法 (見出し・箇条書き・フェンスコードブロック・水平線 `---`・
`**強調**` / `` `コード` `` / `[リンク](https://…)` / ベア URL の自動リンク) は
`scripts/release/render-release-notes.py` の docstring を参照してください。
ネストした箇条書きは対応していません。

ファイルが無いリリースでは、更新ダイアログに GitHub Release への誘導文が
表示されます (ビルドは失敗しません)。**空のファイルは失敗します** —
書き忘れに気付けるようにするためです。
