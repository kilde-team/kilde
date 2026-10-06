---
title: "Capturing per-app system audio on macOS with ScreenCaptureKit — the parts the docs don't spell out"
published: false
description: "How to record the audio your Mac plays — scoped to a single app — with ScreenCaptureKit: audio scoping, child windows, PTS anchoring, and AVAssetWriter pitfalls."
tags: macos, swift, screencapturekit, avfoundation
canonical_url = "https://zenn.dev/takezou621/articles/a7f3df15b3a9ff"
---

**この原稿について** (リポジトリ内の注記です。dev.to に転載するときは削除してください):
issue #312 で追加した Zenn 公開済み記事 1 の英語版です。front matter の
`canonical_url` に Zenn 版を設定してあるので、dev.to に載せるときはこのまま使えます
(kilde.site blog に原典として載せるときは canonical を外す)。英語版記事 2 と
シリーズにするため、公開時に前後編のリンクを張ってください。
原文: `1-zenn-screencapturekit-app-audio.md`。

---

*This post generalizes what we learned building [kilde](https://kilde.site/), a
screen and audio recorder for macOS, into notes that apply to macOS app
development in general.*

## Introduction

If you record your screen with macOS's built-in tools, the only audio you get is
**your microphone**. QuickTime Player's screen recording and the Screenshot
utility (⇧⌘5) both offer a microphone as the only audio choice — there is no
path that writes the sound your Mac is playing (system audio) to a file.

The other participants' voices in a meeting, the audio of a video, an app's
sound effects — to record "the sound coming out of your Mac", you have two
options:

1. Insert a virtual audio driver (BlackHole, Loopback, etc.) to present system
   audio as an input device
2. Capture system audio directly with **ScreenCaptureKit**

This post is about option 2. Of the things we learned implementing
ScreenCaptureKit capture, here are the ones that are hard to discover from the
documentation alone, in this order:

- The minimal setup for system audio capture
- **Scoping the capture to a window (app) also scopes the audio to that app**
- Aligning audio and video timestamps (the PTS anchor)
- Pitfalls on the AVAssetWriter side

## Minimal setup: picking up system audio with SCStream

ScreenCaptureKit has three main players:

- `SCShareableContent` — enumerates what can be recorded (displays / windows /
  apps)
- `SCContentFilter` — specifies what to record
- `SCStream` — the actual capture. Delivers frames as `CMSampleBuffer`s

To pick up audio, set `capturesAudio = true` on `SCStreamConfiguration`.
The point is that you get system audio **without touching the microphone**.

```swift
let config = SCStreamConfiguration()
config.capturesAudio = true     // System audio requires the Screen Recording
                                // TCC permission (no microphone permission
                                // needed). Starting fails without it
config.sampleRate = 48_000
config.channelCount = 2
config.queueDepth = 3            // Max frames kept in the stream's queue.
                                 // If your processing falls behind, this
                                 // overflows and frames get dropped
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps
```

Output arrives through `SCStreamOutput`'s
`stream(_:didOutputSampleBuffer:ofType:)`, mixing `.screen` (video) and
`.audio` buffers. The audio in a `CMSampleBuffer` is uncompressed PCM, delivered
as Float32 in **non-interleaved (planar)** layout. Convert it to interleaved
with `AVAudioConverter` or similar before handing it to an encoder
(AVAssetWriter).

## Scoping to a window also scopes the audio to that app

This is the main topic. `SCContentFilter` comes in two flavors:

- **Display filter**
  (`init(display:excludingApplications:exceptingWindows:)`) — a whole display.
  Audio is system-wide too
- **Desktop-independent-window filter**
  (`init(desktopIndependentWindow:)`) — a single window

When you build a stream with the desktop-independent-window filter, **in our
measurements the audio is scoped to that window's app as well**. Record a
meeting app's window and you get the meeting audio, without notification
sounds or music from other apps. The appeal here is that the "notification
sounds leak into my meeting recording" problem is answered by the *structure of
the capture*, not by mut etiquette.

### Child windows are included by default

Window capture has one trap: ScreenCaptureKit **includes the target window's
child windows in the rendered output by default**. If a child window sits
outside the screen, the output frame is expanded to the bounding box of
"parent + child", so the window you wanted ends up shrunk in the frame, with an
off-screen child window sneaking in.

```swift
let config = SCStreamConfiguration()
// Exclude child windows on the stream configuration side (a macOS 14.2+
// property). With the default, the bounding box grows and the window you
// want is rendered smaller. Builds targeting 14.0/14.1 need an
// availability guard
if #available(macOS 14.2, *) {
    config.includeChildWindows = false
}
```

If "the window I recorded looks oddly small" or "some strange panel is in the
frame", suspect this first. Note that the *audio* scoping (only that app's
sound) is decided by the filter and is independent of this setting.

## Audio/video timestamps: the PTS anchor

The `CMSampleBuffer`s ScreenCaptureKit hands you carry a PTS (presentation
timestamp), but **the PTS origins of video and audio are not guaranteed to
line up**. With window capture in particular, the stream's start timing can
make the audio PTS begin *before* the video PTS, and writing it out as-is
shifts A/V out of sync.

The fix is simple: **anchor on the PTS of the first video sample**.

```swift
// When the first video sample arrives
anchor = sampleBuffer.presentationTimeStamp

// On the audio side, discard everything before the anchor
// (trim the leading buffer so it starts at the anchor)
```

From then on, map "PTS − anchor" to second 0 of the output. This **prevents
accumulated drift caused by dropped samples** (a scheme that accumulates by
sample count keeps drifting once a drop happens, so keeping the reference on
the PTS side is safer. Whether long recordings drift at all is a separate,
measure-it-yourself question).

## Pitfalls on the AVAssetWriter side

Three things worth pinning down from experience on the writing side.

**Width and height are mandatory.** If you create the video
`AVAssetWriterInput` without `AVVideoWidthKey` / `AVVideoHeightKey`, it
crashes with `NSInvalidArgumentException`. You will be computing them from the
ScreenCaptureKit output size anyway, so always pass them.

**Match the pixel format to the codec.** For H.264 / HEVC, use
`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (4:2:0 YUV). The encoder's
input is 4:2:0 regardless, so feeding BGRA adds one extra color conversion,
which showed up as a perceptible increase in CPU usage in our measurements.
Conversely, ProRes 422 is 4:2:2, so keep `kCVPixelFormatType_32BGRA`
(downconverting to 4:2:0 defeats the point of an editing intermediate).

**Make termination reach `finishWriting` even on a signal.** For a CLI or any
long-recording tool, if Ctrl+C doesn't run `finishWriting`, you are left with
a half-written, unplayable file. Treat SIGINT / SIGTERM / SIGHUP as *normal
stops* and structure the code so it writes out to the last sample before
reaching `finishWriting(withCompletionHandler:)` — this is a real reliability
step up for a recording tool (forget SIGHUP and closing the terminal leaves a
broken file behind).

## If you also want the microphone

Meeting recording needs "the other side (system audio) + your side
(microphone)". You open the microphone separately with `AVCaptureSession`, and
since **startup takes a few hundred milliseconds**, start it *before* the
ScreenCaptureKit stream. Start SCStream first and the first few seconds of
your own voice are missing from the file
(the microphone path also needs `NSMicrophoneUsageDescription` in Info.plist
and its own microphone TCC permission. System audio alone needs neither).

Mixing is on you. Once both sources' PTS are aligned, it's just resampling to
a common rate and adding — but writing the padding logic (hold the ahead track
back with silence until the late one catches up) makes the mix robust to
per-track start delays.

## Wrapping up

- System audio is recordable without a driver via ScreenCaptureKit
- **With a window (app) filter, the audio is scoped to that app too** — a
  structural fix for the notification-sound problem
- Child windows are included by default; exclude them explicitly
- Base time on PTS, not sample counts. Anchor on the first video PTS
- Writer width/height are mandatory; match the pixel format to the codec
- Even Ctrl+C must reach `finishWriting`, so no unplayable files are left
  behind

Putting all of this together is [kilde](https://kilde.site/), a recorder for
macOS (with the meeting preset, picking a window mixes system audio and your
microphone into a single file — available on the
[Mac App Store](https://apps.apple.com/app/id6812783176)). In the next post,
I'll cover transcribing the recording with SpeechAnalyzer on macOS 26.
