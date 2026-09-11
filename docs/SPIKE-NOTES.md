# M0 スパイク検証結果

- Date: 2026-09-11
- Environment: macOS 26.6.2 (25G83) / Apple Silicon / Swift 6.3.3 / Xcode 26.5 SDK
- Audio env: 既定出力 ZOOM UAC-232 (USB), BlackHole 2ch 導入済み, 内蔵マイク
- 検証コード: `Sources/Spike` (SPM 実行ファイル `spike`)

## 結果サマリ

| # | 検証項目 | 結果 | 概要 |
|---|---------|------|------|
| S1 | SCK システム音声 | ✅ | `capturesAudio` で音声取得。テスト音声 RMS 0.087 / peak 0.61 |
| S2 | クロック同期 | ✅* | system 映像対 +0.019s / mic +0.373s (開始遅延のみ)。長時間ドリフトは未実測 |
| S3 | 書き込み経路 | ✅ | SCK (BGRA) → AVAssetWriter H.264 2560x1440 で動作。注意点あり (下記) |
| S4 | マルチ出力デバイス | ✅ | `stacked` フラグ必須。作成/既定切替/復元/削除 + BlackHole ループバック録音 (RMS 0.088) まで動作 |
| S5 | シグナル処理 | ✅ | SIGINT → graceful finalize、有効なファイル、exit 0 |
| S6 | 権限の実挙動 | ✅* | 権限は事前付与済みだったため画面・マイクとも SCK/AVCapture が正常動作。未許可時のエラーの形は未観察 |
| S7 | 環境差異 | ⚠️ | macOS 26 のみ検証。13/14/15 は未検証 (特に S8/S9 の挙動) |
| S8 | SCK 音声のみ | ✅ **設計変更** | `.audio` 出力のみ登録で音声のみ取得可 → **録音モードに BlackHole 不要** |
| S9 | ウィンドウ音声スコープ | ✅ **設計変更** | 対象ウィンドウの音は入り (RMS 0.057)、他アプリの音は完全除外 (RMS 0.0000)。S8 との組み合わせ (特定アプリの音声のみ録音) も成功 |
| S10 | 会議アプリ実地 | ⏳ | 未実施。Zoom / Teams / Chrome (Meet) での手動検証が残項目 |

## 詳細と重要な発見

### F-A: SCK は音声のみ取得が可能 (S8) — 設計前提 F6 の反証

`SCStream` に `.audio` 出力だけを登録して `startCapture()` すると、映像なしで
音声ストリームが得られる (macOS 26 で確認)。M4A への書き込みも正常
(6.00s, RMS 0.0868)。

→ `kilde rec --no-video --audio system` が **BlackHole なし**で実現できる。
BlackHole は必須経路ではなく「代替経路 / 他ツール連携 / 旧 OS フォールバック」に役割変更。

### F-B: ウィンドウ単位収録で音声がそのアプリにスコープされる (S9)

`SCContentFilter(desktopIndependentWindow:)` + `capturesAudio` で:

- 収録対象ウィンドウ (音を鳴らすアプリ) → 音声 **入る** (RMS 0.0571)
- 無関係ウィンドウ収録中に他アプリが音を鳴らす → **完全に無音** (RMS 0.0000)
- `--no-video` 相当 (audio 出力のみ) + ウィンドウフィルタ → **特定アプリの音声だけ録音** (RMS 0.0571)

→ 会議録画・録画の既定を「ウィンドウ単位」にすれば、**通知音や他アプリの音を
除いた会議の音声だけ**を録れる。`--preset meeting` の核心。

### F-C: マルチ出力デバイスには非公開の `stacked` フラグが必須 (S4)

`AudioHardwareCreateAggregateDevice` でメンバーを束ねただけでは
マスター側にしか音が流れない (BlackHole が無音になった)。
Audio MIDI Setup の「複数出力装置」と同じ `stacked: true` を渡すと
全サブデバイスに同時出力され、BlackHole での同時録音が成功した。

```swift
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "kilde Monitor",
    kAudioAggregateDeviceUIDKey: uid,
    kAudioAggregateDeviceIsPrivateKey: false,
    "stacked": true,   // ← 非公開キー。これがないと MUD として動かない
    kAudioAggregateDeviceSubDeviceListKey: memberUIDs.map { [kAudioSubDeviceUIDKey: $0] },
    kAudioAggregateDeviceMasterSubDeviceKey: masterUID,
]
```

⚠️ 非公開キーであるため OS 更新で変わる可能性がある。SCK ネイティブ経路が
主役になった今、この機能は「BlackHole を使う人の利便化」が主目的。

### F-D: macOS 26 の API/挙動メモ (実装上の注意)

1. **SCK は既定で圧縮済みフレームを渡す**。AVAssetWriter で再圧縮するなら
   `configuration.pixelFormat = kCVPixelFormatType_32BGRA` で非圧縮を要求する。
   (逆に SCK 圧縮フレームを passthrough すれば無再エンコード録画の可能性 — M1 で検討)
2. **AVAssetWriterInput の video outputSettings に幅・高さが必須**
   (`AVVideoWidthKey/AVVideoHeightKey` がないと NSInvalidArgumentException でクラッシュ)。
3. **CLI でも NSApplication の初期化が必要**: `NSApplication.shared` +
   `setActivationPolicy(.accessory)` をしないと、ウィンドウ収録開始時に
   `CGS_REQUIRE_INIT` で落ちる。
4. **SCWindow.owningApplication が `SCRunningApplication?` 型** に変更
   (`bundleIdentifier` を読む)。SCStreamFrameInfo は型付きキー
   (`[[SCStreamFrameInfo: Any]]` でアタッチメントを読む)。
5. `AVCaptureDevice(uniqueID:)` でデバイス指定取得。
6. マイク (AVCaptureSession) の開始には ~370ms かかる → **SCK 開始前に
   先に開始しておく**べき (開始順序の設計メモ)。

### F-E: A/V 同期 (S2)

`startSession(atSourceTime: 最初の映像 PTS)` アンカー方式で、
SCK 音声 (+0.019s)・AVCapture マイク (+0.373s) が映像と同じタイムラインに
乗ることを確認。マイクのオフセットは開始遅延で、開始順序で吸収可能。
**10 分級の長時間ドリフト測定は未実施** (M1 のスモークテスト課題)。

## M1 への反映

1. 録音 (audio-only) モードは SCK ネイティブ (`--audio system` + `.audio` 出力のみ)
   を既定に。BlackHole は `--audio device:...` + `--monitor` のオプション経路。
2. `--preset meeting` = ウィンドウ単位 + システム (スコープ済み) 音声 + マイク + ミックス。
3. `kilde audio monitor` は stacked フラグを使う。非公開キー依存の切り出し。
4. 映像: pixelFormat BGRA 指定 + AVAssetWriter 幅/高さ明示。
5. CLI 起動時に NSApplication accessory 初期化。
6. マイクは SCK より先に開始。
7. 残課題: (a) 旧 OS (13/14/15) での S8/S9 挙動、(b) 長時間ドリフト、
   (c) S10 会議アプリ実地検証、(d) SCK 圧縮フレーム passthrough の検討。

## 生成物

テスト成果物 (scratchpad): `s1-rec-system.mov`, `s2-rec-system-mic.mov`,
`s8-audio-only.m4a`, `s9a-window-positive.mov`, `s9b-window-negative.mov`,
`s9c-audio-window.m4a`, `s4b-blackhole-stacked.m4a`, `s5-sigint.mov`
