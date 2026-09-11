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

#### 長時間ドリフトの計測手順 (issue #3)

```sh
swift build
scripts/drift-test.sh                  # 15 分 × (separate, mixed) — 計 ~31 分
scripts/drift-test.sh 1m 5 separate    # 手順確認用の短時間版
```

- `scripts/drift-marker.swift`: 黒いウィンドウ `KildeDriftMarker` を一定間隔 (既定 30 秒) で
  白く点滅させ、同時に 1 kHz / 60 ms のビープを鳴らす
- `kilde rec --window KildeDriftMarker --audio system --audio mic --audio-tracks <mode>` で収録する。
  ウィンドウ収録なので system 音声はこのアプリのビープだけになり (F-B)、mic 側は同じビープを
  スピーカーから回り込んで (音響経路) か、BlackHole 経由で (ループバック) 受け取る。
  映像・system・mic の 3 系統に同じ瞬間のマーカーが入る
- `OUT="<出力デバイス名>"` で**システムの既定出力を変えずに**鳴らす先を選べる (部分一致)。
  drift-marker が AVAudioEngine の出力ユニットの `CurrentDevice` を指定している。
  `MIC="device:<名前>"` は `kilde rec --audio` にそのまま渡る
- 録画開始で音声デバイスの構成が変わると AVAudioEngine は**停止し、接続とデバイス指定も失う**。
  drift-marker は `AVAudioEngineConfigurationChange` を受けて繋ぎ直す。直さないと 1 個目のマーカーから
  鳴らないまま録画が進む (2026-09-12 に実際に発生し、system も mic も peak 0.000 の録画になった)
- `scripts/drift-analyze.swift`: 映像は平均輝度の立ち上がりをマーカーとし、音声は**各マーカーの
  −0.5〜+1.0 秒の窓の中だけ**を探して、窓内の雑音レベル (中央値) と最大値の間の 30% を越えた
  最初の 1 ms ブロックをオンセットとする (トラック全体の最大値で閾値を決めると、マイクに入った
  1 回の物音で全マーカーを取り逃すため)。マーカーごとに「音声 − 映像」のずれを出す
- **主指標は推定ドリフト = 最小二乗の傾き × 計測時間**。マーカーごとに映像 1 フレーム
  (~16 ms) 程度の揺れがあるため、「最後のずれ − 最初のずれ」は参考値にとどめる。
  トラックごとの最大ピーク・雑音レベル・マーカー検出数も出るので、無音トラックはここで分かる
- 点滅と発音の間の表示・出力遅延、マイクの音響経路の遅延は**一定のずれ**として乗るだけで、
  ドリフト (経時変化) には影響しない
- mixed では 1 トラックに system と mic が重なるため、オンセットは先に鳴る system 側で決まる。
  mixed の計測は「`AudioMixer` の出力タイムラインが映像に対してずれていかないか」を見るもので、
  mic 自体のドリフトは separate の `audio[1] − audio[0]` で見る
- 前提: 鳴らす先の音量 > 0、計測中はウィンドウを隠さない・スリープさせない。**画面をロックしない**
  (ロック中は SCK がフレームを出さず、映像が 0 秒の録画になる)。音響経路で測る場合は静かな環境で
- **この検証機 (液晶が破損しており常時クラムシェル) には音響経路が存在しない。** 内蔵スピーカーは
  クラムシェルでは鳴らせず (`AudioQueueStart -66681`)、内蔵マイクはデジタル無音 (peak 0.000)、
  外部ディスプレイ (LG Ultra HD) は出力デバイスとして見えるのに音が出ない (2026-09-12 に確認。
  EMEET のマイクで peak 0.002 / 検出 0/12)。**この機体では BlackHole ループバックで計測する**:
  `OUT="BlackHole" MIC="device:BlackHole" scripts/drift-test.sh`
- ループバックでは mic 側が BlackHole の仮想クロックになるので、**実マイク (USB / 内蔵) のドリフトとは
  限らない**。「AVCapture 経路と SCK 経路のタイムラインがずれていかないか」の計測として扱い、
  実マイクでの値が要るときは音響経路のある別の Mac で測る
- 音響経路が使える環境なら `OUT="<スピーカー>" MIC="device:<マイク>"` で従来どおり測れる
  (`kilde devices` で名前を確認)。separate の解析でマイクが無音なら drift-test.sh が警告する
- 許容の目安は 15 分で ±40 ms (issue #3)。超える場合は補正方式 (リサンプル比の動的調整など) の issue を起票する

#### 計測結果

| 日付 | 環境 | 時間 / 間隔 | モード | 映像↔system ドリフト | 映像↔mic ドリフト | system↔mic ドリフト | 備考 |
|------|------|------------|-------|---------------------|------------------|--------------------|------|
| 2026-09-12 | macOS 26.6.2 / クラムシェル / BlackHole ループバック (`OUT="BlackHole" MIC="device:BlackHole"`) | 15m / 30s | separate | **−8.0 ms** (n=30) | **−7.9 ms** (n=30) | **+0.1 ms** (n=30) | **本計測**。検出 30/30。傾き −0.55 / −0.55 / +0.01 ms/分、変動幅 31.3 / 30.6 / 1.0 ms |
| 2026-09-12 | 同上 | 15m / 30s | mixed | **−11.7 ms** (n=30) | — | — | **本計測**。検出 30/30。傾き −0.81 ms/分、変動幅 23.0 ms |
| 2026-09-11 | macOS 26.6.2 / 出力 ZOOM UAC-232 / 入力 内蔵マイク | 1m / 5s | separate | −2.9 ms (n=12) | 計測不可 | — | **手順確認用 (1 分なので参考値)**。クラムシェルで内蔵マイクがデジタル無音 (peak 0.000)。トラック順 audio[0] = system を確認 |
| 2026-09-11 | 同上 | 1m / 5s | mixed | −5.9 ms (n=12) | — | — | 手順確認用。変動幅 16.7 ms |
| 2026-09-11 | 同上 / 入力 EMEET SmartCam C960 (`MIC="device:EMEET"`) | 1m / 5s | separate | +13.1 ms (n=12) | 検出 2/12 | +3.0 ms (n=2) | 手順確認用。Web カメラのマイクがスピーカーの音をほとんど拾えない (peak 0.008)。映像↔system の変動幅 60.7 ms |

手順確認で分かったこと: 映像↔system はマーカーごとに ±30 ms 程度揺れる (画面更新 1〜2 フレーム分)。
1 分・12 点では傾きが ±15 ms/分の範囲で振れるため、ドリフトの判定には 15 分・30 点の本計測が必要。
mic 側は音響経路のあるマイクか、BlackHole ループバックで行う (この検証機は後者しか選べない)。

**本計測の結論 (2026-09-12、issue #3)**:

- 15 分でのドリフトは最大でも 12 ms 程度で、**許容の目安 ±40 ms に対して十分小さい**。
  補正方式 (リサンプル比の動的調整など) は現時点で不要と判断した
- **`audio[1] − audio[0]` (AVCapture 経路 ↔ SCK 経路) は +0.1 ms / 14.5 分、傾き +0.01 ms/分**。
  会議録画の実用上、マイクとシステム音声がずれていく心配はない。
  ただしこの値は BlackHole ループバックで得たもので、実マイクのクロックではない (上記の注意を参照)
- 映像↔音声の −8 〜 −12 ms は傾きにすると −0.55 〜 −0.81 ms/分で、マーカーごとの変動幅
  (23〜31 ms) より小さい。画面更新のタイミングによる揺れに埋もれる水準で、
  1 分の手順確認で ±15 ms/分に振れていたのは点数不足によるものだったことも確認できた
- 30 分〜1 時間級の会議録画に外挿しても、この傾きなら 30 分で −25 ms 程度に収まる見込み

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
