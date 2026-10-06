---
title: "Meeting minutes without the cloud: how I stopped dreading “can you take the minutes?”"
published: false
description: "The AI minutes services I looked at all meant a bot joining the call or audio leaving for the cloud. Here's the local-only alternative I ended up building and using on macOS."
tags: privacy, productivity, macos, meetings
---

**この原稿について** (リポジトリ内の注記です。転載するときは削除してください):
issue #312 で追加した note 公開済み記事 3 の英語版 (海外読者向けに調整) です。
公開先は dev.to を第一候補とするが、Medium / kilde.site blog も候補
(dev.to で載せる場合、note は検索エンジンにインデックスされるため
`canonical_url` に note 版の URL を設定するか、実質的な改稿として
canonical 無しで出すかを公開時に判断)。誇張表現は #157 の英文文案
(show-hn.md «最初のコメント») と語彙を合わせてあるので、修正時はそちらも参照。

---

"Can you take the minutes today?" — I was genuinely bad at this.

There are plenty of AI services that write meeting minutes for you now. But
the ones I looked at all came with one of two assumptions: **a bot joins the
meeting**, or **your audio gets uploaded to the cloud**. They made me
hesitate in exactly the meetings that matter:

- A call where a client's personal data or unpublished numbers will come up —
  I don't want to invite an outside service's bot
- Explaining "is it OK if we record this?" every single time is exhausting
- Some meeting tools don't support bots at all, or are configured to reject
  them

So I'd fall back to "no recording, take notes by hand, reconstruct the minutes
afterwards from my notes and memory." That eats time and energy, every week.

## The local-only option

This is why I built [kilde](https://kilde.site/): a free macOS tool that
records your screen and audio, where **the recording, and — if you turn them
on — the transcription and summary all complete on your Mac** (transcription
needs macOS 26 or later; summaries need an Apple Intelligence-capable Mac).
No bot joins the call, and recordings and transcripts never leave your Mac.

Using it changes nothing about how you run the meeting. One thing first,
though, and it matters: **before recording, tell participants and get their
consent**. Not having a bot in the call doesn't remove that step
(kilde ships a one-click copyable notice to help you say it).

1. Install kilde from the Mac App Store (free); it lives in your menu bar
2. On first recording, grant Screen Recording and Microphone permission
   (the app walks you through it)
3. When the meeting starts, pick the meeting's window from the menu bar icon
   and start recording
4. Stop when it ends. **Both sides of the conversation — their voices (system
   audio) and yours (microphone) — are in one file**
5. With «transcribe after recording» enabled, transcription starts the moment
   you stop

If you live in the terminal, Homebrew installs a `kilde` CLI that does the
same: `kilde doctor` (permission guidance) →
`kilde rec --preset meeting meeting.mov`.

Transcription runs on macOS's built-in speech recognition, **entirely on your
Mac** (macOS 26+). You get timestamped minutes you can export as Markdown,
SRT, WebVTT, TXT, or JSON.

## Clean audio, because the speakers can be separated

What makes kilde usable for meetings is that it records **both** sides —
the other participants (the audio your Mac plays) and you (microphone) — and,
if you want, **keeps them on separate tracks**.

With separate tracks, transcription runs per track, so "what they said" and
"what I said" don't blur together in the minutes. When you read them back,
being able to check only "what I committed to" is quietly useful.

One more detail that matters: if you scope the recording to the meeting's
single window, **the audio is scoped to that app too**, so message
notification sounds don't end up in your minutes. Notifications can pop during
the recording; the transcript stays clean.

## "Is it really not being uploaded?"

Since that's the whole point, here's the honest answer.

- Recordings, transcripts, and summaries are written to your local disk.
  There is no kilde server
- The menu bar app sends aggregate usage statistics via Firebase Analytics to
  improve the app: launches and usage frequency, app and OS versions, device
  type, coarse region derived from your IP address, recording-completion
  counts, bucketed durations («under 1 min / 1–5 min / …», never raw seconds),
  which distribution channel you use, and transcription usage counts. The
  developer sees aggregated numbers only — never recording content,
  filenames, or settings like your save destination
- If the app crashes, Firebase Crashlytics sends an individual crash report on
  next launch: the stack trace (where it crashed), app and OS versions, device
  type and state (free memory and disk space), the time of the crash, and a
  random per-install ID. Crash reports are kept separate from the usage
  statistics above and do not include recording content, filenames, or settings
- The direct-download build checks for updates through Sparkle, which fetches
  update information from GitHub; that request exposes your IP address and app
  version to GitHub. The Mac App Store build updates through the App Store
- If the transcription language model isn't on the device yet, both the app
  and the CLI download it from Apple. That request exposes your IP address to
  Apple; no audio or transcript is sent
- The CLI (`kilde`) uses neither Firebase Analytics/Crashlytics nor Sparkle.
  Apart from the model download above, it makes no network calls
- All of this is written out concretely in the
  [privacy policy](https://kilde.site/privacy/) — you can read it before
  installing

If "nothing leaves your Mac" is the selling point, this part of the story has
to have no escapes in it. That's why it's written down to the point of tedium.

## Who it's for

- People who need minutes for **meetings where a bot can't be invited** —
  client calls, candidate interviews
- People whose company won't approve sending meeting audio to an external
  service
- People who want to full-text-search what was said, later
- Conversely, if cloud sync and team sharing are your main goal, other
  services fit better. kilde is deliberately a "complete on your Mac" tool

kilde is free, from the [website](https://kilde.site/) or the
[Mac App Store](https://apps.apple.com/app/id6812783176) (the menu bar app and
the docs are open source, MIT). It runs on Apple Silicon Macs on macOS 14 or
later; transcription requires macOS 26 or later.

Stop dreading "can you take the minutes?", and the hour before a meeting gets
a little lighter.
