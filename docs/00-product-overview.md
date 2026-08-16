# Vocal — Product Overview

> Working codename: **Vocal** (repo: `vocal2text`). Final name TBD — see interview questions.

## 1. What we are building

Vocal is a personal, fully-offline voice-to-text dictation system, functionally equivalent to
[Wispr Flow](https://wisprflow.ai), for one user, on two devices:

1. **macOS app** (primary) — a menu-bar utility. Hold a hotkey anywhere in the OS, speak,
   release, and polished text is typed into whatever app has focus: editor, browser, terminal,
   chat, email.
2. **iOS app** (companion) — dictation on iPhone with the best cross-app text delivery that
   iOS allows, plus shared transcript history.

Everything — speech recognition, AI cleanup, history — runs **on-device by default**. The only
network-optional feature is AI cleanup via a user-configured provider (Ollama on the Mac, or
any OpenAI-compatible endpoint), which is **off by default**.

## 2. Why (goals)

- **Speed**: dictating is 3–4× faster than typing. The loop "hold key → speak → release →
  text appears" must feel instant (< ~1.5 s from release to text for typical utterances).
- **Privacy**: audio and transcripts never leave the devices unless the user explicitly
  configures a remote cleanup provider.
- **Offline**: works on a plane, works with Wi-Fi off, works forever regardless of any
  vendor's pricing or shutdown.
- **Ownership**: personal tool, personal data, inspectable code, no subscription.

## 3. Scope

### v1 languages

| Language | Status |
|---|---|
| English | ✅ v1 |
| Mandarin Chinese (Simplified output; Traditional via optional conversion toggle, per interview B5) | ✅ v1 |
| Burmese (Myanmar) | ⏸ **Deferred** — explicitly out of v1 scope per user decision (2026-08-16). The language layer must remain pluggable so it can be added later. Research findings preserved in `docs/04-asr-engines-and-languages.md` appendix. |

### v1 feature set (from user requirements)

| # | Feature | One-liner |
|---|---|---|
| F1 | On-device transcription | Local ASR models, no cloud, EN + ZH |
| F2 | Push-to-talk hotkey | Global hold-to-record hotkey on macOS, everywhere in the OS |
| F3 | Text delivery across apps | Transcribed text lands in the focused app/field automatically |
| F4 | Transcript history | Searchable local history of every dictation (text + optional audio) |
| F5 | Audio file import | Drop in m4a/mp3/wav/etc. and get a transcript |
| F6 | Works offline | Zero network dependency for core flow |
| F7 | Optional AI cleanup | Filler-word removal, grammar/punctuation fix, spoken self-corrections ("Friday, sorry Saturday" → "Saturday"). Local model / Ollama / OpenAI-compatible provider. **Off by default.** |
| F8 | Automatic profile switching | Per-app (and per-website-hostname) AI prompt profiles, detected locally from the focused app |
| F9 | Custom dictionary | Case-insensitive word-for-word overrides applied to every transcription |
| F10 | Custom style prompt | User-authored prompt shaping all enhanced output (tone, spelling variant, formatting) |

### Explicit non-goals (v1)

- Multi-user features, accounts, licensing, telemetry, analytics — none.
- Windows/Linux/Android.
- Real-time meeting transcription / speaker diarization (import of long files is in scope; live
  meeting capture is not).
- Voice commands / "command mode" (Wispr Flow has one; we defer it — see roadmap "later").
- App Store distribution. This is a personally signed, personally installed tool.

## 4. Product principles

1. **The hotkey loop is sacred.** Every design decision is subordinate to: hold → speak →
   release → correct text in the right place, fast. Anything that adds latency or failure
   modes to that loop must justify itself.
2. **Raw transcript is never lost.** AI cleanup, dictionary overrides, and profiles transform a
   copy. History stores the raw ASR output alongside the delivered text, so trust in the tool
   never depends on trust in the LLM.
3. **Degrade gracefully.** If the LLM provider is down/slow → deliver the stage-2 text
   (normalized + dictionary applied — overrides apply to *every* transcription, even
   fallbacks). If paste insertion isn't possible → fall back to Unicode-typing; if that
   fails → clipboard + notification. The user should never lose spoken words.
4. **Local first, pluggable always.** ASR engines, cleanup providers, and languages sit behind
   protocol interfaces. Today's best model is next year's fallback; nothing is hard-wired.
5. **Clean code, boring architecture.** Small modules, explicit data flow, tests on the pure
   pipeline. This repo should be maintainable by its owner (plus AI agents) for years.

## 5. Reference products

- **Wispr Flow** (wisprflow.ai) — primary UX reference. We replicate its *behavior* (feature
  set, interaction design) with an original offline implementation. We do not copy its code,
  branding, or marketing content.
- **WhisperStream** (whisperstream.io) — secondary reference for Windows-style UX ideas.
- **Open-source references** (studied for engineering approaches; license noted before any
  code reuse): VoiceInk (macOS, GPL — study only), Handy (cross-platform, MIT/open),
  WhisperKit examples (MIT), whisper.cpp examples (MIT).

## 6. Document map

| Doc | Contents |
|---|---|
| `docs/00-product-overview.md` | This file — vision, scope, principles |
| `docs/01-prd-macos.md` | Full PRD: macOS app |
| `docs/02-prd-ios.md` | Full PRD: iOS app |
| `docs/03-architecture.md` | Technical architecture, shared core, data model |
| `docs/04-asr-engines-and-languages.md` | ASR engine research & selection; language strategy; Burmese appendix |
| `docs/05-ai-cleanup-and-profiles.md` | Cleanup pipeline, profiles, dictionary, style prompts — detailed spec |
| `docs/06-roadmap.md` | Milestones with acceptance criteria and verification steps |
| `docs/07-risks.md` | Risk register with mitigations |
| `docs/08-interview-questions.md` | Open questions for the product owner |
| `docs/09-reference-codebases.md` | Engineering learnings from SpeakType (MIT), VoiceInk (GPL, study-only), Handy (MIT) |
