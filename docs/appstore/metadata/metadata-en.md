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
You can now create a transcript — or meeting minutes with a summary — after the fact, right from the recording library, even for recordings made with transcription off (transcription requires macOS 26 or later; summaries need Apple Intelligence). Default H.264 MP4 recordings are also much smaller now (about 200MB per hour).
```

## What's New (0.11.0)

One user-visible change since MAS 0.10.0: transcripts can now be exported as
a plain text file from the recording library (issue #329). The export always
renders the whole transcript in the same readable `[HH:MM:SS] text` format
whatever the sidecar format is, and saving goes through NSSavePanel, which
works unchanged under App Sandbox. No engine update (the pin stays at
kilde-cli-swift v0.10.0) and no new requirements.

```text
You can now export a recording's transcript as a plain text (.txt) file right from the recording library — handy for carrying meeting text into your notes or other tools.
```

## What's New (0.12.0)

One user-visible change since MAS 0.11.0: recordings can now be paused and
resumed from the menu bar panel (issue #338). While paused the elapsed time
freezes, and paused periods are excluded from both the recorded length and
the saved file. The engine behavior itself shipped in kilde-cli-swift
v0.10.0; no engine update (the pin stays at v0.10.0) and no new requirements.

```text
You can now pause and resume a recording from the menu bar panel. Paused periods are excluded from both the recording time and the saved file.
```

## What's New (0.13.0)

The headline change since MAS 0.12.0 is a **free-disk-space check before
recordings start** (the engine v0.13.0 preflight, adopted by moving the pin
from v0.10.0 to v0.14.0). Before recording, the estimated output size is
compared against the free space at the destination: tight space shows a
warning up front, and a clearly insufficient disk refuses to start. Engine
v0.14.0 is mostly CLI-facing improvements with no effect on GUI recording.
Also includes metrics instrumentation (issue #343) with no functional change.

```text
kilde now checks free disk space before a recording starts. You get a warning up front when space is tight, and recording won't start when it clearly isn't enough — so a long recording is far less likely to fill the disk midway.
```

## What's New (0.14.0)

This release focuses on internal improvements: the recording engine has
been updated as groundwork for upcoming features (issue #352). No changes
to recording operations in the GUI.

```text
We've updated the recording engine as groundwork for upcoming features.
```

## What's New (0.15.0)

The single user-visible change since MAS 0.14.0: the capture source
(screen / window / audio only), audio sources and devices, audio track
layout ("Mix into one track" / "Separate per source"), and transcription
settings chosen in the panel are now saved when a recording is started
from the panel (button or global hotkey) and restored on the next launch
(issue #345 / PR #359). The settings are saved only for panel-started
recordings: recordings started via Shortcuts or meeting auto-detection do
not save them (both override the capture target, and meeting auto-detection
also fixes the audio inputs to the meeting setup). "Make this audio &
save location selection the default" now also saves the capture source.
No engine update (the pin stays at kilde-cli-swift v0.15.0).

```text
When you start a recording from the panel, kilde now remembers the capture source, audio sources and devices, audio track layout, and transcription settings selected there, so the next launch starts with the same setup. "Make this audio & save location selection the default" now also saves the capture source.
```

## What's New (0.16.0)

The single user-visible change since MAS 0.15.0: picking a running app in the
popover now records only that app's audio (issue #364 / PR #366). The feature
is **available on macOS 15 or later** (the Audio Process Tap of engine
kilde-cli-swift v0.16.0 — the pin was updated in PR #366); on macOS 14.x the
"Choose app audio" UI is not shown at all. It can be combined with the
microphone, but app audio and system audio cannot be recorded at the same
time (picking an app turns system audio off). The selection is stored by
bundle ID when a recording starts from the panel (the save-as-default button
does the same) and carried over to the next launch (a not-running app shows
"(not running)" with guidance when you start recording).

```text
Pick a running app in the popover to record only that app's audio (requires macOS 15 or later). You can combine it with the microphone, but app audio and system audio can't be recorded at the same time. kilde remembers your selection when you start a recording and carries it over to the next launch.
```

## What's New (0.17.0)

No user-visible change since MAS 0.16.0. As an internal improvement, the
capture source (display / audio-only) saved when a recording starts is now
stored in the same settings file as the other recording settings (the
`defaultTarget` key of config.json — issue #372 / PR #373; engine
kilde-cli-swift v0.17.0, kilde-cli-swift#123). **The save timing is
unchanged — a recording start** (the panel's start button, or the global
hotkey; recordings started via Shortcuts or the meeting auto-recorder are
not saved; the "make this the default" button saves the same content without
starting a recording), and a window selection is still kept inside
the app because a window ID is reassigned per app launch (the existing
validated restore path is unchanged). What's New keeps the "what changed,
what did not" wording precise and short (stating that the save happens when
a recording starts — an ambiguous line that could read as "saved behind your
back" was flagged by cubic before).

```text
The capture source (display or audio-only) selected when you start a recording from the panel or the global hotkey is now saved to the same settings file as the other recording settings. The save timing is unchanged (when a recording starts) and recording behavior is unchanged.
```

## What's New (0.18.0)

Tips (the MAS portion of issue #171). Three consumable IAP products
(kilde.tip.small / kilde.tip.medium / kilde.tip.large) can be purchased from
the "Support this app" section at the bottom of the panel. The issue's
"do not degrade the free experience" policy is reflected in the UI: the
section is hidden entirely when the product list cannot be fetched, and a cancelled
purchase shows nothing and a failed purchase shows a single caption line, and
neither raises an alert. The amounts follow the proposal in the issue (¥160 / ¥480 / ¥1,200;
price tiers 1 / 3 / 8 in ASC). The direct-distribution (DMG) build shows
nothing — the "link to Sponsors" part of the issue stays unimplemented until
the GitHub Sponsors application (bank setup) is done, and will be added
separately afterwards (issue #171 is scoped here to "the MAS tips pass
review"). The What's New states explicitly that every feature stays free
(conveying both the addition and what remains unchanged).

```text
Added a "Support this app" section at the bottom of the panel where you can send a tip in three amounts (store version only). All recording and transcription features remain free of charge.
```

## What's New (0.19.0)

The Transcribe action on the recording-completed notification (issue #392):
a one-tap path from the success moment, enqueueing with the settings as of
the tap (format / locale; no summary). Recordings that were already
transcribed open the existing sidecar instead of creating a `-2` duplicate.
The notification carries a security-scoped bookmark, so tapping after
changing the destination and relaunching still processes the old folder's
recording. Unsupported Macs (below macOS 26) do not get the action at all.

```text
Added a "Transcription" action to the recording-completed notification. Start transcribing a finished recording right from the notification (transcription requires macOS 26 or later and the speech data for your language).
```
## What's New (0.20.0)

Calendar meeting names (issue #393): an opt-in sub-setting of meeting
auto-recording looks up the calendar ahead of the start and names the
recording `kilde-<timestamp>-<event title>` (engine kilde-cli-swift#132,
`RecordRequest.outputTitle`). The title is also used in the recording-started
notification and the transcript heading. Permission is requested when the
toggle is turned on, and again when the panel is opened with the toggle on
and the permission still unanswered (`requestFullAccessToEvents`, macOS 14+ —
macOS has no read-only calendar grant, so the request is for full access, but
the app only reads events). Denied permission, no overlapping event, or a
lookup that has not finished all fall back to the default file name.

```text
Meetings detected by auto-recording can now be named after your calendar events. Enable "Use calendar event names for recording file names" and the overlapping event's title is used for the recording file name, the recording-started notification, and the transcript heading. The calendar is only read for this feature on-device and your calendar content is never sent over the network (off by default).
```
## What's New (0.21.0)

Automatic transcription language (issue #409, engine kilde-cli-swift#131;
design in cli-swift SPIKE-NOTES F-Q). Adds "Automatic (detect from recording)"
to the transcription language setting (the default stays "Device language").
When selected, the first 30 seconds of **each audio track** are transcribed
with the candidate locales (device language, Japanese, English) and the
locale with the highest duration-weighted mean confidence wins. Separate-track
recordings get e.g. the peer's track in English and your microphone track in
Japanese. Undecided tracks (no speech in the head window / near tie) fall
back to the device language. No new permissions; audio and transcripts
never leave the device (missing language models are downloaded from Apple,
as with fixed languages).

```text
The transcription language setting gains "Automatic (detect from recording)". It detects the meeting language from the first 30 seconds of the recording (candidates: your device language, Japanese, English) and transcribes in it; with separated audio tracks, the peer's track and your own microphone track are transcribed each in their own language. When detection cannot decide, the device language is used as before. Transcription requires "Transcribe after recording" to be enabled and macOS 26 or later with the speech data (language model) for the language (the default setting is unchanged; audio and transcripts are never sent over the network — missing language models are downloaded from Apple — as with any network request, the download reaches Apple with your IP address).
```


## What's New (0.22.0)
Importing existing files (issue #416). The library window gains an
"Import Files…" picker (multiple selection) plus drag & drop, so audio/video
files recorded before kilde — or with other tools — can be transcribed
(the GUI counterpart of `kilde transcribe`; **transcription stays free**).
Files are **copied into the output folder** — under the App Store sandbox the
app cannot write a sidecar next to an arbitrary user-selected file — as
`kilde-<date>-<original name>`, then fed into the existing transcription
queue (language/format are snapshotted when the import starts; no summary).
A file with the same name and byte size already in the folder counts as
imported, so re-importing does not duplicate (a name+size heuristic — not a
guaranteed content identity).
No new permissions; recording and transcription remain free (no purchases
except the 0.18.0 tips).

```text
The library can now import existing audio/video files (MOV, MP4, M4V, M4A, MP3, WAV, AIF/AIFF, CAF, AAC). Pick a file or drop it onto the library window — recordings made before kilde or with other tools are copied into the output folder and transcribed on device (the original file stays untouched; a file whose name and size match an existing import is not copied again). Imported recordings become searchable in the library. Importing and transcription require macOS 26 or later plus the language's speech data. Also fixed: the menu bar panel could keep the compact height used during recording after the recording ended.
```

## What's New (0.23.0)

Maintenance release with no functional change (issue #426). Its purpose is to
register the App Store preview videos (ja / en, generated in kilde#399 and
measured at 1920×1080 / H.264 / 29.9 s) — version assets are locked while a
version is in review or released, so creating 0.23.0 (PREPARE_FOR_SUBMISSION)
is the first opportunity to attach them (see the 2026-10-24 comment on
issue #160). Everything merged since v0.22.0 is selftest hardening
(issue #424) with no user-visible change. Following the 0.9.0 precedent, the
What's New copy states plainly that this is a maintenance release.

```text
This is a maintenance release with no changes to recording or transcription. It ships alongside the new app preview video on the App Store product page.
```

## What's New (0.24.0)

Opt-out for usage statistics and crash reports (issue #435). A new "Privacy"
section in the panel settings; unchecking "Send app usage statistics and crash
reports" stops both Firebase Analytics and Crashlytics **immediately** and
deletes unsent crash reports. When launched with the setting off the app never
calls `FirebaseApp.configure()`. **On by default** (what is collected does not
change — what changes is that it can be stopped). This is the release that lets
docs/launch/faq.md §2 ("Can I turn it off?") answer "Yes" before the launch
posts (#157). No engine change (pin v0.19.0). The measured elements
(description / keywords / subtitle / screenshots) are unchanged.

```text
New "Privacy" setting. Uncheck "Send app usage statistics and crash reports" to stop both right away — the usage statistics that help improve the app and the crash reports that help fix bugs — and to delete any crash reports still queued on your Mac. When launched with the setting off, the app does not initialize the analytics SDK at all. It is on by default and nothing new is collected; your recordings, transcripts, and file names are never sent, whatever the setting.
```
