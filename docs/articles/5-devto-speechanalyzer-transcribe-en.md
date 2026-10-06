---
title: "Transcribing meeting recordings with SpeechAnalyzer on macOS 26 — feeding PCM from a file"
published: false
description: "SpeechAnalyzer is the on-device transcription API in macOS 26. Notes on the file path: AVAssetReader → PCM, the big-endian trap, speaker separation, and cancellation."
tags: macos, swift, speechframework, avfoundation
canonical_url: https://zenn.dev/takezou621/articles/7a8de3ca6ccb59
---

**この原稿について** (リポジトリ内の注記です。dev.to に転載するときは削除してください):
issue #312 で追加した Zenn 公開済み記事 2 の英語版です。front matter の
`canonical_url` に Zenn 版を設定してあるので、dev.to に載せるときはこのまま使えます
(kilde.site blog に原典として載せるときは canonical を外す)。公開時に
英語版記事 1 (前編) へのリンクを «前回» の位置に張ってください。
原文: `2-zenn-speechanalyzer-transcribe.md`。

---

*This post generalizes what we learned adding post-recording transcription to
[kilde](https://kilde.site/), a screen and audio recorder for macOS.*

## What SpeechAnalyzer is

`SpeechAnalyzer`, added to the Speech framework in macOS 26, is an API for
transcribing long audio **on-device**. Where the older `SFSpeechRecognizer` is
shaped like "talk into a recognition session", SpeechAnalyzer is shaped like
**stream processing: you feed PCM into an analyzer**.

- `SpeechTranscriber` — audio → a sequence of text segments. Time ranges are
  attached via an option described below
- `AssetInventory` — secures the language model. Models are managed by the
  system; when the model for a language isn't on the device, a download from
  Apple is triggered
- `SpeechAnalyzer` — the engine you attach modules (transcriber, etc.) to and
  feed input

You wrap an `AVAudioPCMBuffer` in an `AnalyzerInput` to deliver audio. Besides
"microphone in real time", this is the main path when transcribing an
**already-recorded file** (execution targets Apple silicon Macs; the rest of
this post is about the file path).

## File → PCM: reading with AVAssetReader

From a recording file (MOV / M4A), expand the audio track to linear PCM with
`AVAssetReader` and hand the buffers to the analyzer.

```swift
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    // ★ Don't omit this. See below
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]
let reader = try AVAssetReader(asset: asset)
reader.add(try AVAssetReaderAudioMixOutput(audioTracks: tracks,
                                           audioSettings: settings))
```

### ★ Do not omit `AVLinearPCMIsBigEndianKey`

This is the single most important point in this post. **When you request
16-bit integer PCM without this key, AVAssetReader on macOS 27 outputs
big-endian** (on macOS 26 the default was little-endian, so the problem never
surfaced).

On-device SpeechAnalyzer expects little endian. When a big-endian buffer
arrives, the audio "sounds reversed and broken" would still be a nice outcome —
in practice **the process dies on an internal assert** (EXC_BREAKPOINT).
"Code that worked for months starts crashing the day the OS updates" is almost
always one of these implicit defaults changing. The lesson: when requesting a
format, be explicit down to the byte order.

### When the input is already PCM

An even nastier case: the input source is itself LPCM. For example, the M4A
that `say -o voice.m4a` produces contains 16-bit **big**-endian I16, and the
reader can pass that byte order straight through
(it goes through a path where the little-endian setting you requested isn't
applied). Normal M4A files are compressed (AAC etc.), so they don't hit this.
It surfaces with "uncompressed LPCM inside a container" inputs (AIFF, `say`
output, and so on).

The defense is easy: **validate the ASBD (AudioStreamBasicDescription) on the
first buffer, and if it doesn't match what you expected, convert it with
`AVAudioConverter` before feeding the analyzer**. Making "don't trust the
reader; validate on the first buffer" a habit lets one implementation survive
the diversity of input formats (recording files, audio-only M4A, third-party
WAVs…).

## Segments and timestamps

`SpeechTranscriber` results arrive as an AsyncSequence. Each segment can carry
a time range within the audio, but **time ranges are not attached by default**.
You must specify `SpeechTranscriber.ResultAttributeOption.audioTimeRange` when
creating the transcriber (or pick a preset that includes timing) — the standard
`.transcription` preset does not include them, so this is a mandatory setting
if you're building SRT or WebVTT. Once you have time ranges,
**a segment's time = its time in the recording**, and you can format directly
into SRT / WebVTT / Markdown.

For meeting transcription, **speaker separation** is what pays off.
SpeechAnalyzer has no speaker diarization, so you solve it on the recording
side:

- Record system audio (the others) and the microphone (you) as **separate
  tracks**
- Transcribe track by track
- Merge on timestamps into a transcript labeled "others / me"

Once mixed into a single file they can't be separated afterwards, which is why
separation at recording time matters. This is why a recorder should offer
"separate tracks", not just "mixed into one track".

## The cancellation trap

Long transcriptions must of course be cancellable, but **canceling before the
analyzer has consumed even one sample can leave it unresponsive**
(observed on macOS 26). Users cancel "right after starting" all the time, so
this needs a guard:

- Check for cancellation immediately before starting transcription and right
  after launching the analyzer
- Cancellation after consumption has started stops correctly, so the only
  window you need to plug is the short one before start

## Formatting the output

What you get is a sequence of timestamped text segments; format per use case:

- **Markdown** — a human-readable transcript, with headings and timestamps
- **SRT / WebVTT** — subtitle playback in a video player
- **JSON** — structured data to hand to a downstream LLM

The formatting itself is plain string processing, but deciding the surrounding
conventions up front — "segment times are relative to the recording" and
"never overwrite an existing file at the destination (sidecars get a sequence
number or exclusive creation)" — makes the tool noticeably more trustworthy.

## Wrapping up

- SpeechAnalyzer is on-device, stream-shaped transcription. The file path is
  AVAssetReader → PCM → `AnalyzerInput`
- **Don't omit `AVLinearPCMIsBigEndianKey`** — on macOS 27 the reader can
  output big-endian, and the Speech side takes the whole process down
- If the input source is already PCM, byte order can slip through unchanged.
  Validate the ASBD on the first buffer and normalize with `AVAudioConverter`
- Speaker separation is solved on the recording side (track separation), not
  in the analyzer
- Guard the cancel-right-before-start window

[kilde](https://kilde.site/) does recording through this whole pipeline in one
flow (with «transcribe after recording» enabled, transcription kicks off the
moment you stop — available on the
[Mac App Store](https://apps.apple.com/app/id6812783176) and via Homebrew).
