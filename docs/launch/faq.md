# 想定質問への回答 (issue #157)

Show HN / r/macapps / Product Hunt のコメント欄で想定される質問と回答案。
**回答は英語で書く** (コメントは英語圏) — 各回答の English ブロックをそのまま
貼ってよい。«見出し» は日本語の注記。

方針:
- **誇張しない**。数値実績・«世界初»・«最速» は書かない
- **将来を約束しない** (収益化・ライセンス方針は #168 で未決定)
- 批判には防御せず事実で返す。オープンにできる点 (公開リポジトリ、
  プライバシー文書) へのリンクを貼る

---

## 1. なぜエンジンが private なのか («open-source では?»)

一番来る質問。README にも書いてある通り**正直に**答える。防御しないこと。

> Two repos, on purpose: this one (menu bar app, release/signing pipeline,
> docs) is public under MIT. The recording engine and CLI source live in a
> separate private repo while we decide their long-term source policy — it's
> an open question on our roadmap, not a hidden plan. Everything shipped is
> signed and notarized, the CLI is free, and the privacy policy
> (https://kilde.site/privacy/) covers all distribution channels.

補足 (日本語注記): «ソース公開の方針を決めるまでは private» が事実
(#168 で決める。#115 の移行時点からの合意)。«not a hidden plan» は
事実に基づく — 方針決定 issue が公開リポジトリのロードマップに存在する。

## 2. 何を収集しているのか (アナリティクス)

> The CLI sends nothing — no analytics at all. The GUI apps (App Store and
> direct download) send two kinds of telemetry. Aggregate usage stats via
> Firebase Analytics: launches and usage frequency, app and OS versions,
> device type, coarse region (derived from IP), recording-completion counts,
> bucketed duration (never raw seconds), which channel you use, and
> transcription usage counts. Separately, crash reports (stack traces) via
> Crashlytics, sent after a crash. Never the recording content, filenames,
> paths, settings, or transcript text — recordings and transcripts never
> leave your Mac. Full list: https://kilde.site/privacy/

言われたときの追い質問 «Can I turn it off?»:

> There's no opt-out switch in the app today — honest answer. The GUI's
> telemetry is two kinds: aggregate usage stats (never content, filenames,
> or paths) and, when it crashes, a crash report with a stack trace. The
> other outbound connections — the update check (direct download only) and
> speech-model downloads from Apple — don't carry usage data; everything is
> listed in the privacy policy. The CLI, which sends no telemetry, covers
> scripted and automation use. If enough people want a toggle we'll
> consider it.

補足 (日本語注記): «オプトアウトは現状無し» が事実 (gui/Sources/UsageAnalytics.swift —
isEnabled は Firebase の設定有無のみ)。«consider it» は約束しない言い方。
要望が多いようならオプトアウト検討の issue を起票する。

## 3. 対応 OS は?

> macOS 14 or later. Transcription and summaries need macOS 26+ (they use
> Apple's on-device speech and foundation models). Runtime testing is done
> on macOS 26 on Apple Silicon.

## 4. Intel Mac は?

> Not right now — release binaries are arm64 (Apple Silicon) builds. We're
> a small team and Apple Silicon is where our users are; an Intel build is
> not off the table but we can't promise a date.

補足 (日本語注記): «date の約束なし» を崩さない。Intel ユーザーには CLI の
Homebrew 経路も現状 arm64 のため提供なし — 素直に «not right now»。

## 5. OBS / QuickTime / Audio Hijack と何が違う? (競合比較)

他社ツールは**貶めない**。機能の事実だけ (README.md «文面のルール»)。

> They're great tools with different centers of gravity. kilde is focused on
> meetings: native ScreenCaptureKit capture means system audio (everyone
> else in the call) records without a virtual audio driver; window capture
> can scope audio to that app; stopping the normal ways — the stop button,
> the hotkey, quitting the app, or Ctrl+C — always leaves a finalized file;
> and on macOS 26+ the recording can be transcribed on-device (speaker
> labels when mic and system audio are kept as separate tracks) and
> summarized locally on Apple Intelligence-capable Macs. If you need
> scenes, streaming, or deep audio routing, those tools do more; if you
> want the meeting on record with a transcript, kilde does less, faster.
> (And the usual reminder: record meetings only with everyone's informed
> consent, per your local laws.)

## 6. 録音をクラウドに送らない本当の根拠は? (信頼質問)

> Nothing to trust but the design: transcription runs on Apple's on-device
> speech stack; summaries run on-device foundation models; the only network
> calls are listed in the privacy policy (aggregate analytics, crash
> reports, the update check, and speech-model downloads from Apple). The
> CLI makes none of those calls except model downloads. Code that handles
> recordings writes to files you choose — there's no upload path.

## 7. Windows / Linux は?

> No plans to announce — kilde is built on macOS frameworks
> (ScreenCaptureKit, Speech, Foundation Models) that don't exist elsewhere.
> Feature requests welcome, but we'd rather do one platform well.

## 8. 名前の意味は? (小ネタ。柔らかい質問には答える)

> *kilde* is Danish/Norwegian for "source" — a spring where water rises,
> and the source of information. Meetings and screens create more and more
> knowledge; the recordings are sources worth keeping. That's also why
> stopping a recording the normal ways — Ctrl+C included — always leaves a
> finalized file: a source you can't open again is no source at all.

## 9. 有料化の予定は?

> It's free today, both from the Mac App Store and as a direct download,
> and the CLI is free too. Longer-term monetization is an open question on
> our roadmap — nothing to announce, and we'll be upfront when that
> changes.

補足 (日本語注記): «永久無料» とは言わない (MONETIZATION.md / #168 の方針次第)。
«be upfront» (変えるときは正面から告知する) で誠実さを見せる。

## 10. 文字起こしの精度は? (日本語は?)

> It uses the speech recognition built into macOS (on-device, via the
> Speech framework), so quality follows your macOS version and locale —
> macOS 26 required. Try it with `kilde transcribe FILE` on an existing
> recording and tell us how it does in your language; reports (good and
> bad) genuinely shape what we fix next.

補足 (日本語注記): 精度の数値約束はしない。«試して報告を» が最良の CTA。
