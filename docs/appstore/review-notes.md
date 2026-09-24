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
4. (Optional) To test transcription: enable "Transcribe" in the panel before
   recording, record a short clip with speech, then press Stop. After the
   recording finishes, a Markdown transcript (`.md`) is written **next to the
   recording file**.

**Transcription and data handling:**

- Transcription runs **entirely on this device** using Apple's SpeechAnalyzer /
  SpeechTranscriber APIs. No audio or transcript is sent to Kilde's servers or
  any third-party service (Kilde operates none).
- On first use, the app downloads a **speech recognition language model** from
  Apple's servers (a standard OS asset, several hundred MB). After that, all
  transcription works offline.
- The app uses the App Sandbox. Recordings and transcripts are written to
  `~/Movies` or to a folder the user picks in the open panel (persisted via a
  security-scoped bookmark). Files are never placed inside the app's sandbox
  container.
- The app makes outbound network connections for: (a) optional usage analytics
  (Firebase Analytics), and (b) the one-time language-model download described
  above. Neither carries audio content.

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
4. (任意) 文字起こしのテスト: 録画前にパネルで「文字起こし」を有効にし、
   短い音声付きの録画を取って停止します。録画完了後、録画ファイルの隣に
   Markdown 文字起こし (`.md`) が書かれます。

**文字起こしとデータの扱い:**

- 文字起こしは Apple の SpeechAnalyzer / SpeechTranscriber を使い
  **このデバイス上だけで** 実行されます。音声や文字起こし結果が Kilde の
  サーバーや第三者サービスへ送られることはありません (Kilde はサーバーを
  運用していません)。
- 初回利用時に、音声認識の **言語モデル** を Apple のサーバーから
  ダウンロードします (OS 標準のアセットで、数百 MB 級)。以降の文字起こしは
  すべてオフラインで動作します。
- アプリは App Sandbox を使用しています。録画と文字起こしは `~/Movies` または
  ユーザーがオープンパネルで選んだフォルダ (security-scoped bookmark で永続化)
  に書き込まれます。**アプリのサンドボックスコンテナ内に置かれることはありません**。
- 外向き接続は (a) 任意の利用統計 (Firebase Analytics) と (b) 上記の
  一度きりの言語モデル取得です。いずれも音声データを含みません。

**収録同意について (レビュアー向け):** Kilde はシステム音声を録るため、
会議の他の参加者の声が入る可能性があります。実際の利用では録画の告知は
ユーザーの責務です。レビューではマイクに話しかける、または任意のサンプル音声を
お使いください — 実在の会議は不要です。

---

## 根拠 (開発者向けメモ — ASC には書かない)

- **NSSpeechRecognitionUsageDescription は意図的に無い**: SpeechTranscriber は
  macOS 26 で TCC の音声認識権限を要求せず、Info.plist キー無しで動作する実測が
  kilde-cli-swift#33 (SPIKE-NOTES「権限・サンドボックス・アセット」) にある。
  不要なキーを足すと審査での説明義務だけが増える
- **保存先は Guideline 2.4.5(i) の直接の対策**: 0.3.0 (2) をコンテナ内 Movies への
  保存でリジェクトされた履歴 (2026-09-17) があり、CLAUDE.md §5-17 の修正
  (SandboxSupport.userVisibleMoviesDirectory) を経ている。レビューノートで
  「コンテナには置かない」を明示して再発時の説明コストを下げる
- **オンデバイスの明示**は Privacy Nutrition Label (Data Not Collected) との
  一貫性のため。モデル DL と Firebase は App Privacy 申告側でも申告済みの前提
  (issue #148 の時点で未確認 — 提出前に MAS 版の申告と突き合わせること)
