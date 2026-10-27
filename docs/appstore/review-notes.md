# App Review Notes (KildeGUI, App Store 提出用)

App Store Connect の App Review Information → Notes に貼る文案。
変更のたびにこのファイルを更新し、その内容を ASC に転記する。
**このファイル自体が審査への申告ではない** — ASC への提出は手動 (issue #148 では未実施)。

---

## English (paste into App Review Notes)

Kilde is a menu bar screen recorder that also records system audio and the
microphone, with optional on-device transcription of finished recordings.

**Permissions requested during review testing:**

- **Screen Recording**: required to capture the screen **and system audio
  (which can include other participants' voices)**. After granting it in
  System Settings, please **restart the app** — macOS activates it only
  after a relaunch.
- **Microphone**: required to record **your own voice**. You can decline it;
  recording still works (video + system audio).

**How to test:**

1. Open Kilde from the menu bar icon.
2. Choose a display (or window), audio sources, and a destination (default
   `~/Movies`). Press Record, wait a few seconds, press Stop — the recording
   appears in the destination and in "Recent recordings".
3. (Optional, **macOS 26+**) To test transcription: enable "Transcribe after
   recording", record a short clip with speech, press Stop. A Markdown
   transcript is written **next to the recording file**. On earlier versions
   the option is disabled.

**Transcription and data handling:**

- Transcription runs **entirely on this device** (Apple SpeechAnalyzer /
  SpeechTranscriber). No audio or transcript is sent anywhere (Kilde operates
  no servers). If the speech language model is not on the device, it is
  downloaded from Apple's servers (a standard OS asset; as with any network
  request, your IP address reaches Apple); otherwise it works offline.
- The app uses the App Sandbox. Recordings and transcripts are written to
  `~/Movies` or a user-picked folder (security-scoped bookmark), never inside
  the sandbox container.
- Outbound network connections: (a) usage analytics (Firebase Analytics),
  (b) crash reports after a crash (Firebase Crashlytics), (c) the
  language-model downloads above. None carries audio content.

**Automatic transcription language (v0.21.0, opt-in):** The transcription
language setting gains "Automatic (detect from recording)" (default
unchanged). It picks the language per audio track from the first 30 seconds
(candidates: device language, Japanese, English; undecided tracks fall back
to the device language). No new permissions. Audio and transcripts never
leave the device; missing language models download from Apple as noted
above.

**Meeting auto-recording (off by default):**

Kilde can optionally detect an ongoing meeting and record it automatically.
Detection runs locally and sends nothing anywhere. **Off by default** — it never starts or
stops a recording unless the user enabled "Record meeting windows
automatically", and manual recordings are never stopped automatically.

**Calendar meeting names (off by default, v0.20.0):**

A separate opt-in ("Use calendar event names"), effective only while meeting
auto-recording is also enabled, uses the title of a calendar event overlapping
the detected meeting for the recording file name, the recording-started
notification, and the transcript heading. macOS offers no read-only calendar
permission, so the request — `requestFullAccessToEvents` (macOS 14+) — and the
entitlement are for full access, but **the app only reads events**; it never
creates, edits, or invites. Calendar data stays on-device; if declined,
recordings continue with the default file name. A lookup not finished by the time recording starts
falls back to the default file name.

**Recording-consent note:** system audio can include other participants'
voices; informing them is the user's responsibility. For your test, any sample
audio works — no real meeting is required.

**In-app purchase — tips (v0.18.0):**

The panel has an optional "Support this app" section with three consumable
tips (kilde.tip.small/medium/large); tapping one starts a standard StoreKit
purchase (confirm with your sandbox Apple ID). Nothing is gated behind it —
every feature stays free. If the section does not appear, the products are
not yet available in your environment; no feature is missing.

**In-app purchase — kilde Pro, meeting summaries (v0.26.0):**

Meeting summaries are the first paid feature, sold as a non-consumable
one-time purchase (kilde.pro, ¥2,800 in Japan). In the transcription
section of the panel, "Summarize after recording" is replaced by a locked
row with a "Pro" badge while the purchase is not owned. Clicking the row
expands an inline purchase panel: the price pulled from the App Store, a
Buy button that starts a standard StoreKit purchase (confirm with your
sandbox Apple ID), and a Restore Purchase button (App Store sync).
After the purchase the row turns back into the normal toggle. To actually
generate a summary, also enable "Transcribe after recording" (transcription
is the input to the summary); summaries run on-device with Apple
Intelligence (macOS 26+; on devices without it the lock row is disabled,
and an explanatory line appears when transcription is enabled). **Recording and transcription are currently
free** — nothing else is gated. If the price does not load during review
(product not yet visible in your environment), the panel shows a loading
placeholder; that is expected, and the IAP's review screenshot shows the
locked row and the expanded panel.

---

## 日本語 (参考訳 — 提出は英語版)

**アプリ内課金 — kilde Pro・会議の要約 (v0.26.0):**

会議の要約が最初の有料機能 (非消耗型 kilde.pro・日本では ¥2,800 の買い切り)。
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
