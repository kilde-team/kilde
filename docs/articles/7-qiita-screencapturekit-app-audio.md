**この原稿について** (リポジトリ内の注記です。Qiita に転載するときは削除してください):
issue #312 で追加した、Zenn 公開済み記事 1 の Qiita クロスポスト原稿です。

- 公開手順: 下の本文を Qiita の新規記事にそのまま貼り付け、記事設定の
  **«canonical URL» に Zenn 版 (https://zenn.dev/takezou621/articles/a7f3df15b3a9ff)
  を設定して**公開する (重複コンテンツ扱いを避けるため)
- タグ案: `macOS` `Swift` `ScreenCaptureKit` `AVFoundation`
- 本文は Zenn 版とほぼ同一ですが、末尾の «次の記事» に公開済み Zenn 記事 2 への
  リンクを追加した点と、レビューで指摘のあった 3 か所の文言調整
  (子ウィンドウの既定値の由来を明記 / `finishWriting` の完了待ちを明記 /
  PTS アンカー前の音声バッファは保持する旨を明記) が異なります
- Zenn 版を修正したときは、このファイルも見直す

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
config.capturesAudio = true     // システム音声には「画面収録」の TCC 許可が必要
                                // (マイク許可は不要)。許可なしだと開始が失敗する
config.sampleRate = 48_000
config.channelCount = 2
config.queueDepth = 3            // ストリームのキューに保持できる最大フレーム数。
                                 // 処理が追いつかないとここを溢れてフレームが落ちる
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps
```

出力は `SCStreamOutput` の `stream(_:didOutputSampleBuffer:ofType:)` に
`.screen` (映像) と `.audio` (音声) が混ざって流れてきます。
`CMSampleBuffer` の音声は非圧縮 PCM ですが、Float32 の**ノンインターリーブ (平面)**
で渡ってきます。`AVAudioConverter` などでインターリーブに変換してから
エンコーダ (AVAssetWriter) に渡します。

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

ウィンドウ収録には 1 つ落とし穴があります。macOS 14.2 以降、ScreenCaptureKit は
**対象ウィンドウの子ウィンドウも既定で描画に含める**ようになっています
(実測に基づく挙動で、ドキュメントには既定値の記載がありません)。
子ウィンドウが画面の外にあると、
出力フレームは「親 + 子」の外接矩形に合わせて拡張され、結果として
録りたいウィンドウが縮んで写り、画面外の子ウィンドウが入り込んでしまいます。

```swift
let config = SCStreamConfiguration()
// ストリーム構成側で子ウィンドウを含めない (macOS 14.2 以降のプロパティ)。
// 既定のままだと外接矩形が広がって目的のウィンドウが縮んで写る。
// 14.0 / 14.1 向けのビルドでは availability ガードが必要
if #available(macOS 14.2, *) {
    config.includeChildWindows = false
}
```

「撮ったはずのウィンドウが妙に小さい」「変なパネルが写っている」ときは
ここを疑うのが近道です。なお音声のスコープ (そのアプリの音だけ、という指定) は
フィルタ側で決まり、この設定とは独立です。

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
なお、音声は最初の映像サンプルより先に届くことがあります。このバッファは
捨てずに保持しておき、アンカーが確定した時点でアンカー位置で切り詰めます
(素通りで捨てると録画冒頭の音声が失われます)。
これで**ドロップ起因の累積ズレは防げます** (サンプルカウントで積算する方式だと、
ドロップが起きたときにずれ続けるので、基準は常に PTS 側に置くのが安全です。
長時間録画でのドリフトの有無そのものは、別途の実測事項です)。

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
書きかけの再生不能ファイルが残ります。SIGINT / SIGTERM / SIGHUP を
「正常な停止」として扱い、最後のサンプルまで書き切ってから
`finishWriting(withCompletionHandler:)` を呼び、**完了コールバックを待ってから
終了する**作りにしておくと、録画ツールとしての信頼性が一段上がります
(SIGHUP を忘れると、ターミナルを閉じた瞬間に書きかけのファイルが残ります)。

## マイクを混ぜるなら

会議の録音では「相手の声 (システム音声) + 自分の声 (マイク)」が要ります。
マイクは `AVCaptureSession` で別に開くことになりますが、**起動に数百ミリ秒**かかるので、
ScreenCaptureKit のストリームより**先に**開始します。先に SCStream を上げると、
最初の数秒の自分の声が録れていない、ということが起きます
(マイク経路には Info.plist の `NSMicrophoneUsageDescription` と
マイクの TCC 許可が別途要ります。システム音声だけなら不要です)。

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
システム音声とマイクを 1 つのファイルにミックスします。[Mac App Store](https://apps.apple.com/app/id6812783176)
から入ります)。続きは、録った音声を macOS 26 の SpeechAnalyzer で
文字起こしする話です: [macOS 26 の SpeechAnalyzer で会議録音を文字起こしする](https://zenn.dev/takezou621/articles/7a8de3ca6ccb59) (Zenn)。
