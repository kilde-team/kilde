# App Store metadata — English (en-US)

**Issue #160 (2026-09-26) update**: rewritten to lead with transcription and
summaries (0.8.1) and to drop third-party trademarks (meeting-service names,
audio-driver names) from the description and keywords. Subtitle now carries
"record & transcribe". The previous copy (system-audio-first, 0.4.0–0.6.0)
lives in git history and in the before-record in [metrics.md](metrics.md).

## App name (≤30)

```text
kilde: Screen & Voice Recorder
```

(em dash + spaces would be 31 chars, hence the colon — metadata README)

## Subtitle (≤30)

```text
Record & transcribe meetings
```

(28 chars. Keeps the differentiators "record" + "transcribe" in the
indexed subtitle; "system audio" moved to keywords and the description.
Previous: "System audio + mic, one file")

## Description

```text
kilde records your screen and audio together — an open-source screen and audio recorder for macOS. It captures the system audio that the built-in screen recording can't, in one click.

FOR MEETINGS
Record online meetings with the other participants' voices (system audio) and your own voice (microphone) mixed into a single file. Keep the sources as separate tracks and the transcript labels each speaker (you / the other side). Meeting windows can even be detected and recorded automatically (off by default).

TRANSCRIBE AND SUMMARIZE (MACOS 26 OR LATER)
When a recording finishes, kilde transcribes it entirely on this Mac and writes a Markdown transcript next to the file. On Macs with Apple Intelligence enabled it can also draft a meeting summary. Audio and transcripts never leave your device.

FIND ANY MOMENT
Transcripts are searchable in the recording library: search the full text and jump straight to the moment it was said — no more scrubbing through hour-long recordings.

FEATURES
- Screen + system audio with zero setup (native ScreenCaptureKit)
- Record a microphone or audio interfaces at the same time (mixed or separate tracks)
- Window capture — audio is scoped to that app
- Audio-only recording (M4A), no extra driver needed
- Start and stop with global hotkeys or the Shortcuts app
- Whether you stop recording or quit the app, your file is always finalized

PRIVACY
Your recordings and transcripts never leave your Mac. The developer only receives aggregated usage statistics such as launch counts, and crash reports when the app crashes — never the content of your recordings. See PRIVACY.md at github.com/kilde-team/kilde.

REQUIREMENTS
macOS 14 or later (Apple Silicon); transcription and summaries require macOS 26 or later. Free, no ads, open source (MIT).

The GUI shares the same recording engine as the `kilde` command-line tool.
Learn more at https://github.com/kilde-team/kilde
```

(Section headers in caps; Apple renders the description as plain text.)

## Keywords (≤100)

```text
system audio,transcription,microphone,window capture,screen capture,video,minutes,summary,mp4
```

(93 chars. "screen", "recorder", "record", "transcribe" and "meetings" are already
indexed via the name and subtitle, so the keywords spend their budget on other
terms. Dropped "Zoom" — third-party trademark (issue #160).)

## What's New (0.6.0)

The only change from 0.5.0 is internal (crash reporting), so the copy stays
honest and short — do not pad it with feature claims.

```text
Stability and reliability improvements.
```

## What's New (0.8.1)

```text
Adds on-device recording transcription and summaries, Shortcuts support for starting and stopping recordings, and a recording library with full-text search and playback from the exact moment. Transcription now also survives changing the save destination mid-recording.
```

## What's New (0.8.2)

The only change since 0.8.1 is the App Store screenshots (issue #266); the app
itself is identical (build number only). Keep the copy honest and short.

```text
Updated the App Store product page. No changes to the app's features.
```

## What's New (0.8.3)

The only changes since 0.8.2 are internal telemetry: recording-completion
analytics and migrating the recordings lifetime counter off the MAS
review-prompt counter (issue #159). No user-visible feature changes — #283
(update-dialog release notes) is not in the MAS build, where
UpdaterCoordinator is compiled out with `#if !APPSTORE`. Keep the copy honest
and short.

```text
Internal improvements to the app. No changes to the app's features.
```

## What's New (0.8.4)

First user-visible changes since 0.8.2: Open Folder buttons on the completion
screen and the recent-recordings rows (issue #296 / PR #297), and detection of
capture interruptions — when ScreenCaptureKit stops the stream on its own
(e.g. after a display change on macOS 26), the recording is finalized up to
that point and the app notifies (issue #298 / PR #299, engine v0.8.2). UI
terms match Localizable.xcstrings (en).

```text
Adds Open Folder buttons to the recording completion screen and the recent recordings list. Also includes a stability improvement: if the capture is interrupted, kilde now detects it, saves the recording up to that point, and notifies you.
```

## What's New (template)

```text
Summarize this version's changes in 1–3 lines (fixes and new features).
```

## What's New (0.8.5)

One user-visible change since 0.8.4: the recording engine is updated to
kilde-cli-swift **v0.9.0**, which adds an **automatic restart** after capture
interruptions (kilde-cli-swift#73 / issue #304). When ScreenCaptureKit stops the
stream on its own (e.g. after a display reconfiguration), v0.8.2 finalized the
recording right there; the engine now resumes into the same file up to 3 times.
The GUI switches the notification to a "resumed automatically" wording via
`Summary.captureRestartCount`.

```text
Screen recording now resumes automatically after interruptions such as display connection or resolution changes, continuing into the same file. If the capture cannot be resumed, kilde still saves the recording up to that point and notifies you.
```

## What's New (0.9.0)

No functional change since 0.8.5: this submission aligns the App Store version
number with the direct-distribution release v0.9.0 (issue #307 / issue #310).
The automatic restart after capture interruptions (0.8.5) and the "Open Folder"
button (0.8.4) have already reached App Store users, so the What's New copy
simply states this is a maintenance release.

```text
This is a maintenance release. The version number is aligned with the direct-distribution build. There are no changes to the recording features.
```

## What's New (0.10.0)

Two user-visible changes since 0.9.0. Recordings made with transcription
disabled can now be transcribed — with optional meeting minutes (summary) —
right from the library window (issue #321). The engine is updated to
kilde-cli-swift **v0.10.0** (issue #316) with retuned default bitrates
(kilde-cli-swift#86), bringing the default mp4 recording down to roughly
200MB per hour. The "raise the bitrate in config.json" workaround from the
release notes does not apply to the sandboxed App Store build, so it is left
out of the copy.

```text
You can now create a transcript — or meeting minutes with a summary — after the fact, right from the recording library, even for recordings made with transcription off. Recording files are also much smaller by default now (about 200MB per hour).
```
