---
title: "ScreenCaptureKit で「アプリ単位のシステム音声」を録る — macOS の画面収録 API の勘所"
emoji: "🎧"
type: "tech"
topics: ["macOS", "Swift", "ScreenCaptureKit", "AVFoundation"]
published: false
---

*この記事は、macOS 用の画面・音声録音ツール [kilde](https://kilde.site/) の実装で得た知見を、
一般の macOS アプリ開発に役立つ形に一般化したものです。*

## はじめに

macOS の標準機能で画面収録をすると、録れるのは**マイクの音だけ**です。
QuickTime Player の画面収録も、Screenshot ユーティリティ (⇧⌘5) も、音声の選択肢に
マイクを置くだけで、Mac が再生している音 (システム音声) をファイルに落とす経路がありません。

会議の相手の声、動画の音、アプリの効果音 — 「Mac の外に出ている音」を記録するには、
選択肢が 2 つあります。

1. 仮想オーディオドライバ (BlackHole、Loopback など) を挟んでシステム音を入力に見せる
2. **ScreenCaptureKit** でシステム音声を直接キャプチャする

この記事は 2 の話です。ScreenCaptureKit で録る実装のうち、ドキュメントを読むだけでは
気づきにくかった点を、次の順でまとめます。

- システム音声キャプチャの最小構成
- **ウィンドウ (アプリ) 単位に絞ると、音声もそのアプリに絞られる**
- 音声と映像のタイムスタンプを揃える (PTS アンカー)
- AVAssetWriter 側の落とし穴

## 最小構成: SCStream でシステム音声を拾う

ScreenCaptureKit の登場人物は 3 つです。

- `SCShareableContent` — 録れる対象 (ディスプレイ / ウィンドウ / アプリ) の列挙
- `SCContentFilter` — 何を録るかの指定
- `SCStream` — 実際のキャプチャ。フレームを `CMSampleBuffer` で渡してくれる

音声を拾うには `SCStreamConfiguration` で `capturesAudio = true` を入れます。
マイクを鳴らさずにシステム音声だけが得られるのがポイントです。

```swift
let config = SCStreamConfiguration()
config.capturesAudio = true
config.sampleRate = 48_000
config.channelCount = 2
config.queueDepth = 3            // ディスプレイと音声でバッファ深度を共有するので、
                                 // 映像のフレームレート × 長さがここを溢れないように
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps
```

出力は `SCStreamOutput` の `stream(_:didOutputSampleBuffer:ofType:)` に
`.screen` (映像) と `.audio` (音声) が混ざって流れてきます。
`CMSampleBuffer` の音声は非圧縮 PCM (Float32 interleaved) なので、
そのままエンコーダ (AVAssetWriter) に渡せます。

## ウィンドウ単位に絞ると、音声もそのアプリに絞られる

ここが本題です。`SCContentFilter` には 2 系統あります。

- **ディスプレイ フィルタ** (`init(display:excludingApplications:exceptingWindows:)`) —
  画面全体。音声もシステム全体
- **デスクトップ独立ウィンドウ フィルタ**
  (`init(desktopIndependentWindow:)`) — 1 つのウィンドウ

デスクトップ独立ウィンドウのフィルタでストリームを作ると、**実測では音声も
そのウィンドウのアプリにスコープされます**。会議アプリのウィンドウを録れば
会議の音が入り、ほかのアプリの通知音や音楽は入りません。
「会議を録るときに通知音が混ざる」問題に対して、ミュートのお作法ではなく
キャプチャの構造で答えられるのが強いところです。

### 子ウィンドウを含まない

ウィンドウ フィルタには 1 つ落とし穴があります。`SCContentFilter` は既定で
**子ウィンドウも描画に含める**ことです。子ウィンドウが画面の外にあると、
出力フレームは「親 + 子」の外接矩形に合わせて拡張され、結果として
録りたいウィンドウが縮んで写り、画面外の子ウィンドウが入り込んでしまいます。

```swift
filter = SCContentFilter(desktopIndependentWindow: window)
filter.includeChildWindows = false   // 補助ウィンドウを含めない。
                                     // 既定のままだと外接矩形が広がって
                                     // 目的のウィンドウが縮んで写る
```

「撮ったはずのウィンドウが妙に小さい」「変なパネルが写っている」ときは
ここを疑うのが近道です。

## 音声と映像のタイムスタンプ: PTS アンカー

ScreenCaptureKit から渡される `CMSampleBuffer` には PTS (presentation timestamp) が
入っていますが、**映像と音声で PTS の起点が揃っているとは限りません**
特にウィンドウ収録では、ストリーム開始のタイミング差で音声の PTS が
映像より前から始まることがあり、このまま書き出すと A/V がずれます。

対策はシンプルで、**最初の映像サンプルの PTS をアンカーにする**ことです。

```swift
// 映像の最初のサンプルが来たとき
anchor = sampleBuffer.presentationTimeStamp

// 音声側ではアンカー以前の分を捨てる
// (先頭のバッファはアンカーから巻き込まれる形で切る)
```

以降の音声は「PTS − アンカー」を書き出し側の 0 秒に写像します。
この処理を入れるだけで、長時間録画でもズレの累積がありません
(サンプルカウントで積算する方式だと、ドロップが起きたときにずれ続けるので、
基準は常に PTS 側に置くのが安全です)。

## AVAssetWriter 側の落とし穴

書き出し側で実測ベースで抑えておきたい点を 3 つ。

**幅と高さは必須。** 映像の `AVAssetWriterInput` を作るとき
`AVVideoWidthKey` / `AVVideoHeightKey` を渡さないと
`NSInvalidArgumentException` でクラッシュします。ScreenCaptureKit の出力サイズから
計算して必ず入れることになります。

**ピクセルフォーマットはコーデックに合わせる。**
H.264 / HEVC に渡すなら `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
(4:2:0 YUV)。エンコーダの入力はどのみち 4:2:0 なので、BGRA のまま渡すと
色変換が 1 回余計に入り、実測で CPU 使用率が体感で増えます。
逆に ProRes 422 は 4:2:2 なので `kCVPixelFormatType_32BGRA` のままにします
(4:2:0 に落とすと編集用の中間フォーマットとしての意味が薄れます)。

**終了処理をシグナルでも通す。** CLI や長時間収録のツールでは、
Ctrl+C で止められたときに `finishWriting` まで走らせないと
書きかけの再生不能ファイルが残ります。SIGINT / SIGTERM を
「正常な停止」として扱い、最後のサンプルまで書き切ってから
`finishWriting(withCompletionHandler:)` に到達させる作りにしておくと、
録画ツールとしての信頼性が一段上がります。

## マイクを混ぜるなら

会議の録音では「相手の声 (システム音声) + 自分の声 (マイク)」が要ります。
マイクは `AVCaptureSession` で別に開くことになりますが、**起動に数百ミリ秒**かかるので、
ScreenCaptureKit のストリームより**先に**開始します。先に SCStream を上げると、
最初の数秒の自分の声が録れていない、ということが起きます。

ミックスは自前で行います。両ソースの PTS を揃えた上で、
サンプルレートを揃えて加算するだけですが、片方が遅れて到着した分を
無音で埋める (先に進めたトラックを待ち合わせる) 処理を書くと、
トラックごとの開始遅延に強くなります。

## まとめ

- システム音声は ScreenCaptureKit でドライバなしに録れる
- **ウィンドウ (アプリ) フィルタにすると、音声もそのアプリに絞られる** —
  通知音問題の構造的な解
- 子ウィンドウは既定で含まれる。含めない設定を明示する
- 時間の基準はサンプルカウントではなく PTS。最初の映像 PTS をアンカーにする
- writer の幅・高さ必須、ピクセルフォーマットはコーデックに合わせる
- Ctrl+C でも finishWriting まで走らせて、再生不能なファイルを残さない

これらをまとめて実装したものが、macOS 用の録画ツール
[kilde](https://kilde.site/) です (会議プリセットでウィンドウを選ぶと
システム音声とマイクを 1 つのファイルにミックスします。Mac App Store から
入ります)。次の記事では、録った音声を macOS 26 の SpeechAnalyzer で
文字起こしする話を書きます。
