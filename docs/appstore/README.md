# App Store 用のアイコンとスクリーンショット

Mac App Store 配布 (App Store Connect の App レコード `com.takezou621.KildeGUI`) で使う
ビジュアル素材の置き場です。**アイコンは本番の成果物**、**スクリーンショットは実機
キャプチャに差し替えるまでのドラフト**という位置づけが違うので、混同しないこと。

## 1. アプリアイコン (本番)

正本はベクタの `icon/kilde-icon-*.svg`。ビルドに入るのは
`gui/Resources/Assets.xcassets/AppIcon.appiconset/` の PNG です。

- **意匠**: 暗いスレートの角丸四角 (超楕円 n=5.9) に、赤い録画ドットと左右へ広がる音波。
  「画面と音声を録る」を 1 つの形で表す。地の暗さは録画中の赤を目立たせるため
- **サイズ別に絵を変えてある**。細い弧は 16px で消えるので、`full` (3 本・≥128px) /
  `mid` (2 本・64px) / `small` (1 本・≤32px) を使い分ける。1 枚を縮小しただけでは
  小サイズがつぶれる
- **1024px は `icon_512x512@2x.png`**。macOS アプリは App Store 用アイコンを別途
  アップロードせず、この 1 枚が製品ページに出る

### ビルドへの結線 (片方だけだと黙ってアイコンなしで通る)

| 場所 | キー |
|---|---|
| `gui/project.yml` | `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` と `sources` への `Resources/Assets.xcassets` |
| `gui/Resources/Info.plist` | `CFBundleIconName` = `AppIcon` |

`LSUIElement` で Dock には出ないが、Finder・通知・「システム設定 > プライバシーとセキュリティ」
の一覧・App Store の製品ページではこのアイコンが使われる。

## 2. スクリーンショット (ドラフト)

`screenshots/*.png` — 2880×1800 (Mac App Store の受け付けサイズ)、5 枚。

**これは実機キャプチャではなく、`gui/Sources/ContentView.swift` の UI を HTML/CSS で
再現したモックです。** 提出前に実機のキャプチャへ差し替えること。フォントが
Noto Sans CJK JP で、macOS 実機の SF Pro / ヒラギノとは字形が違う。

| ファイル | 訴求 |
|---|---|
| `01-capture-system-and-mic.png` | システム音声 + マイクを 1 本のファイルに |
| `02-recording.png` | 録画中の経過時間・レベルメーター |
| `03-window-capture.png` | ウィンドウ単位の収録 |
| `04-audio-only.png` | 音声のみ (M4A) |
| `05-safe-finish.png` | どの終了経路でもファイルを仕上げる |

- **他社の商標を画面に入れない**。ウィンドウ一覧のサンプルは `com.example.*` の
  一般名にしてある。実機キャプチャに差し替えるときも、Zoom / Google Meet / Teams などの
  ウィンドウ名・バンドル ID・ロゴが写り込まないようにすること (App Store の審査で
  指摘されうる)
- リポジトリに入っているのは 256 色に最適化した版 (5 枚で約 2.5MB)。UI 画像なので
  見た目の劣化はほぼ無い。フル品質が要るときは下の手順で作り直す

## 3. 作り直す

`tools/` は Python + Playwright (Chromium) で動く。macOS の Xcode ツールチェーンには
依存しないので、CI でも手元でも同じ絵が出る。

```sh
python3 -m pip install playwright && python3 -m playwright install chromium
cd docs/appstore/tools
python3 icon.py ../icon          # SVG を書き出す (3 バリアント)
python3 render.py                # SVG -> PNG (16〜1024px)
python3 build.py                 # スクリーンショット 5 枚 (2880x1800)
```

`panel.py` がパネルの再現部分。`ContentView.swift` を変えたら、スクリーンショットを
撮り直す前にこちらも合わせること (幅 380pt・padding 12・セクション間 14 は SwiftUI 側の値)。

## 4. App Store Connect 側の状態

App レコードは作成済み (Apple ID `6812783176`)。プライバシー (データ収集なし)・
年齢区分 (4+)・カテゴリ (ユーティリティ / 仕事効率化)・著作権は入力済み。
**説明・キーワード・スクリーンショットの登録と審査提出はまだ**。
プライバシーポリシー URL はリポジトリ URL の仮値のままなので、提出前に専用ページへ
差し替えること。
