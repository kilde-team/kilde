[English](README.md) | [日本語](README.ja.md)

# kilde

[![CI](https://github.com/takezou621/kilde/actions/workflows/ci.yml/badge.svg)](https://github.com/takezou621/kilde/actions/workflows/ci.yml)

An open-source command-line screen and audio recorder for macOS.

kilde records your screen together with **system audio that QuickTime Player's
screen recorder cannot capture**, all with a single command. It is CLI-first,
with a menu bar app in development.

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

## Installation and build

- macOS 14 or later
- Runtime testing is currently performed on macOS 26 on Apple Silicon

### Homebrew

The Homebrew tap is available (v0.1.0+). Install kilde with either form:

```sh
brew tap takezou621/kilde
brew trust --formula takezou621/kilde/kilde   # one-time, newer Homebrew only
brew install kilde

# Or install directly from the tap
brew install takezou621/kilde/kilde
```

To build the latest `main` branch from source through Homebrew, add `--HEAD`:

```sh
brew install --HEAD takezou621/kilde/kilde
```

The HEAD build requires a toolchain with the macOS 26 SDK (Xcode 26 or
later). The code references `captureHDRRecordingPreservedSDRHDR10`
(macOS 26 API), which older SDKs lack, so **any pre-26 toolchain —
Xcode 15 and 16 alike — fails with `has no member`**. Runtime still
supports macOS 14+; users on older OSes should use the release binaries.

### Build from source

Building from source requires Swift Package Manager and a toolchain
with the macOS 26 SDK (Xcode 26 or later; pre-26 SDKs fail to compile —
see the note under Homebrew above).

```sh
git clone https://github.com/takezou621/kilde.git
cd kilde
swift build
.build/debug/kilde doctor   # Check and request permissions on first run
```

Optionally put the binary on your PATH so the examples below work as written:

```sh
ln -sf "$PWD/.build/debug/kilde" /usr/local/bin/kilde
```

The only package dependency is
[swift-argument-parser](https://github.com/apple/swift-argument-parser).

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
kilde devices      # List displays, windows, and audio devices
kilde inspect FILE # Show tracks and audio levels in a recording
kilde config show  # Show configured values and effective defaults
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

### Why is BlackHole not required?

kilde uses ScreenCaptureKit's native system-audio capture, so ordinary screen
and audio recording works without a virtual audio driver. BlackHole is only
needed for specialized routing, such as monitor mode, where you want to listen
to audio while recording it through another path.

## Recording options and defaults

By default, kilde captures display `0`, records `system` audio into a `mixed`
audio track, uses the H.264 video codec, and includes the cursor. If no output
path is supplied, it creates `kilde-yyyyMMdd-HHmmss.mov`, or an `.m4a` file in
audio-only mode. Run `kilde rec --help` for the complete option list.

Common options include:

- `--display NUMBER` or `--window MATCH` to select the capture target
- repeatable `--audio system|mic|device:NAME_OR_UID|none` to select audio sources
- `--audio-tracks mixed|separate` to mix sources or preserve separate tracks
- `--no-video`, `--monitor`, `--duration 30s` (counted from the end of a hotkey
  wait, not from launch), `--codec h264|hevc|prores`, and `--fps NUMBER`
- `--cursor` or `--no-cursor`, `--countdown SECONDS`, `--preset meeting`, and
  `--hotkey SHORTCUT`
- `-o PATH` or `--output PATH` as an alternative to the positional output path

## Configuration

Persistent `rec` defaults are stored in `~/.kilde/config.json`. Manage them
with `kilde config show|set|unset|path` rather than editing the file by hand.

```sh
kilde config set outputDirectory ~/Movies/kilde
kilde config set defaultAudioSources system,mic
kilde config set showsCursor false   # Use kilde rec --cursor to override it once
kilde config set hotkey cmd+shift+r  # Start rec in hotkey-waiting mode (see below)
kilde config show
kilde config unset hotkey
kilde config path
```

The supported keys are `outputDirectory`, `defaultAudioSources`, `audioTracks`,
`codec`, `fps`, `showsCursor`, and `hotkey`.

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
| `0` | Success, including a recording safely stopped by SIGINT, SIGTERM, or SIGHUP |
| `1` | Other runtime failure, including invalid configuration |
| `2` | Missing permission |
| `3` | Display, window, or audio device not found |
| `64` | Command-line parsing or option validation error, such as `rec --fps 0` |

## Development

- Official releases (Developer ID signing and notarization): [docs/RELEASE.md](docs/RELEASE.md)

- Build, permissions, testing, and troubleshooting:
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- Architecture and behavior: [docs/DESIGN.md](docs/DESIGN.md)
- M0 spike results: [docs/SPIKE-NOTES.md](docs/SPIKE-NOTES.md)
- Monetization strategy survey (Japanese): [docs/MONETIZATION.md](docs/MONETIZATION.md)
- Local integration tests with real recording: `scripts/integration-test.sh`
  (requires permissions and audible speaker output; takes about two minutes)

## GUI (M3 in progress)

The menu bar app skeleton uses `NSStatusItem` and `NSPopover`. It is managed
manually with AppKit because SwiftUI `MenuBarExtra` with a `.window` panel does
not open on macOS 26. The app shares the same `KildeCore` recording engine as
the CLI through a local package dependency. Generate the uncommitted Xcode
project from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

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

## Roadmap

- **M0** ✅ Technical spike: validated ScreenCaptureKit audio capture
- **M1** ✅ CLI MVP: `kilde rec / devices / doctor / audio monitor / inspect`
- **M2** Global hotkey ✅; region capture ✅; pause/resume
- **M3** Menu bar GUI app: skeleton ✅ / recording UI ✅ / permission
  onboarding ✅ / completion notifications, recent recordings, global hotkey,
  and launch at login ✅

## Contributing

Bug reports, feature requests, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) to get started.

## License

[MIT License](LICENSE)
