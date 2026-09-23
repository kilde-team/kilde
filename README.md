[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [한국어](README.ko.md) | [Español](README.es.md)

# kilde

[![Release](https://github.com/kilde-team/kilde/actions/workflows/release.yml/badge.svg)](https://github.com/kilde-team/kilde/actions/workflows/release.yml)

An open-source screen and audio recorder for macOS.

kilde records your screen together with **system audio that QuickTime Player's
screen recorder cannot capture** — as a single-command CLI and as a menu bar
app.

The project is split across two repositories (issue #115):

| Repository | Contents | Visibility |
|---|---|---|
| [kilde-team/kilde](https://github.com/kilde-team/kilde) (this one) | Menu bar app (`gui/`), release signing and distribution, Homebrew formula, documentation | Public |
| [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift) | The recording engine (`KildeCore`) and the `kilde` CLI source | Private (kilde-team members) |

## Features

- 🖥️ Record the screen and system audio with zero setup using native
  ScreenCaptureKit capture
- 🎤 Record a microphone or another input device such as BlackHole at the same
  time
  - Mix multiple sources into **one track** by default, or keep separate tracks
    with `--audio-tracks separate`
- 🪟 **Capture a single window** and scope system audio to its app, excluding
  notification sounds and audio from other apps
- 🎙️ Record audio only with `--no-video`, with no additional driver required
- 🛡️ Safely finalize the output file when you stop recording with Ctrl+C
- ⌨️ Start and stop recording with a global hotkey while working in another app
- 📝 Transcribe recordings to markdown/SRT/VTT/text/JSON sidecar files,
  entirely on device (macOS 26+)

## Installation

- macOS 14 or later
- Transcription requires **macOS 26 or later**
- Release binaries are **arm64 (Apple Silicon) builds** — Intel Macs are not
  supported at this time
- Runtime testing is currently performed on macOS 26 on Apple Silicon
- Requires a toolchain with the macOS 26 SDK to build (the engine references
  the macOS 26 API `captureHDRRecordingPreservedSDRHDR10`; runtime still
  supports macOS 14+)

### Mac App Store

The menu bar app is on the Mac App Store — installs in one click and the App
Store keeps it up to date automatically:

<a href="https://apps.apple.com/app/id6812783176">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/appstore/badge/mac-app-store-badge-en-white.svg">
    <img src="docs/appstore/badge/mac-app-store-badge-en-black.svg" alt="Download on the Mac App Store" height="40">
  </picture>
</a>

### Homebrew

```sh
brew tap kilde-team/kilde
brew trust --formula kilde-team/kilde/kilde   # one-time, newer Homebrew only
brew install kilde

# Or install directly from the tap
brew install kilde-team/kilde/kilde
```

### Release binaries

Download `kilde-<version>-macos.zip` from
[GitHub Releases](https://github.com/kilde-team/kilde/releases), unzip it, and
put the `kilde` binary on your `PATH`:

```sh
unzip kilde-*-macos.zip && sudo cp release/kilde /usr/local/bin/
```

### Building from source

The `kilde` CLI and the `KildeCore` engine are developed in
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift),
which is **private**, so public source builds are not available at this time —
please use Homebrew or the release binaries. kilde-team members can clone that
repository and build it with `swift build` there (see its documentation).

## Getting started

Start with `doctor`. Screen recording and microphone capture require macOS
permissions, and this command checks the environment and prompts for any
permissions you still need:

```sh
kilde doctor
```

Then record your screen and system audio. Press Ctrl+C to stop and safely
finalize the file:

```sh
kilde rec demo.mov
```

Use the other commands to discover capture targets, inspect a recording, and
manage persistent recording defaults:

```sh
kilde devices         # List displays, windows, and audio devices
kilde inspect FILE    # Show tracks and audio levels in a recording
kilde transcribe FILE # Transcribe a recording to a sidecar file (macOS 26+)
kilde config show     # Show configured values and effective defaults
```

## Recording examples

Record the whole screen (the default), or part of it. `--region` takes
`x,y,w,h` in points with the origin at the top-left. Width and height are
rounded down to even values for H.264; a region outside the display fails
before recording starts (exit 1), and malformed or sub-2-point values are
argument errors (exit 64). It cannot be combined with `--window`,
`--no-video`, or `--preset meeting`:

```sh
# Whole screen + system audio (default)
kilde rec demo.mov

# Part of the screen
kilde rec --region 0,0,1280,720 demo.mov
```

Record a Zoom, Google Meet, or Teams meeting. The meeting preset prompts you to
choose a window, then mixes the other participants' system audio and your
microphone into one track:

```sh
kilde rec --preset meeting meeting.mov
```

Add a microphone explicitly, record audio only as M4A, or scope capture to a
specific app window. `--window` accepts a partial title, bundle ID, or window ID
match; use `kilde devices` to find available windows.

```sh
# Screen + system audio + microphone
kilde rec --audio system --audio mic out.mov

# Audio only
kilde rec --no-video memo.m4a

# Only the audio from a matching Zoom window, excluding other apps
kilde rec --no-video --window zoom meeting.m4a

# Several windows in one file. Pass --window more than once; the output is the
# size of the whole display, with everything outside those windows left black
kilde rec --window zoom --window notes demo.mov

# Hide specific apps from a full-screen recording, such as a password manager
# or a chat client. Bundle IDs match exactly -- run `kilde devices` to find them
#   Note: an excluded app's *audio* is dropped too. Excluding a meeting app or a
#   browser loses its sound as well, so if you only want to hide what is on
#   screen, consider recording the windows you want with --window instead
kilde rec --exclude-app com.1password.1password --exclude-app com.tinyspeck.slackmacgap demo.mov

# HDR capture, which needs macOS 15 or later, an HDR display, and HEVC.
# Output is HEVC Main10 with PQ; primaries follow the OS preset
#   (macOS 26: BT.2020 with HDR10 metadata, 15: Display P3)
#   Where any of that is missing, kilde records SDR, says why, and still exits 0 --
#   it will not hand you a file you believe is HDR when it is not
kilde rec --hdr --codec hevc demo.mov
```

To record through BlackHole while still hearing the audio, install BlackHole
and use monitor mode. Monitor mode temporarily sets up and tears down the
required multi-output device for the recording session.

```sh
brew install --cask blackhole-2ch
kilde rec --no-video --audio "device:BlackHole 2ch" --monitor meeting.m4a
```

Start kilde in hotkey-waiting mode and use Cmd+Shift+R globally to start and
stop recording. Pressing Ctrl+C while waiting exits without creating a file.
`--hotkey` cannot be combined with `--countdown`.

```sh
kilde rec --hotkey cmd+shift+r meeting.mov
```

`--duration` *can* be combined with a hotkey, but it is counted from the moment
the wait ends — not from launch. A `hotkey` in the configuration file therefore
turns even `kilde rec --duration 30s` into a command that waits for the key, so
an unattended script would sit there until someone presses it (Ctrl+C, SIGTERM
and SIGHUP all exit cleanly). kilde prints a warning to stderr when a
*configured* hotkey defers a `--duration` you asked for; an explicit `--hotkey`
stays quiet, since waiting is then what you asked for. To record unattended,
remove the configured key with `kilde config unset hotkey`.

### Transcribing after recording

Add `--transcribe` and kilde transcribes the recording into a sidecar file
(`meeting.md`) as soon as the recording file is finalized (macOS 26+, no
Speech recognition permission needed):

```sh
kilde rec --transcribe --preset meeting meeting.mov
```

Transcription runs entirely on your Mac (on device) — neither the audio nor
the transcript text is ever sent anywhere. It starts only after the recording
file is complete, so a failure or interruption never touches the recording
itself. Pressing Ctrl+C while the transcription is running interrupts just the
transcription — the recording file stays on disk and the exit status is still
`0`. A transcription *failure* (such as an unsupported environment, locale, or
model download failure) exits `1`, because you explicitly asked for it.
`--transcript-format md|srt|vtt|txt|json` picks the sidecar format and
`--locale ja-JP` picks the language. In a `--no-video --audio-tracks separate`
recording, the two audio tracks are transcribed with speaker labels
("相手" for the system-audio track, "自分" for the mic track). You can also
transcribe an existing recording with `kilde transcribe FILE`.

### Why is BlackHole not required?

kilde uses ScreenCaptureKit's native system-audio capture, so ordinary screen
and audio recording works without a virtual audio driver. BlackHole is only
needed for specialized routing, such as monitor mode, where you want to listen
to audio while recording it through another path.

## Recording options and defaults

By default, kilde captures display `0`, records `system` audio into a `mixed`
audio track, uses the H.264 video codec, and includes the cursor. If no output
path is supplied, it creates `kilde-yyyyMMdd-HHmmss.mp4` (an `.mov` file when
`--format mov` is selected, or when ProRes forces the default container back to
`mov`), or an `.m4a` file in audio-only mode. Run `kilde rec --help` for the
complete option list.

Common options include:

- `--display NUMBER` or `--window MATCH` to select the capture target
- repeatable `--audio system|mic|device:NAME_OR_UID|none` to select audio sources
- `--audio-tracks mixed|separate` to mix sources or preserve separate tracks
- `--no-video`, `--monitor`, `--duration 30s` (counted from the end of a hotkey
  wait, not from launch), `--codec h264|hevc|prores`, `--fps NUMBER`, and
  `--format mov|mp4` (the output path's `.mov`/`.mp4` extension also selects
  the container; ProRes cannot go into MP4, so a standalone `--codec prores`
  falls back to `mov`)
- `--cursor` or `--no-cursor`, `--countdown SECONDS`, `--preset meeting`, and
  `--hotkey SHORTCUT`
- `--transcribe` (with `--transcript-format` and `--locale`) to transcribe the
  recording into a sidecar file once it is finalized (macOS 26+)
- `-o PATH` or `--output PATH` as an alternative to the positional output path

## Configuration

Persistent `rec` defaults are stored in `~/.kilde/config.json`. Manage them
with `kilde config show|set|unset|path` rather than editing the file by hand.

```sh
kilde config set outputDirectory ~/Movies/kilde
kilde config set defaultAudioSources system,mic
kilde config set showsCursor false   # Use kilde rec --cursor to override it once
kilde config set hotkey cmd+shift+r  # Start rec in hotkey-waiting mode (see below)
kilde config set transcribe true     # Transcribe every recording when it stops
kilde config set transcriptFormat srt
kilde config set locale ja-JP
kilde config show
kilde config unset hotkey
kilde config path
```

The supported keys are `outputDirectory`, `defaultAudioSources`, `audioTracks`,
`codec`, `fps`, `showsCursor`, `hotkey`, `transcribe`, `transcriptFormat`, and
`locale`.

Recording settings are resolved in this order, from highest to lowest priority:

1. CLI arguments
2. `--preset`
3. Environment variables such as `KILDE_OUTPUT_DIR`
4. The configuration file
5. Built-in defaults

The hotkey has its own equivalent order: `--hotkey`, then the configured
`hotkey`, then no waiting mode.

A global hotkey can only be held by one process at a time, so **whichever
registers it first wins**. This matters when the menu bar app is running,
since it launches at login and holds the configured hotkey. When `rec`
finds the key already taken, a hotkey that came from the configuration
file is skipped: it prints a warning and starts recording immediately
instead of waiting. An explicit `--hotkey` fails with the reason instead,
because waiting is what you asked for.

`rec` checks whether the key is available just before it decides, so a
process that grabs the key in between still makes it exit with the
registration error — in practice that needs two recordings started at the
same moment, since a hotkey held by the GUI is caught by the check.

Set `KILDE_CONFIG_DIR` to relocate both `config.json` and
`monitor-state.json`, which is useful for isolated environments and testing.
Its value must be an absolute path or start with `~`; relative paths are
rejected. Invalid configuration or a missing output directory fails before
recording with exit status `1`.

## Exit statuses

| Status | Meaning |
|---:|---|
| `0` | Success, including a recording safely stopped by SIGINT, SIGTERM, or SIGHUP. Interrupting the post-recording transcription of `rec --transcribe` with Ctrl+C also exits `0` — the recording file stays on disk |
| `1` | Other runtime failure, including invalid configuration. A failed post-recording transcription of `rec --transcribe` (unsupported environment or locale, model download failure, sidecar write failure) exits `1` too — the recording file stays on disk, but you explicitly asked for the transcription |
| `2` | Missing permission |
| `3` | Display, window, or audio device not found |
| `64` | Command-line parsing or option validation error, such as `rec --fps 0` |

## GUI

The menu bar app in `gui/` uses `NSStatusItem` and `NSPopover`. It is managed
manually with AppKit because SwiftUI `MenuBarExtra` with a `.window` panel does
not open on macOS 26. It shares the same `KildeCore` recording engine as the
CLI through a **pinned** dependency on
[kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
(private — package resolution requires kilde-team git credentials). Generate
the uncommitted Xcode project from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen   # First time only
cd gui && xcodegen
open KildeGUI.xcodeproj # Run the KildeGUI scheme in Xcode
```

After building, a ● icon appears in the menu bar. Click it to choose the
capture target (screen / window / audio only), audio sources, and the output
directory, then start recording. While recording, the menu bar shows the
elapsed time and the panel shows per-source level meters. Closing the panel
does not stop the recording. Initial values are read from the same
`~/.kilde/config.json` as the CLI.

When a recording finishes, a notification shows its name, length, and size;
clicking it reveals the file in Finder. The panel also lists the five most
recent recordings in the output directory — including ones made with the CLI —
and clicking one reveals it in Finder. Set a global hotkey in the panel to
start and stop recording from any app; it is stored as `hotkey` in the same
configuration file, so `kilde rec` picks it up as well. A checkbox registers
the app to launch at login through `SMAppService`, which macOS may ask you to
approve in System Settings.

## Development

- Engine and CLI (`KildeCore`, `kilde`): developed in
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
  (private) — its repository owns the tests and CI
- Menu bar app, release workflow, and Homebrew formula: this repository
  - Build, permissions, and GUI troubleshooting:
    [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  - Official releases (signing, notarization, distribution):
    [docs/RELEASE.md](docs/RELEASE.md)
- Architecture and behavior: [docs/DESIGN.md](docs/DESIGN.md)
- M0 spike results: [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- Monetization strategy survey (Japanese):
  [docs/MONETIZATION.md](docs/MONETIZATION.md)

## Roadmap

- **M0** ✅ Technical spike: validated ScreenCaptureKit audio capture
- **M1** ✅ CLI MVP: `kilde rec / devices / doctor / audio monitor / inspect`
  (the engine and CLI source now live in
  [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift),
  issue #115)
- **M2** Global hotkey ✅; region capture ✅; pause/resume
- **M3** Menu bar GUI app: skeleton ✅ / recording UI ✅ / permission
  onboarding ✅ / completion notifications, recent recordings, global hotkey,
  and launch at login ✅

## The name

*kilde* is the Danish and Norwegian word for **source** — literally a
spring, where water rises from the ground, and by extension the source of
a piece of information, as in a journalist's or a scholar's sources.

More and more knowledge is now created in online meetings and on screens.
In an era when AI can transcribe, summarize, and search recordings, those
recordings — the video, the audio, the screen — are valuable sources of
information in their own right, not byproducts to discard once the meeting
is over. kilde is named for the thing it exists to keep: the source. The
same conviction is why kilde is built so that stopping a recording — even
with Ctrl+C — always leaves a finalized, playable file. A source you
cannot open again is no source at all.

## Contributing

Bug reports, feature requests, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) to get started. Work on the recording
engine and the CLI happens in kilde-team/kilde-cli-swift.

## License

[MIT License](LICENSE)
