# プライバシーポリシー / Privacy Policy

最終更新日 / Last updated: 2026-09-23

対象: kilde (macOS 用の画面・音声録画アプリ `Kilde` と `kilde` コマンドライン)

[English follows below.](#english)

## 日本語

### 収集する情報

kilde は**録画・録音の内容や設定を収集しません**。
広告やクラッシュレポートの送信は行いません。

GUI アプリ (直接配布版・Mac App Store 版の両方) は、アプリの利用状況の解析を
Google の **Firebase Analytics** で行います。収集するのは起動回数・利用頻度・
アプリのバージョン・OS のバージョン・デバイスの種類・IP アドレスから推定される
大まかな地域などの利用統計で、**録画の内容 (映像・音声・ファイル名・保存先) や
あなたの設定 (ホットキー・保存先など) は含まれません**。これらのデータは
Google のサーバーに送信され、取り扱いは
[Google のプライバシーポリシー](https://policies.google.com/privacy) に従います。
開発者が取得できるのは集計された利用統計のみです。
`kilde` コマンドラインは解析を行いません。

### 録画・録音したデータ

- 画面の映像、システム音声、マイクの音声は、あなたの Mac 上で処理され、
  **あなたが指定した保存先 (アプリの既定は `~/Movies`、コマンドラインは指定した場所) のファイルにだけ**書き込まれます
- 録画ファイルがアプリによってネットワークへ送られることはありません。
  ファイルの共有・削除はあなたの管理下にあります
- 会議などを録画する場合は、参加者の同意を得るなど、お住まいの地域の法令に
  従ってください

### 要求する権限とその用途

| 権限 | 用途 |
|---|---|
| 画面収録 | 画面・ウィンドウの映像とシステム音声を録るため |
| マイク | 選んだマイク・入力デバイス (内蔵マイク、外部マイク、BlackHole などの仮想デバイスを含む) の音声を録るため。入力デバイスを 1 つ以上選んだときだけ要求します |
| ファイルとフォルダ (保存先) | 録画ファイルを指定の場所に書き込むため |

これらの権限で得たデータは、上記「録画・録音したデータ」のとおりローカルの
ファイルにのみ保存されます。

### 設定

保存先や音声の選択などの設定は、あなたの Mac 上 (App Store 版はアプリの
コンテナ内) にだけ保存されます。

### ネットワーク通信

- **Mac App Store 版**: 上の「収集する情報」のとおり、Firebase Analytics が
  利用統計を Google のサーバーへ送信します。アップデートは App Store を通じて
  配信されます
- **直接配布版の GUI (GitHub Releases の `kilde-<version>-macos.zip`)**: アップデートの
  確認のため、自動更新ライブラリ Sparkle が GitHub 上の更新情報
  (`https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml`) を
  取得します。この通信では、一般的な HTTP 通信と同じく IP アドレスやアプリの
  バージョンなどが GitHub に伝わりますが、開発者がそれを受け取ることはありません。
  GitHub による取り扱いは
  [GitHub のプライバシーステートメント](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)
  に従います。定期的な自動確認を行うかどうかは、Sparkle が表示する確認ダイアログで
  選べます (手動の「アップデートを確認」は押したときだけ通信します)
- **Homebrew で入れた `kilde` コマンド (CLI)**: Sparkle を含みません。CLI 自身が
  ネットワーク通信を行うことはなく、更新は `brew upgrade` を実行したときに
  Homebrew が行います

### 第三者への提供

録画・録音したデータと、あなたがアプリに入力した内容 (保存先・ホットキーなどの設定) を
第三者へ提供することはありません (そもそも収集していません)。

ただし次の 2 点は通信が発生します:

- **GUI アプリが利用統計を送るとき**: 上の「収集する情報」のとおり Firebase Analytics
  が Google のサーバーへ接続します (直接配布版・Mac App Store 版とも)
- **直接配布版の GUI が更新を確認するとき**: 上の「ネットワーク通信」のとおり
  GitHub へ接続します。この通信で IP アドレスやアプリのバージョンなどが
  GitHub に送信されます (取り扱いは GitHub のプライバシーステートメントに従います)

CLI にはこれらの通信はありません。

### 本ポリシーの変更

内容を変更する場合は、このページを更新し、最終更新日を改めます。

### お問い合わせ

GitHub の Issues でお問い合わせください:
https://github.com/kilde-team/kilde/issues

---

<a id="english"></a>

## English

### Information we collect

kilde **never collects your recordings or your settings**. It has no
advertising or crash reporting.

The GUI app (both the directly distributed and the Mac App Store version) uses
Google's **Firebase Analytics** to measure app usage. What is collected is usage
statistics such as launch counts, usage frequency, app version, OS version,
device model, and a coarse region estimated from your IP address. **It never
includes the content of your recordings (video, audio, file names, save
locations) or your settings (hotkeys, save locations, and so on).** These data
are sent to Google's servers and handled under
[Google's privacy policy](https://policies.google.com/privacy). The developer
only sees aggregated usage statistics. The `kilde` command-line tool does no
analytics.

### Your recordings

- Screen video, system audio, and microphone audio are processed on your Mac and
  written **only to files in the location you choose** (`~/Movies` by default in the app; wherever you specify on the command line)
- The app never uploads your recordings. Sharing and deleting them is up to you
- When you record meetings or calls, follow the laws where you live, such as
  getting consent from other participants

### Permissions and why they are needed

| Permission | Purpose |
|---|---|
| Screen Recording | To capture screen or window video and system audio |
| Microphone | To record audio from the input devices you select — a built-in or external microphone, or a virtual device such as BlackHole. Requested only when you select at least one input device |
| Files and folders (save location) | To write recordings to the location you choose |

Data obtained through these permissions is stored only in local files, as
described above.

### Settings

Settings such as the save location and audio sources are stored only on your Mac
(inside the app's container for the Mac App Store version).

### Network access

- **Mac App Store version**: Firebase Analytics sends usage statistics to
  Google's servers as described under "Information we collect". Updates are
  delivered through the App Store
- **Directly distributed GUI (the `kilde-<version>-macos.zip` on GitHub Releases)**:
  to check for updates, the Sparkle update framework downloads the update feed from GitHub
  (`https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml`).
  As with any HTTP request, GitHub receives information such as your IP address
  and the app version; the developer does not receive it. GitHub handles it under
  the [GitHub General Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
  Sparkle asks whether to check for updates automatically, and you can decline
  ("Check for Updates" connects only when you click it)
- **The `kilde` command-line tool installed with Homebrew**: does not include
  Sparkle. The CLI itself makes no network connections; updates happen when you
  run `brew upgrade`

### Sharing with third parties

Your recordings, and what you enter in the app (the save location, the hotkey
and other settings), are never shared with third parties (none of it is
collected in the first place).

Two kinds of connections are made:

- **When the GUI app sends usage statistics**: Firebase Analytics connects to
  Google's servers as described under "Information we collect" (both the directly
  distributed and the Mac App Store version)
- **When the directly distributed GUI checks for updates**: it connects to
  GitHub as described under "Network access", which sends information such as
  your IP address and the app version to GitHub (handled under the GitHub
  General Privacy Statement)

The CLI makes neither connection.

### Changes to this policy

If this policy changes, this page will be updated along with the "Last updated"
date.

### Contact

Please open an issue on GitHub: https://github.com/kilde-team/kilde/issues
