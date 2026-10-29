# App Review Notes (KildeGUI, App Store 提出用)

App Store Connect の App Review Information → Notes に貼る文案。
変更のたびにこのファイルを更新し、その内容を ASC に転記する。
**このファイル自体が審査への申告ではない** — ASC への提出は手動 (issue #148 では未実施)。

---

## English (paste into App Review Notes)

Kilde is a menu bar screen recorder that also records system audio and the
microphone, with optional on-device transcription of finished recordings.

**Permissions requested during review testing:**

- **Screen Recording**: required for the screen **and system audio (which
  can include other participants' voices)**. After granting it, please
  **restart the app** — macOS activates it only after a relaunch.
- **Microphone**: records **your own voice**. You can decline it; recording
  still works (video + system audio).

**How to test:**

1. Open Kilde from the menu bar icon.
2. Choose a display (or window), audio sources, and a destination (default
   `~/Movies`). Record a few seconds and stop — the file appears in the
   destination and in "Recent recordings".
3. (Optional, **macOS 26+**) enable "Transcribe after recording" and record
   a short clip with speech; a Markdown transcript is written next to the
   recording. On earlier versions the option is disabled.

**Data handling:** transcription and AI features run **entirely on this
device** (SpeechTranscriber / Apple Intelligence). No audio, transcript,
summary, or draft text is sent anywhere. A missing language model downloads
from Apple (standard OS asset; as with any network request, your IP reaches
Apple); otherwise it works offline. Recordings and transcripts are written
to `~/Movies` or a user-picked folder (App Sandbox; never inside the
container). Outbound connections: usage analytics and crash reports
(Firebase) and those downloads; none carries audio content.

**Automatic transcription language (v0.21.0, opt-in):** "Automatic (detect
from recording)" picks the language per audio track from the first 30
seconds. No new permissions; audio never leaves the device.

**Meeting auto-recording (off by default):** can detect an ongoing meeting
and record it automatically. Detection is local; manual recordings are
never stopped automatically. **Calendar meeting names (v0.20.0, opt-in):**
with auto-recording enabled, "Use calendar event names for recording file
names" applies the matched event title to the file name, the start
notification, and the transcript heading. macOS has no read-only calendar
permission so the request is full access, but **the app only reads
events**; data stays on-device. If declined — or a lookup is still running
when recording starts — the default file name is used.

**Recording-consent note:** system audio can include other participants'
voices; informing them is the user's responsibility. Any sample audio works
for testing.

**In-app purchase — tips (v0.18.0):** the optional "Support this app"
section offers three consumable tips (kilde.tip.*); tapping one starts a
standard StoreKit purchase (sandbox Apple ID). Nothing is gated.

**In-app purchase — kilde Pro (v0.26.0 summaries, v0.28.0 follow-up
drafts):** one non-consumable, one-time product (kilde.pro) unlocks both.

- *Summaries:* while not owned, "Summarize after recording" in the panel's
  transcription section is a locked row with a "Pro" badge; clicking it
  expands an inline purchase panel (price, Buy — standard StoreKit purchase
  with your sandbox Apple ID — and Restore). After purchase the row becomes
  the normal toggle. Also enable "Transcribe after recording" (it is the
  input). Summaries run on-device with Apple Intelligence (macOS 26+;
  without it the lock row is disabled).
- *Follow-up drafts (v0.28.0):* in the library window, a recording whose
  minutes (.md) include a summary shows "Draft a follow-up"; the sheet
  generates an email or chat draft from that summary (same on-device model,
  copy button). Without Pro it is locked with a tooltip; without Apple
  Intelligence or a summary it is disabled with the reason as a tooltip.
**Recording and transcription are currently free.** If the price shows a
loading placeholder, the product may not be visible yet; reopening the
panel retries. The IAP's review screenshot shows the row and the panel.

---
## 日本語 (参考訳 — 提出は英語版)

**アプリ内課金 — kilde Pro・会議の要約 (v0.26.0) とフォローアップの下書き (v0.28.0):**

会議の要約とフォローアップの下書きが有料機能で、**同じ非消耗型 kilde.pro
(日本では ¥2,800 の買い切り) 1 商品で両方がアンロック** されます。
未購入の間、パネルの文字起こしセクションの «録画後に要約も作る» は «Pro» バッジ付きの
ロック行に置き換わります。クリックするとインラインの購入導線が開き、App Store から
取得した価格・購入ボタン (StoreKit 標準フロー — sandbox の Apple ID で確認)・
«購入を復元» (App Store sync) が並びます。購入後は通常のトグルに戻ります。
要約の生成には «録画後に文字起こし» も有効化が必要です (文字起こしが入力になるため)。
処理は Apple Intelligence のオンデバイス (macOS 26+。非対応機ではロック行自体が
無効になり、文字起こしが有効なときは理由の案内行も出ます)。**録画と文字起こしは現在無料** — 他にゲート
される機能はありません。レビュー環境で価格が取得できない場合 (商品がまだ見えない)
は «読み込み中» のプレースホルダになります — 想定された挙動で、IAP の審査用
スクリーンショットにロック行と導線を示してあります。

*フォローアップの下書き (v0.28.0):* ライブラリウィンドウで、要約つきの議事録
(.md) を持つ録画の詳細に «フォローアップを下書き» ボタンが出ます。シートで
形式 (メール / チャット) を選んで生成すると、要約から送信用の下書き (件名 +
本文) を作り、コピーできます (要約と同じ Apple Intelligence のオンデバイス
処理)。未購入ではロックされツールチップで設定パネルへの購入を案内、Apple
Intelligence が使えない環境・要約のない録画では理由がツールチップに出ます。

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
  いずれも音声データを含みません (言語モデルの取得では、任意のネットワーク通信と
  同様に IP アドレスが Apple へ届きます)。

**文字起こし言語の自動判定 (v0.21.0、オプトイン):** 文字起こしの言語設定に
«自動 (録音から判定)» が増えます (既定は端末の言語のまま)。選ぶと録音の冒頭
30 秒から音声トラックごとに言語を決めます (候補は端末の言語・日本語・英語。
判定できないトラックは端末の言語にフォールバック)。新しい権限は不要です。
録音・書き起こしの内容が端末外へ送られることはありません (言語モデルが未取得の
場合は上記のとおり Apple から取得されます)。

**会議の自動録画 (既定ではオフ):**

kilde は進行中の会議を検知して自動で録画できます (オプション)。検知は
マイクを使用中のプロセスと画面上のウィンドウを見るローカル処理で、
外部へ何も送信しません。この機能は **既定でオフ** で、パネルの
「会議を検知したら会議ウィンドウを自動で録画する」を有効にした場合にのみ
動作します。手動で開始した録画が自動で停止されることはありません。

**カレンダーの会議名 (既定ではオフ、v0.20.0 で追加):**

«カレンダーの予定名を録画ファイル名に使う» は、«会議の自動録画» も有効な
ときにだけ働く設定で、検知した会議と時間帯が重なるカレンダーの予定の題名を
録画ファイル名・録画開始通知・議事録の見出しに使います。macOS に読み取り専用の
カレンダー権限は無いため、要求 (`requestFullAccessToEvents` (macOS 14+)) と
エンタイトルメントはフルアクセスになりますが、**アプリは予定の読み取りだけを
行い**、作成・変更・招待はしません。カレンダーの内容は端末内だけで使われ、
上記の通信に含まれることはありません。拒否しても他の機能は通常どおり動きます。
許可済みでも、録画開始時点で検索が未完了の場合はカレンダー名なしの既定名に
なります (検索は数秒前に先行するため、実際にはまれです)。

**収録同意について (レビュアー向け):** Kilde はシステム音声を録るため、
会議の他の参加者の声が入る可能性があります。実際の利用では録画の告知は
ユーザーの責務です。レビューではマイクに話しかける、または任意のサンプル音声を
お使いください — 実在の会議は不要です。

**アプリ内課金 — チップ (v0.18.0 で追加):**

パネルの最下部に «アプリを応援» セクションがあり、消耗型のチップ商品
(kilde.tip.small / kilde.tip.medium / kilde.tip.large) を 3 段階で送れます。
タップで標準の StoreKit 購入が始まり、システムの確認シートで完了します。
セクションは App Store から商品一覧を取得できたときにのみ表示され、
録画・文字起こしのすべての機能は購入なしで完全に利用できます。
チップをレビューする場合はセクション内のボタンをタップし、
サンドボックスの Apple ID で承認してください。セクションが見えない場合は
レビュー環境に商品がまだ届いていないもので、設計どおりの非表示です —
**機能が欠けているわけではありません**。本 IAP はこのバージョン
(0.18.0) に添付して提出するため、審査中にはサンドボックスでも
商品が取得できるようになります。

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
- **チップ (issue #171) のレビューノート**: «セクションは商品一覧の取得後のみ
  表示» と «すべての機能は購入なしで利用可能» を明示する — レビュー環境で商品
  (初回審査中の IAP) が取得できずセクションが出ないときに «機能が欠けている»
  と誤解されるのを防ぐ。Guideline 3.1.1 の消耗型 IAP で、外部決済・外部リンクは
  直接配布版にも出さない (GitHub Sponsors 導線は issue #171 の残りスコープで、
  MAS 版には一切出さない)
