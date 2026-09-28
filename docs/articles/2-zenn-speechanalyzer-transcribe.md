---
title: "macOS 26 の SpeechAnalyzer で会議録音を文字起こしする — ファイルから PCM を流し込むときの注意"
emoji: "📝"
type: "tech"
topics: ["macOS", "Swift", "SpeechFramework", "音声認識", "AVFoundation"]
published: false
---

*この記事は、macOS 用の録画・録音ツール [kilde](https://kilde.site/) に
録画後の自動文字起こしを実装したときの知見を一般化したものです
(前回: [ScreenCaptureKit で「アプリ単位のシステム音声」を録る](https://zenn.dev) — 公開後にリンクを張ります)。*

## SpeechAnalyzer とは

macOS 26 の Speech framework に加わった `SpeechAnalyzer` は、**オンデバイス**で
長時間の音声を文字起こしするための API です。従来の `SFSpeechRecognizer` が
「認識セッションに話しかける」形だったのに対し、SpeechAnalyzer は
**分析器に PCM を流し込むストリーム処理**の形をしています。

- `SpeechTranscriber` — 音声 → テキストのセグメント列。時刻範囲は後述の指定で付与
- `AssetInventory` — 言語モデルの確保。モデルはシステムが管理し、
  その言語のモデルが端末に無いときに Apple からダウンロードが走る
- `SpeechAnalyzer` — モジュール (transcriber など) を載せて入力を受け付ける本体

音声の入力は `AnalyzerInput` に `AVAudioPCMBuffer` を包んで渡します。
「マイクをリアルタイムで」だけでなく「**録画済みファイルを**」文字起こしする場合、
こちらが主役になります (動作は Apple silicon の Mac が対象。以下はファイル経路の話です)。

## ファイル → PCM: AVAssetReader で読む

録画ファイル (MOV / M4A) から音声トラックを `AVAssetReader` で
linear PCM に展開して、バッファの列にして analyzer に渡します。

```swift
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    // ★ これを省略しない。後述
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]
let reader = try AVAssetReader(asset: asset)
reader.add(try AVAssetReaderAudioMixOutput(audioTracks: tracks,
                                           audioSettings: settings))
```

### ★ `AVLinearPCMIsBigEndianKey` を省略しない

ここがこの記事で一番伝えたいことです。**16-bit 整数 PCM を要求するとき
このキーを省略すると、macOS 27 の AVAssetReader は big endian で出力します**
(macOS 26 では省略時に little endian だったため、顕在化していませんでした)。

端末上の SpeechAnalyzer は little endian を期待していて、big endian のバッファが
届くと音が反転して故障したようなテキストになる…ならまだよくて、
**内部の assert でプロセスごと落ちます** (EXC_BREAKPOINT)。
「今まで動いていたコードが OS を上げた途端に落ちる」のは大抵この種の
暗黙の既定値が変わったときです。フォーマットを要求するときは
エンディアンまで明示する、が教訓です。

### 入力がもう PCM のとき

さらに厄介なのが、入力ソース自体が LPCM のケースです。
たとえば `say -o voice.m4a` が作る M4A は中身が 16-bit **big** endian の I16 で、
reader はこの語順をそのまま通してしまうことがあります
(要求した little endian の設定が適用されない別経路を通る)。
通常の M4A は AAC などに圧縮されているのでここは該当しません。
「コンテナに無圧縮 LPCM が入っている」この種の入力 (AIFF や `say` の出力など) で
顕在化します。

防御は簡単で、**最初のバッファで ASBD (AudioStreamBasicDescription) を検証し、
想定と違ったら `AVAudioConverter` で揃え直してから analyzer に渡す**ことです。
「reader を信頼しない。最初のバッファで検証する」を習慣にしておくと、
入力フォーマットの多様性 (録画ファイル、音声のみの M4A、外製の WAV…) に
1 回の実装で耐えられます。

## セグメントとタイムスタンプ

`SpeechTranscriber` の結果は AsyncSequence で流れてきます。
各セグメントは音声内の時刻範囲を持っていますが、**時刻範囲は既定では付きません**。
transcriber を作るときに `SpeechTranscriber.ResultAttributeOption.audioTimeRange`
を指定する (または時刻付きの preset を選ぶ) 必要があります — 標準の
`.transcription` preset では付かないので、SRT や WebVTT を作るなら必須の指定です。
時刻範囲が得られれば、**セグメントの時刻 = 録音内の時刻**として
SRT / WebVTT / Markdown にそのまま整形できます。

会議の文字起こしで効くのが**話者の分離**です。SpeechAnalyzer 側に
話者ダイアライゼーションはないので、録音側で分けておきます:

- システム音声 (相手たち) とマイク (自分) を**別トラック**で録る
- トラックごとに文字起こしする
- 時刻でマージして「相手 / 自分」のラベル付きの議事録にする

1 つのファイルにミックスしてしまうと後から分離できないので、
録る段階での分離が重要です。録画ツール側で
「ミックス 1 トラック」だけでなく「トラック分離」を持っているのはこのためです。

## キャンセルの落とし穴

長時間の文字起こしは中止できて当然ですが、**1 サンプルも入力を消費する前に
cancel すると、analyzer が応答しなくなることがあります** (macOS 26 実測)。
ユーザーが「開始した直後」にキャンセルするのはよくある操作なので、
ここはガードが必要です。

- 文字起こし開始の直前と、analyzer 起動直後にキャンセル済みチェックを置く
- 消費が始まった後のキャンセルは正しく止まるので、塞ぐ必要があるのは
  開始前の短い窓だけ

## 出力の整形

得られるのは時刻範囲付きテキストのセグメント列なので、あとは用途ごとに整形します。

- **Markdown** — 人が読む議事録。見出しとタイムスタンプを付ける
- **SRT / WebVTT** — 動画プレーヤーでの字幕再生
- **JSON** — 後段の LLM に渡すときの構造化データ

整形は純粋な文字列処理なので簡単ですが、「セグメントの時刻は録音内の相対時刻」
「書き出し先の既存ファイルを上書きしない (サイドカーは連番や排他的生成で)」
といった周辺の作法を決めておくと、ツールとしての信頼性が上がります。

## まとめ

- SpeechAnalyzer はオンデバイスのストリーム型文字起こし。ファイル経路は
  AVAssetReader → PCM → `AnalyzerInput`
- **`AVLinearPCMIsBigEndianKey` を省略しない** — macOS 27 の reader は
  big endian で出すことがあり、Speech 側でプロセスごと落ちる
- 入力ソースが既に PCM の場合は語順が素通りすることがある。
  最初のバッファで ASBD を検証し、`AVAudioConverter` で揃える
- 話者分離は analyzer ではなく録音側 (トラック分離) で解決する
- 開始直前のキャンセルにはガードを置く

録画からここまでを一気通貫でやるのが [kilde](https://kilde.site/)
(«録画後に文字起こし» を有効にしている場合は、録画の停止と同時に文字起こしが走ります。
[Mac App Store](https://apps.apple.com/app/id6812783176) / Homebrew で入ります) です。
