# プライバシーポリシー / Privacy Policy

最終更新日 / Last updated: 2026-09-16

対象: kilde (macOS 用の画面・音声録画アプリ `Kilde` と `kilde` コマンドライン)

[English follows below.](#english)

## 日本語

### 収集する情報

kilde は**個人情報を含むいかなるデータも収集しません**。解析 (アナリティクス)、
トラッキング、広告、クラッシュレポートの送信は行いません。開発者のサーバーへ
データを送ることもありません。

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
| マイク | 自分の声を録音するため (マイクを使う設定のときだけ要求します) |
| ファイルとフォルダ (保存先) | 録画ファイルを指定の場所に書き込むため |

これらの権限で得たデータは、上記「録画・録音したデータ」のとおりローカルの
ファイルにのみ保存されます。

### 設定

保存先や音声の選択などの設定は、あなたの Mac 上 (App Store 版はアプリの
コンテナ内) にだけ保存されます。

### ネットワーク通信

- **Mac App Store 版**: ネットワーク通信を行いません (アプリにネットワーク接続の
  権限がありません)。アップデートは App Store を通じて配信されます
- **直接配布版 (GitHub Releases / Homebrew)**: アップデートの確認のため、
  自動更新ライブラリ Sparkle が GitHub 上の更新情報
  (`https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml`) を
  取得します。この通信では、一般的な HTTP 通信と同じく IP アドレスやアプリの
  バージョンなどが GitHub に伝わりますが、開発者がそれを受け取ることはありません。
  GitHub による取り扱いは
  [GitHub のプライバシーステートメント](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)
  に従います。定期的な自動確認を行うかどうかは、Sparkle が表示する確認ダイアログで
  選べます (手動の「アップデートを確認」は押したときだけ通信します)

### 第三者への提供

データを収集しないため、第三者へ提供するデータはありません。

### 本ポリシーの変更

内容を変更する場合は、このページを更新し、最終更新日を改めます。

### お問い合わせ

GitHub の Issues でお問い合わせください:
https://github.com/kilde-team/kilde/issues

---

<a id="english"></a>

## English

### Information we collect

kilde **does not collect any data, including personal information**. It has no
analytics, tracking, advertising, or crash reporting, and it sends no data to the
developer.

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
| Microphone | To record your voice (requested only when you choose to record the microphone) |
| Files and folders (save location) | To write recordings to the location you choose |

Data obtained through these permissions is stored only in local files, as
described above.

### Settings

Settings such as the save location and audio sources are stored only on your Mac
(inside the app's container for the Mac App Store version).

### Network access

- **Mac App Store version**: makes no network connections (the app has no
  network entitlement). Updates are delivered through the App Store
- **Directly distributed version (GitHub Releases / Homebrew)**: to check for
  updates, the Sparkle update framework downloads the update feed from GitHub
  (`https://github.com/kilde-team/kilde/releases/latest/download/appcast.xml`).
  As with any HTTP request, GitHub receives information such as your IP address
  and the app version; the developer does not receive it. GitHub handles it under
  the [GitHub General Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
  Sparkle asks whether to check for updates automatically, and you can decline
  ("Check for Updates" connects only when you click it)

### Sharing with third parties

Because no data is collected, no data is shared with third parties.

### Changes to this policy

If this policy changes, this page will be updated along with the "Last updated"
date.

### Contact

Please open an issue on GitHub: https://github.com/kilde-team/kilde/issues
