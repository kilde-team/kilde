# デモ動画 — 絵コンテと生成手順 (kilde-site#1)

60 秒のデモ動画の絵コンテと生成手順。**制作は docs/appstore/tools/video.py による
自動生成** (issue #399。当初想定の「人間が実機を撮影する」方式から変更 — 実機撮影は
ダミー会議の用意・権限・映り込み管理が人手に依存して失敗しやすく、モック生成は
App Store 用スクリーンショットと同じパイプライン (docs/appstore/) のビジュアルを
そのまま動かせるため。UI を変えた再生成もコマンド 1 回になる)。
この動画が [kilde-site#1](https://github.com/kilde-team/kilde-site/issues/1)
の素材 «デモ動画 ❌» を埋める。

## 制約 (kilde-site#1 のスコープより)

- **実在の会議サービスのロゴ・ウィンドウ名を映さない** (App Store 審査対策)。会議は
  ダミーウィンドウ («週次定例 — ビデオ会議»、参加者名はダミー) で演じる
- 日本語版と英語版 = **同一タイムライン + 字幕と UI 文言の差し替え**で作る
  (video.py が両言語を別々にレンダリングする)
- App Store のプレビュー動画仕様 (2026-10 確認): **1920×1080 (16:9)・15〜30 秒・
  H.264 ≤30fps・AAC ステレオ**。60 秒マスターから hook / nobot〜transcript /
  エンドカード (`endcard30`) を残して短縮した派生版 (29.9 秒) を作る — エンドカードは
  URL ではなくサブタイトルと同じ文言に差し替える (録画同意の注意 1 行はどちらの版にも
  入れる)
- Product Hunt のギャラリーは 16:9 (最低 1270×760) — 生成物 1920×1080 をそのまま
  使える (旧案の «2880×1800 で撮って投稿者がクロップ» は不要になった)
- **音源 (BGM) は入れない**: 権利クリアの曲選びは人間の判断が必要で、サイト側の
  video 要素は無音でも成立するため。必要になったらマスター生成時に音声トラックを
  追加する (App Store 版は仕様上 AAC ステレオを敷いている — 無音)

## 絵コンテ (60 秒)

シーン key は video.py の `TL_MASTER` / `TL_APPSTORE` に対応する。

| # | key | 時間 | 画面 (何が見えるか) | 字幕 (ja) | 字幕 (en) |
|---|---|---|---|---|---|
| 0 | hook | 0:00-0:04 | ダミー会議ウィンドウ «週次定例» が開いたデスクトップ。左にタイトルキャプション | (導入) 会議も、その声も、まるごと。 | The whole meeting. Every voice. |
| 1 | nobot | 0:04-0:10 | メニューバーの kilde アイコンをクリック → ポップオーバーが開く (収録対象の選択肢が見える) | 会議に、ボットは要らない。 | No bots in your meetings. |
| 2 | start | 0:10-0:17 | «録画開始» をクリック → 録画中パネルへ切替 | ワンクリックで録画開始。システム音声もマイクも。 | One click. System audio and your mic. |
| 3 | recording | 0:17-0:25 | 録画中のタイマー (00:00:04 → 00:08:12 のタイムラプス。start シーンの実時間の進行から連続する) と音量インジケータ («システム音声» と «マイク» の 2 系統)。会議ウィンドウでは話者グリーン枠が交互に移る | 相手の声も自分の声も、1 つのファイルに。 | Their voice and yours, in one file. |
| 4 | stop | 0:25-0:32 | «停止» をクリック → «仕上げ中…» → **完了通知 (ファイル名・長さ・サイズ)** が届く | 止めた瞬間にファイナライズ。完成したら通知。 | Hit stop — it finalizes, then tells you. |
| 5 | transcript | 0:32-0:41 | 画面が .md エディタに切替。議事録 (Markdown) の文字起こし行が «相手»/«自分» ラベル付きで流れる | トラックを分けて録ると、文字起こしに話者ラベル。 | Split tracks, labeled transcripts. |
| 6 | summary | 0:41-0:48 | 議事録が要約ブロックまでスクロール。«この処理は端末内だけで行われます (macOS 26 以降)» のバッジ | 要約も自動で、端末内。内容は外に出ません。 | Summaries too, on device. |
| 7 | export | 0:48-0:54 | エディタが左に寄り、書き出し先フォルダ (~/Meetings) に .mp4 と .md が並ぶ (.md に «自動保存») | 議事録は指定フォルダへ自動書き出し。 | Minutes auto-export to your folder. |
| 8 | endcard | 0:54-1:00 | エンドカード: kilde ロゴ + «kilde» + «会議を録って、議事録まで。» + kilde.site。画面隅に録画同意の注意 1 行 | 注意: 録画の同意は、あなたの責任で。 | Recording consent is your responsibility. |

- ショット 6 の要約は Pro 化予定の機能 (#163)。**動画では価格や «無料» «Pro» の
  区分に触れない** (launch README の文面ルール — «将来の価格・ライセンスを保証しない»)
- «Ctrl+C でも壊れない» は **CLI の強み** — GUI の場面では語らない (誤解を招くため)
- «Nothing leaves your Mac» のような絶対表現は使わない — モデルのダウンロード時に
  Apple と通信するため。主張は «録音・文字起こし・要約の**内容**が端末外へ出ない» に
  限定する (ショット 6 のバッジ文言 «この処理は端末内だけで行われます» はこの範囲)
- App Store 版 (29.9 秒) は hook / nobot / start / recording / stop / transcript /
  エンドカード (`endcard30`) の構成。エンドカードはサブタイトル «システム音声ごと
  録って文字起こし» / "Record & transcribe meetings" と**録画同意の注意 1 行**のみ
  (URL は無し — どちらの版も会議録画を勧める文面を含むため、同意の注意は省かない)
- 文字起こし・要約の前提条件 (macOS 26 以降 / 要約は Apple Intelligence が有効な Mac) は
  該当シーンの字幕下に注記行として表示する (大きな字幕に OS バージョンを織り込むと
  読みにくくなるため分けている)

## 生成と検証 (docs/appstore/tools/video.py)

```sh
python3 -m pip install playwright && python3 -m playwright install chromium
cd docs/appstore/tools
python3 icon.py ../icon && python3 render.py    # png/icon_1024.png (未生成なら)
python3 video.py --stills                       # 各シーンの代表フレーム (確認用)
python3 video.py                                # 4 本を生成 (60s ja/en + 30s ja/en)
```

- 出力先は `docs/appstore/video/` (コミットしない — 下の «納品» どおり kilde-site 側で管理)。
  ファイル名: `kilde-demo-60s-{ja,en}.mp4` / `kilde-demo-appstore-{ja,en}.mp4`
- 1920×1080・30fps。App Store 版は H.264 High 10Mbps + 無音 AAC 256k ステレオ、
  60 秒版は CRF 21 (faststart)
- すべてのアニメーションはフレーム番号から決定論的に計算する (CSS アニメーション
  不使用)。**実時間依存の要素を足さないこと** — 再生成の再現性が失われる
- 検証: `--stills` の代表フレームを OCR して (macOS なら Vision.framework)、
  各シーンで期待する字幕・UI 文言が写っていることと、他社商標・実在サービス名が
  写っていないことを確認する。文言はこのファイルの表と
  [appstore/README.md](../appstore/README.md) §2 の規約 (訴求は保証範囲内) が正本

### 納品

- 60 秒版とポスター画像 (動画の hook フレーム) を kilde-site リポジトリの
  `public/assets/demo/` にコミットし、トップページ (日英) に `preload="none"` の
  video 要素で掲載する (kilde-site#1 の受け入れ条件)
- App Store 版は次のバージョン (編集可能な状態) で App Store Connect の
  App Preview に ja / en とも登録する — 現行バージョンが審査中の間は
  メタデータが編集できないため

## 実機撮影に差し替えるとき (参考)

video.py のモックは ContentView.swift の再現のため、実機と完全に同一ではない
(フォント・レイアウトの細部)。将来、あえて実機キャプチャに差し替える場合は
元の撮影チェックリストを使う:

- ダミー会議ウィンドウ (実在サービス不使用・ダミー参加者名)、デスクトップの整理
  (無地の壁紙・Do Not Disturb・個人情報が写らない)、トラックは «ソースごとに分離»
  (話者ラベルのため)、«録画後に文字起こし»«録画後に要約も作る» をオン
- ダミー発話はヘッドホンで再生 (`say -o` 等で作成。スピーカー再生だとマイクに
  回り込み、分離トラックと話者ラベルが汚れる)
- 2880×1800・60fps・H.264 で撮影し、16:9 へのクロップは編集時に実施

## 事実の正本

- 機能の記述は README.md / docs/DESIGN.md のとおり («QuickTime Player が録れない
  システム音声» / «Ctrl+C でもファイナライズ» / 文字起こしは macOS 26 の Speech /
  要約はオンデバイスの Foundation Models)
- «一切送らない» 系の主張は PRIVACY.md の記述範囲で言う。超えた言い方 («100% 安全» 等)
  はしない
