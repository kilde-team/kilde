# Product Hunt 文案 (issue #157)

投稿は最後に行う (README.md «投稿の順序とタイミング» — ギャラリー・初動体制を
整えてから)。起動は**火曜 00:01 PT 開始**が伝統 (米国の丸 1 日を取る)。
ハンティング (他アカウントに掲載してもらう) は自己ハントでよい —
最近の Product Hunt はメーカー自身の投稿が一般的。

**投稿前チェックリスト**:
- [ ] デモ動画 (kilde-team/kilde-site#1) がギャラリーに入っている (PH では実質必須)
- [ ] **スクショを実機キャプチャに差し替えた** — `docs/appstore/screenshots/` の
      6 枚は HTML/CSS で UI を再現した**モック** (docs/appstore/README.md §2)
- [ ] スクショを 16:9 (1270×760 以上) にクロップ/パディングした
- [ ] ギャラリー画像 1 枚目に«価値提案の一文»を焼き込んだカバーを作った
- [ ] タグライン・説明文の文字数を投稿画面で再確認 (上限は変わりうる)
- [ ] 投稿日の 0:01 PT から数時間はコメント返信に張り付く体制

## 基本情報

| 項目 | 内容 |
|---|---|
| Name | Kilde |
| Tagline (60 字上限) | `Record meetings with system audio. Transcribed on your Mac.` (59 字) |
| Link | https://kilde.site/ |
| Mac App Store ボタン | https://apps.apple.com/app/id6812783176 |
| Topics | Productivity / Artificial Intelligence / Mac |
| Price | Free |

タグライン候補 2: `The meeting recorder that keeps everything on your Mac.` (55 字)

## Description (260 字上限)

```text
kilde records your screen with system audio + mic in one track — the sound
most recorders miss. On macOS 26+ (Apple Intelligence Macs), meetings are
transcribed and summarized on-device. No bots in your calls. No cloud.
Free. App and docs are open source.
```
(255 字 — 話者ラベルは分離トラック時の機能なので説明文には書かず、
メーカーコメントとギャラリーで条件付きに記載)

## ギャラリー (順番が重要 — 1 枚目で価値を伝える)

スクショは `docs/appstore/screenshots/` のもの (16:9 への変換は投稿前チェックリスト参照)。

1. カバー: «Your meetings. Recorded and transcribed. On your Mac.» + アイコン
2. `01-meeting.png` — 会議録画の価値提案 (system audio + mic)
3. `02-transcribe.png` — オンデバイス文字起こし + 話者ラベル (分離トラック時)
4. `03-recording.png` — 録画パネル (レベルメーター)
5. `05-audio-only.png` — 音声のみ録音
6. `06-safe-finish.png` — Ctrl+C でも必ずファイナライズ
7. 動画 (60 秒デモ — kilde-site#1)

## 最初のコメント (メーカーコメント)

```markdown
Hi PH! I'm the maker of kilde 🎙️

Every meeting tool I tried either put a bot in the call, sent the audio to a
cloud, or — worse for meetings — only recorded my microphone, missing
everyone else. On a Mac, the other participants' voices are *system audio*,
and that's exactly what most recorders can't capture.

kilde records system audio + your mic together (native ScreenCaptureKit —
no virtual audio driver), from a menu bar app or a CLI. On macOS 26+, with
transcription enabled, it transcribes the recording on-device (speaker
labels when mic and system audio stay as separate tracks), summarizes it
locally on Apple Intelligence-capable Macs, and drops the markdown next to
your recording — ready for your Obsidian vault or wherever you keep notes.

What I'm proudest of: everything stays on your Mac. No meeting bot joins
your calls; recordings, transcripts, and summaries never leave your machine.
The CLI sends no analytics at all; the GUI sends aggregate usage stats
(bucketed durations — never content, filenames, or paths) and, if it ever
crashes, a crash report with a stack trace.

It's free: Mac App Store, Homebrew, or download from GitHub (MIT).
Apple Silicon, macOS 14+ (transcription needs macOS 26+).

Ask me anything — especially what you'd want in a meeting recorder. And
when you record meetings, make sure everyone's informed and consenting 🙂
```

## 初動 (0:01 PT〜)

- 1 時間ごとにコメントを確認し返信 (faq.md 使用)
- 投稿 URL を SNS/知人に共有するのは«起動当日»に集中させる (PH は当日の
  集中が順位に効く)
- 翌朝に metrics.md へ初回数値を記入する
