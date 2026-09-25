# App Review Notes (KildeGUI, App Store 提出用)

App Store Connect の App Review Information → Notes に貼る文案。
変更のたびにこのファイルを更新し、その内容を ASC に転記する。
**このファイル自体が審査への申告ではない** — ASC への提出は手動 (issue #148 では未実施)。

---

## English (paste into App Review Notes)

Kilde is a menu bar screen recorder that also records system audio and the
microphone, with optional on-device transcription of finished recordings.

**Permissions requested during review testing:**

- **Screen Recording**: Required to capture the screen. Kilde shows a permission
  onboarding screen and takes you to System Settings. After you grant it, please
  **restart the app** — macOS activates screen capture permission only after a
  process relaunch. Kilde re-checks the permission when the menu bar panel opens
  and right before recording starts.
- **Microphone**: Required to mix your voice into the recording. If you test
  screen recording only, you can decline the microphone; recording still works
  (video + system audio).

**How to test:**

1. Open Kilde from the menu bar icon.
2. Choose a display (or window), audio sources, and a destination. The default
   destination is `~/Movies`.
3. Press Record, wait a few seconds, press Stop. The recording appears in the
   chosen destination and in "Recent recordings".
4. (Optional, requires **macOS 26 or later**) To test transcription: enable
   "Transcribe after recording" in the panel before recording, record a short
   clip with speech, then press Stop. After the recording finishes, a Markdown
   transcript (`.md`) is written **next to the recording file**. On versions
   earlier than macOS 26 the Transcribe option is disabled in the panel.

**Transcription and data handling:**

- Transcription runs **entirely on this device** using Apple's SpeechAnalyzer /
  SpeechTranscriber APIs. No audio or transcript is sent to Kilde's servers or
  any third-party service (Kilde operates none).
- When the language model for the requested language is not already on the
  device, the app downloads a **speech recognition language model** from
  Apple's servers (a standard OS asset, several hundred MB). With a model
  present, transcription works entirely offline. The OS may remove unused
  models, in which case the model is downloaded again on next use.
- The app uses the App Sandbox. Recordings and transcripts are written to
  `~/Movies` or to a folder the user picks in the open panel (persisted via a
  security-scoped bookmark). Files are never placed inside the app's sandbox
  container.
- The app makes outbound network connections for: (a) usage analytics
  (Firebase Analytics), (b) crash reports sent on the next launch after a crash
  (Firebase Crashlytics), and (c) the language-model downloads described above.
  None of them carries audio content.

**Recording-consent note for reviewers:** Kilde records system audio, which can
include other meeting participants' voices. During normal use it is the user's
responsibility to inform participants that the session is being recorded. For
your review test, please speak into the microphone or use any sample audio —
no real meeting is required.

---

## 日本語 (参考訳 — 提出は英語版)

Kilde はメニューバーから使う画面録画アプリで、システム音声とマイクを録音でき、
録画の文字起こし (オプション) を備えています。

**レビュー中に求められる権限:**

- **画面収録**: 画面をキャプチャするために必須。権限オンボーディングを表示し、
  システム設定へ案内します。許可後は **アプリの再起動が必要** です (macOS は
  プロセス再起動後に画面収録権限を有効化します)。パネルを開くときと録画開始直前に
  アプリ側で権限を取り直します。
- **マイク**: 録画に自分の声を混ぜるために使います。画面収録のみのテストなら
  拒否しても録画は機能します (映像 + システム音声)。

**テスト手順:**

1. メニューバーアイコンから Kilde を開きます。
2. 画面 (またはウィンドウ)・音声ソース・保存先を選びます。既定の保存先は `~/Movies`。
3. 録画を開始し、数秒待って停止します。録画ファイルが選択した保存先と
   「最近の録画」に現れます。
4. (任意、**macOS 26 以降が必要**) 文字起こしのテスト: 録画前にパネルで
   「録画後に文字起こし」を有効にし、短い音声付きの録画を取って停止します。
   録画完了後、録画ファイルの隣に Markdown 文字起こし (`.md`) が書かれます。
   macOS 26 未満ではパネルのこのオプションは無効です。

**文字起こしとデータの扱い:**

- 文字起こしは Apple の SpeechAnalyzer / SpeechTranscriber を使い
  **このデバイス上だけで** 実行されます。音声や文字起こし結果が Kilde の
  サーバーや第三者サービスへ送られることはありません (Kilde はサーバーを
  運用していません)。
- 必要な言語のモデルが端末に無い場合、音声認識の **言語モデル** を Apple の
  サーバーからダウンロードします (OS 標準のアセットで、数百 MB 級)。
  モデルが端末にある間は文字起こしは完全にオフラインで動作します
  (OS が未使用のモデルを削除することがあり、その場合は次回利用時に再取得します)。
- アプリは App Sandbox を使用しています。録画と文字起こしは `~/Movies` または
  ユーザーがオープンパネルで選んだフォルダ (security-scoped bookmark で永続化)
  に書き込まれます。**アプリのサンドボックスコンテナ内に置かれることはありません**。
- 外向き接続は (a) 利用統計 (Firebase Analytics)、(b) クラッシュした次の起動時に
  送るクラッシュレポート (Firebase Crashlytics)、(c) 上記の言語モデル取得です。
  いずれも音声データを含みません。

**収録同意について (レビュアー向け):** Kilde はシステム音声を録るため、
会議の他の参加者の声が入る可能性があります。実際の利用では録画の告知は
ユーザーの責務です。レビューではマイクに話しかける、または任意のサンプル音声を
お使いください — 実在の会議は不要です。

---

## 根拠 (開発者向けメモ — ASC には書かない)

- **NSSpeechRecognitionUsageDescription は意図的に無い**: SpeechTranscriber は
  macOS 26 で TCC の音声認識権限を要求せず、Info.plist キー無しで動作する実測が
  kilde-team/kilde-cli-swift の SPIKE-NOTES (issue kilde-cli-swift#33「権限・
  サンドボックス・アセット」) にある。不要なキーを足すと審査での説明義務だけが増える
- **保存先は Guideline 2.4.5(i) の直接の対策**: 0.3.0 (2) をコンテナ内 Movies への
  保存でリジェクトされた履歴 (2026-09-17) があり、CLAUDE.md §5-17 の修正
  (SandboxSupport.userVisibleMoviesDirectory) を経ている。レビューノートで
  「コンテナには置かない」を明示して再発時の説明コストを下げる
- **オンデバイスの明示**は ASC の App Privacy 申告と PRIVACY.md の記載との
  一貫性のため。App Privacy は 2026-09-23 に Firebase Analytics (#136) に合わせて
  「おおよその場所・デバイス ID・製品の操作」(いずれも analytics 目的・トラッキングなし)
  で公開済み — 文字起こしの音声・テキストは収集対象に含めず、両者で同じ立場を取る。
  言語モデルの取得は PRIVACY.md の「ネットワーク通信」に記載済み。
  **提出前に ASC 側の申告と本ノートの記載を突き合わせること**
- **「one-time」ではなく「モデルが無い場合に取得」と書く**: 実装
  (TranscriptionCoordinator.installModelAsset) は必要言語のモデルが無いときに
  取得し、PRIVACY.md も「未使用のモデルはシステムが削除することがあるため、
  再び起こることがある」と申告している。英語本文はこの事実に合わせた言い方にする
