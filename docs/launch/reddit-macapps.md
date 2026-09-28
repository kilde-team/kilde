# r/macapps 投稿文案 (issue #157)

r/macapps (https://www.reddit.com/r/macapps/) 向け。雰囲気は Show HN より
くだけて、スクショと«何が便利か»を前段に置く。

**投稿前の注意**:
- 開発者投稿は**約 30 日に 1 度**の制限がある (2026-09 調査時点の認識)。
  **投稿直前にサイドバー/About で最新のルールを確認**し、必要なら
  モデレーターに確認する。開発者投稿のラベル/フレアがあれば付ける
- アカウントは投稿前に一般的な参加実績を作っておく (90/10 ルール)
- 1 発しかない投稿なので、Show HN で出た質問への回答を faq.md に
  蓄積してから投稿する

タイミング: 平日 (米国の朝〜昼に見られることが多い)。Show HN の反応を見て、
質疑で補強された点を本文に反映してから投稿する。

## タイトル候補

1. `Kilde – free, open-source macOS recorder for meetings: system audio + your mic, transcribed on-device`
2. `I built a menu bar app that records online meetings with the other people's audio (system audio) and transcribes it locally`

## 本文

```markdown
Hey r/macapps! I built **kilde**, a free and open-source screen/audio
recorder for macOS. It fixes the thing that always bugged me about recording
online meetings: **the other participants' voices come through system audio,
which QuickTime's screen recording doesn't capture** — so you end up with only
your own side of the conversation.

kilde records system audio + your mic (mixed into one track, or kept separate)
from a menu bar app, and — on macOS 26+ — transcribes everything **entirely
on your Mac**, with speaker labels (you vs. the other side), into markdown,
SRT, VTT, TXT, or JSON next to the recording. It also summarizes the
transcript on-device and can export it to a notes folder like your Obsidian
vault.

**What it does:**

- 🖥️ Record the screen, a single window, or audio only — native
  ScreenCaptureKit capture, **no BlackHole / virtual audio driver needed**
- 🎙️ Window capture can scope the audio to that app only, so notification
  pings don't end up in your recording
- 🛡️ Stop it any way you like (even force-quit-level Ctrl+C) and the file is
  always finalized and playable
- 📝 On-device transcription with speaker labels + summaries (macOS 26+,
  no audio or text ever leaves your Mac)
- ⌨️ Global hotkey, Shortcuts app support, notification + recent recordings
- It also detects when a meeting app starts using the mic and offers to
  start recording (opt-in, off by default)

**Free** — Mac App Store: https://apps.apple.com/app/id6812783176
Homebrew: `brew tap kilde-team/kilde && brew install kilde-team/kilde/kilde`
GitHub (MIT, details + docs): https://github.com/kilde-team/kilde

Requirements: Apple Silicon Mac, macOS 14+ (transcription needs macOS 26+).
CLI sends no analytics; the GUI sends aggregate usage stats only — no
recording content, filenames, or paths (privacy policy:
https://kilde.site/privacy/).

Would love your feedback — especially on transcription quality in your
language, and anything that feels missing. (And the usual reminder: when
recording meetings, make sure everyone's informed and consenting per your
local laws.)
```

## コメント返信の方針

- 質問には [faq.md](faq.md) の回答で誠実に。«エンジンが private» は必ず聞かれる
  ので、削除される前に答えておく (最初の自分コメントに先回りで書くのも可)
- 機能要望は«良い点、取り上げる»とだけ返す (約束しない)。採用したら後日
  同スレッドに追記する
