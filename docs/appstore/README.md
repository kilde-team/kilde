# App Store 用のアイコンとスクリーンショット

Mac App Store 配布 (App Store Connect の App レコード `com.takezou621.KildeGUI`) で使う
ビジュアル素材の置き場です。**アイコンは本番の成果物**、**スクリーンショットは実機
キャプチャに差し替えるまでのドラフト**という位置づけが違うので、混同しないこと。

## 1. アプリアイコン (本番)

意匠のベクタは `icon/kilde-icon-*.svg`。ビルドに入るのは
`gui/Resources/Assets.xcassets/AppIcon.appiconset/` の PNG です。

- **意匠**: 暗いスレートの角丸四角 (超楕円 n=5.9) に、赤い録画ドットと左右へ広がる音波。
  「画面と音声を録る」を 1 つの形で表す。地の暗さは録画中の赤を目立たせるため
- **現行の PNG は納品物 `kilde-appicon.zip` (2026-09-16) の書き出し**で、全サイズとも
  1024px マスターの縮小。16/32px では外側の弧がほぼ見えず「暗い角丸に赤いドット」に
  なる。小サイズの判読性を上げたいときは、`tools/` のサイズ別バリアント (`full` 3 本・
  ≥128px / `mid` 2 本・64px / `small` 1 本・≤32px) から作り直せる (§3)。細い弧は
  1 枚を縮小しただけでは 16px で消えるため、バリアントはそれを避ける設計
- **1024px は `icon_512x512@2x.png`**。macOS アプリは App Store 用アイコンを別途
  アップロードせず、この 1 枚が製品ページに出る

### ビルドへの結線 (片方だけだと黙ってアイコンなしで通る)

| 場所 | キー |
|---|---|
| `gui/project.yml` | `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` と `sources` への `Resources/Assets.xcassets` |
| `gui/Resources/Info.plist` | `CFBundleIconName` = `AppIcon` |

**`icon.py` → `render.py` は asset catalog を更新しない。** PNG を作り直したら
`python3 sync_appicon.py` で `png/` の 7 サイズを `AppIcon.appiconset` の 10 ファイルへ
反映すること — 忘れると「アイコンを作り直したのに MAS 成果物は旧版のまま」になる
(cubic / CodeRabbit レビュー指摘)。対応付けは `Contents.json` の `size` × `scale` から
機械的に決まる (16/32/64/128/256/512/1024 が過不足なく対応する)。

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
| `05-safe-finish.png` | 停止・アプリ終了のどちらでもファイルを仕上げる |

- **訴求は実装の保証範囲を超えない**。05 の文言は「停止・アプリ終了」に限定してある —
  DESIGN.md §5 は**プロセス異常終了時を保証対象外**としているので、「どう終わっても」の
  ような書き方はしない (cubic レビュー指摘)
- **モックは全セクションを描かない**。訴求に関係する部分 (収録対象・音声・保存先) に
  絞ってあり、実機のパネルにある「グローバルホットキー」「ログイン時に起動」は
  `panel_done()` 以外では省いている。**実機キャプチャへ差し替えるときは全体が入る**ので、
  ドラフトと実機の縦の情報量が違う点に注意すること
- **他社の商標を画面に入れない**。ウィンドウ一覧のサンプルは `com.example.*` の
  一般名にしてあり、入力デバイスの例も「外部マイク (USB)」のような一般名にしてある
  (実在の製品名は入れない — cubic レビュー指摘)。実機キャプチャに差し替えるときも、Zoom / Google Meet / Teams などの
  ウィンドウ名・バンドル ID・ロゴが写り込まないようにすること (App Store の審査で
  指摘されうる)
- リポジトリに入っているのは 256 色に最適化した版 (5 枚で約 2.5MB)。UI 画像なので
  見た目の劣化はほぼ無い。フル品質が要るときは下の手順で作り直す

## 3. 作り直す

`tools/` は Python + Playwright (Chromium) で動く。macOS の Xcode ツールチェーンには
依存しないので、CI でも手元でも同じ絵が出る。パスはすべてスクリプト位置基準で
解決するため、どのディレクトリから実行しても同じ場所を読み書きする
(`icon.py` の SVG → `icon/`、`render.py` の PNG → `png/`、`build.py` の
スクリーンショット → `screenshots/`)。

```sh
python3 -m pip install playwright && python3 -m playwright install chromium
cd docs/appstore/tools
python3 icon.py ../icon          # SVG を書き出す (3 バリアント)
python3 render.py                # SVG -> PNG (16〜1024px)
python3 sync_appicon.py          # PNG -> gui/Resources/.../AppIcon.appiconset (§1)
python3 build.py                 # スクリーンショット 5 枚 (2880x1800) を screenshots/ へ
```

- `build.py` は **"Noto Sans CJK JP" が無い環境では警告を出す**。フォントが変わると
  字幅と改行が変わり、コミット済みの画像と同じ絵にならない (フォントをリポジトリに
  同梱しないのは Noto CJK が 16MB 級のため。cubic レビュー指摘)

- `png/` と `icon.py` が書き出す `icon-*.svg` は中間成果物 (コミットしない。
  `png/` は `.gitignore` 済み — `git add -A` で紛れ込まないようにするため)。
  コミットされている `icon/kilde-icon-*.svg` は納品物の別名コピー (§1)
- **スクリーンショットをコミットするときは 256 色に最適化する**
  (`pngquant --force --ext .png --strip *.png` を `screenshots/` で実行。
  **`--ext .png` が要る** — `--force` だけでは元を置き換えず `*-fs8.png` を別に作る
  (2026-09-18 実測)。リポジトリに入っている版はこれで約 2.4MB/5 枚に抑えてある — §2)

`panel.py` がパネルの再現部分。`ContentView.swift` を変えたら、スクリーンショットを
撮り直す前にこちらも合わせること (幅 380pt・padding 12・セクション間 14 は SwiftUI 側の値)。
モックに描く要素は **MAS ビルド (KildeGUI-AppStore) の実機と一致させる** —
更新セクション (`#if !APPSTORE`) のような直接配布版にしか無い UI を入れない。

## 4. App Store Connect 側の状態

App レコードは作成済み (Apple ID `6812783176`)。プライバシー (データ収集なし)・
年齢区分 (4+)・カテゴリ (ユーティリティ / 仕事効率化)・著作権は入力済み。
**0.3.0 (2) を 2026-09-16 に提出し、2026-09-17 にリジェクトされた** (§5)。
プライバシーポリシーの本文はリポジトリ直下の `PRIVACY.md` (issue #128)。
App Store Connect のプライバシーポリシー URL には
`https://github.com/kilde-team/kilde/blob/main/PRIVACY.md` を指定する
(main にマージされるまでは 404 になるので、URL の差し替えはマージ後に行う)。

## 5. 審査の履歴

### 0.3.0 (2) — Guideline 2.4.5(i) でリジェクト (2026-09-17)

> The app saves user data to the app's container, which is not user accessible …
> It would be appropriate to save user files to a location selected by or available
> to users, using standard Save dialogs.

**原因**: 既定の保存先を `FileManager.urls(for: .moviesDirectory, in: .userDomainMask)`
から取っていた。サンドボックス下でこの API が返すのは実 `~/Movies` ではなく
**コンテナ内の** `~/Library/Containers/com.takezou621.KildeGUI/Data/Movies` で、
新規コンテナではそこが実ディレクトリとして作られ、録画がコンテナの中に落ちる。
既存コンテナで実 `~/Movies` への symlink になっている場合でも、アプリが表示・記録する
パス文字列はコンテナのままなので、録画完了のパス表示・通知の「Finder で表示」・
「最近の録画」がユーザーからアクセスできない場所を指す。

**対応**: MAS ビルドの既定保存先を `SandboxSupport.userVisibleMoviesDirectory()`
経由にし、実 `~/Movies` を指すようにした (symlink 解決 → だめなら `getpwuid` の実ホーム)。
`config.json` に残った古いコンテナ内パスも `SandboxSupport.userVisible(_:)` で正規化し、
コンテナ内を指す古い security-scoped bookmark は復元時に破棄する (Codex レビュー指摘。
0.3.0 (2) までの既定をそのまま「変更…」で選んでいると、bookmark にコンテナのパスが
残っていて正規化を打ち消すため)。
検証手順は docs/DEVELOPMENT.md の「App Store 配布ビルドのビルドと検証」、
地雷としての記録は CLAUDE.md §5.17。

**再提出時のレビューノートに書くこと** (App Store Connect の「App Review Information」):

```
Recordings are saved to the user's ~/Movies folder by default (entitlement:
com.apple.security.assets.movies.read-write). The save location is shown in the
recording panel and can be changed at any time with the "変更…" (Change…) button,
which opens a standard NSOpenPanel; the choice is persisted with a security-scoped
bookmark. The app container holds only the app's own settings (config.json) — no
user-created files are written there.
```

