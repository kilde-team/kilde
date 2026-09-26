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

## What's New (template)

```text
Summarize this version's changes in 1–3 lines (fixes and new features).
```
