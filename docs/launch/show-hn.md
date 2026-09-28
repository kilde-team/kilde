# Show HN 文案 (issue #157)

リンク先は **GitHub リポジトリ** (https://github.com/kilde-team/kilde)。
Show HN は«動いて試せるもの»を見せる場 — リポジトリの README・ダウンロード・
App Store ですぐ試せる状態にしてから投稿する。デモ動画
(kilde-team/kilde-site#1) が揃っていれば最初のコメントに貼る。

タイミング: 火〜木の米東岸朝 7〜10 時 (README.md «投稿の順序とタイミング»)。
投稿後 **丸 1 日はコメントに付きっきり** で返信する (faq.md の回答をそのまま使う)。

## タイトル候補 (1 行。80 文字前後に収める)

1. `Show HN: Kilde – record system audio on macOS and transcribe it on-device`
2. `Show HN: Kilde – macOS recorder that captures system audio`
3. `Show HN: Kilde – menu-bar recorder for meetings with on-device transcription`

1 番を第一候補とする («system audio» が機能の核心で、«on-device» が
プライバシー訴求の核)。2 番は文字起こしに魅力を感じない層向け。

## 本文 (リンク投稿のため不要 — 最初のコメントに注力する)

## 最初のコメント (投稿者自身がすぐ書く)

```markdown
Hi HN! I built kilde, a screen and audio recorder for macOS that
can capture **system audio** — the sound your Mac plays, which QuickTime
Player's screen recorder cannot record — together with your microphone,
and transcribe it entirely on your Mac.

The use case it started from: recording online meetings. The other
participants' voices come through system audio, so most recorders only get
your side of the conversation. kilde mixes both into one track (or keeps them
separate for speaker-labeled transcripts).

It comes in two shapes:

- A menu bar app: pick screen/window/audio-only, sources, and destination;
  with transcription enabled (macOS 26+), recordings are transcribed
  on-device into markdown/SRT/VTT/TXT/JSON — speaker labels when mic and
  system audio stay as separate tracks — and summarized locally on Apple
  Intelligence-capable Macs, or exported to a notes folder like your
  Obsidian vault
- A CLI (`kilde rec` / `kilde transcribe`) for scripts and automation.
  A few things we sweated: Ctrl+C always leaves a finalized, playable file;
  window capture can scope system audio to that app only; no virtual audio
  driver needed (native ScreenCaptureKit capture)

Everything runs locally — no meeting bot joins your call, recordings and
transcripts never leave your Mac, and the CLI sends no analytics at all.
The GUI sends aggregate usage stats (bucketed durations, never content,
filenames, or paths) and, if it crashes, a crash report with a stack trace —
details: https://kilde.site/privacy/

Honest caveats: Apple Silicon only for now, and the recording engine lives in
a separate private repo while we decide its long-term source policy — the app,
distribution, and docs in this repo are MIT.

Free download: Mac App Store (https://apps.apple.com/app/id6812783176),
Homebrew (`brew tap kilde-team/kilde && brew install kilde-team/kilde/kilde`),
or the release zip. We'd love feedback on the transcription quality in your
language, and what you'd want next.

When recording meetings, make sure participants are informed and consent
according to your local laws.
```

## 返信で使う想定質問

[faq.md](faq.md) をそのまま使う。特に来やすいもの:
«Why is the engine private?» / «What analytics do you collect?» /
«Windows or Linux version?» / «How is this different from OBS?»。
OBS などとの比較は«機能の事実»の範囲で (他社ツールの貶めない。README.md
«文面のルール»)。
