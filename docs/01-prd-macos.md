# PRD — Vocal for macOS

Owner: Joseph · Status: Draft for review · Platforms: macOS (Apple Silicon)
Implementation notes live in `docs/03-architecture.md`; engine facts in `docs/04`.

## 1. Summary

A menu-bar dictation utility. Hold a global hotkey in any app, speak English or Chinese,
release; the transcript — optionally cleaned by a local AI with a per-app profile — is
inserted at the cursor of the focused app. Fully offline. Searchable history. Audio import.

## 2. User stories

- **US-1**: As Joseph writing an email (having turned AI cleanup on), I hold the hotkey,
  speak two sentences with a few "um"s and one self-correction, release, and see polished
  prose appear in Gmail within ~2–3 s (≤1.5 s when cleanup is off).
- **US-2**: As Joseph in the terminal, I dictate a shell one-liner and get *verbatim* text —
  no auto-punctuation, no capitalization surprises (Terminal profile has cleanup off).
- **US-3**: As Joseph chatting in WeChat, I dictate Chinese; output uses 。，？full-width
  punctuation, keeps the English product names I said mid-sentence, and matches my casual tone.
- **US-4**: As Joseph, I say "Claude" and it types "Claude", not "cloud" — because I added a
  dictionary entry once.
- **US-5**: As Joseph, I need that thing I dictated last Tuesday; I open History, search a
  keyword (English or 中文), and copy it.
- **US-6**: As Joseph with a voice memo from my phone, I drop the .m4a onto the app and get a
  transcript I can copy or save.
- **US-7**: As Joseph on a plane with Wi-Fi off, every one of the above works identically.

## 3. Functional requirements

IDs are stable; acceptance criteria in §6 reference them.

### FR-1 Push-to-talk capture
- FR-1.1 Global hotkey works regardless of focused app, including full-screen apps.
- FR-1.2 **Hold-to-talk**: press starts capture (< 100 ms perceived; pre-armed audio engine),
  release stops it and triggers transcription of the whole utterance.
- FR-1.3 **Lock mode**: double-tap the hotkey to keep recording hands-free; single tap ends.
  Hard cap: lock-mode recording auto-stops with a notification at a configurable limit
  (default 15 min) — a stuck session must never record until the disk fills. A low-disk
  guard (<1 GB free) stops any recording mode.
- FR-1.4 Hotkey is configurable. **Default: hold-Fn/Globe** (Wispr Flow muscle memory;
  research-confirmed viable via CGEventTap — requires onboarding step setting "Press 🌐
  key to: Do Nothing", see docs/03 §3.1). **First-class fallback: Right-⌘ hold** (no system
  conflict, works on all keyboards incl. third-party externals whose firmware swallows Fn).
  Also offered: Right-⌥, Right-⌃ holds. Keyed chords (⌥Space) supported but discouraged
  (they die under secure-input sessions; modifier-only hotkeys survive). Interview C8 can
  override the default.
- FR-1.5 A press shorter than 500 ms is discarded silently (accidental tap) **unless** the
  VAD detected speech during it, in which case it is transcribed normally. (Same rule and
  threshold in docs/03 §3.1.)
- FR-1.6 Escape (or configurable key) during capture cancels — nothing is inserted and
  nothing is transcribed; the audio lands in History marked "cancelled" for 24 h, where a
  "Recover" action transcribes it on demand; then it auto-deletes. If the audio-retention
  setting is "never", cancelled audio is discarded immediately (no recovery window).
- FR-1.7 Maximum utterance length ≥ 5 minutes without degradation (chunked internally).

### FR-2 On-device transcription (EN/ZH)
- FR-2.1 All ASR runs locally; the process makes **no network calls** during the dictation
  path (enforced in code review + a network-free integration test).
- FR-2.2 Languages: English and Mandarin Chinese, including intra-sentence code-switching.
- FR-2.3 Language handling: automatic detection per utterance by default; a per-profile or
  manual override (menu-bar toggle EN/中/auto) for when detection misfires.
- FR-2.4 Model management UI: list available models with size/status, download over resumable
  HTTPS, verify checksum, delete; app ships with a functional small model or guided first-run
  download (decision in docs/04).
- FR-2.5 Latency target (M-series, large-v3-turbo-class model): ≤ 1.5 s from key-release to
  inserted text for a 10 s utterance with cleanup off; ≤ 3 s with local cleanup on. Measured
  and displayed in a debug overlay.

### FR-3 Text delivery
- FR-3.1 On completion, text is inserted at the cursor of the frontmost app's focused text
  element. Insertion strategy is tiered — **paste-primary** (pasteboard+⌘V with full
  snapshot/restore, transient+concealed pasteboard marking) → CGEvent Unicode-typing
  fallback (terminals / clipboard-free mode) → clipboard + user notification; AX direct
  insertion is deliberately *not* primary (Electron breakage; see docs/03 §3.2 and
  docs/09). The requirement is: **works in** native apps, Electron apps (Slack, VS Code),
  browsers (Safari/Chrome/Arc), terminals, and Java IDEs.
- FR-3.2 If secure input is active at delivery time (password field), **never insert and
  never persist** — no transcript text, no audio, no history row beyond an anonymous
  "blocked: secure field" event; show a discreet HUD notice naming the responsible app when
  identifiable. (A secure-field dictation is very likely a password; storing it in plaintext
  history would be a privacy leak.)
- FR-3.3 Smart spacing/capitalization relative to surrounding text (stage-4 formatter,
  docs/05 §6) — consecutive dictations compose into flowing prose.
- FR-3.4 If no text field has focus, fall back to clipboard + notification "Copied — ⌘V to
  paste".
- FR-3.5 The clipboard is restored to its prior contents after paste-insertion (including
  images/rich content) within 300 ms; a setting can disable clipboard use entirely
  (**typing-only mode** — CGEvent Unicode typing, docs/03 §3.2 tier 2).
- FR-3.6 Timing anchors: the profile is resolved at hotkey **press** and stays pinned; the
  secure-input check runs at **delivery** time; text is delivered to the app frontmost at
  delivery. If the frontmost app changed between press and delivery, hold-to-talk still
  delivers (the window is ~1–3 s and the switch was user-initiated), but **lock mode** falls
  back to clipboard + notification instead of pasting into an app the user wandered into.

### FR-4 Recording HUD
- FR-4.1 While capturing: a small floating HUD (bottom-center, above full-screen apps) shows
  a live waveform + elapsed time + active profile name + language mode + **streaming
  partial-transcript preview** (preview only — committed text always comes from the
  full-utterance pass, docs/09 chunk-stitching lesson).
- FR-4.2 While transcribing/cleaning: HUD shows progress state; result flashes briefly on
  insert. Total HUD footprint ≤ ~360×80 pt, never steals focus, click-through except its
  cancel button.
- FR-4.3 Menu-bar icon reflects state (idle / listening / processing / error) — visible even
  when HUD is disabled by setting.
- FR-4.4 Optional sounds: subtle start/stop ticks (default on, respect output device).

### FR-5 Transcript history
- FR-5.1 Every dictation is stored locally: timestamp, raw ASR text, delivered text, profile,
  language, duration, target app (bundle ID + name), cleanup metadata, timings, and audio
  (per retention setting).
- FR-5.2 History window: reverse-chronological list, full-text search working for English and
  Chinese, filter by app/profile/date, per-item actions (copy raw / copy delivered / re-run
  cleanup with a different profile / play audio / delete).
- FR-5.3 Retention settings: keep text {forever | N days}; keep audio {never | 24 h | 7 d |
  30 d | forever}. Defaults: text forever, audio 30 days.
- FR-5.4 Export: select items → Markdown/JSON/plain text file. Full-database export as JSON.
- FR-5.5 "Delete all history" with confirmation; secure-delete audio files.

### FR-6 Audio file import
- FR-6.1 Import via drag-onto-menu-bar-icon, drag-into-History-window, Finder "Open With",
  and an in-app picker. Formats: wav, m4a/aac, mp3, opus/ogg, flac, aiff, and video
  containers' audio tracks (mp4/mov).
- FR-6.2 Long files (≥ 10 min, up to ≥ 3 h) transcribe with progress UI, chunked with
  VAD-aware segmentation, producing timestamped paragraphs; cancellable.
- FR-6.3 Imported transcripts land in History flagged "imported", with source filename; AI
  cleanup optionally applied per current profile choice in the import dialog (default: off
  for imports).
- FR-6.4 Import never blocks live dictation (separate queue/priority).

### FR-7 AI cleanup (spec: docs/05)
- FR-7.1 A global cleanup master switch ships **OFF** and gates stage 3 entirely; when ON,
  per-profile `cleanupEnabled` decides (precedence spec: docs/05 §0).
- FR-7.2 Providers (both platforms unless noted): **Apple Foundation Models** (zero-install
  default local provider on OS 26 Apple-Intelligence hardware), **downloadable MLX local
  model** (the requirement's "downloadable Local model"; quality upgrade), **Ollama**
  auto-detect (macOS), **OpenAI-compatible** custom endpoint. Provider status (reachable?
  model loaded?) visible in Settings. Same roster in docs/04 §4 and docs/05 §3.2.
- FR-7.3 Failure of the cleanup stage never loses the dictation: deliver stage-2 text and log.
- FR-7.4 Remote providers display a persistent "cloud" badge on the HUD while active
  (privacy honesty).

### FR-8 Profiles & auto-switching (spec: docs/05 §4)
- FR-8.1 Ship the 5 built-in profiles; full CRUD on profiles incl. custom prompt text,
  routes (app picker listing installed apps; hostname text entry), provider override.
- FR-8.2 Automatic selection on hotkey press: app bundle ID → browser hostname when the app
  is a supported browser (Safari + Chromium family: Chrome, Arc, Edge, Brave, Vivaldi,
  Opera) and Automation permission granted. Firefox has no scriptable tab-URL interface —
  it degrades to app-level routing (documented limitation).
- FR-8.3 Manual override: hold hotkey + press number keys 1-9? No — v1: menu-bar dropdown
  pins a profile ("Pin profile for next dictation / until unpinned").
- FR-8.4 Hostname is reduced from the tab URL in memory, used only for route matching, never
  written to disk (log stores the matched profile name only).

### FR-9 Custom dictionary (spec: docs/05 §2)
- FR-9.1 Dictionary tab: CRUD, search, import/export CSV, per-entry enable, usage counts.
- FR-9.2 Applied to every transcription (cleanup on or off), case-insensitive, longest-match
  first, no cascading.
- FR-9.3 "Add from history": select a wrong word in a history item → "correct this…" flow
  pre-fills spoken/written forms.

### FR-10 Custom style prompt (spec: docs/05 §5)
- FR-10.1 Single global style prompt in Settings, applied to all cleanup-enabled profiles
  unless a profile opts out.

### FR-11 Settings, onboarding, app lifecycle
- FR-11.1 First-run onboarding: welcome → mic permission → Accessibility permission (with
  live "granted ✓" detection; Input Monitoring is never separately requested) → Fn "Press
  🌐 key to: Do Nothing" check with Settings deep link (if Fn chosen) → model download →
  hotkey choice → test dictation playground ("say this sentence…").
- FR-11.2 Settings panes: General (hotkey, launch at login, sounds, HUD), Models, Cleanup
  (providers), Profiles, Dictionary, History & privacy, Advanced (timings overlay, logs).
- FR-11.3 Launch at login (SMAppService), single-instance guard, Sparkle-style update **not**
  required (git-based personal updates), crash-safe: an in-flight utterance's audio survives
  app crash (written to disk during capture) and offers recovery on next launch.
- FR-11.4 Diagnostics: structured local log (os_log + exportable file), per-stage timing
  overlay toggle.

## 4. Non-functional requirements

- **NFR-1 Privacy**: no telemetry, no network in core path (verified by test), remote cleanup
  clearly badged and off by default. Mic indicator honesty: capture only between press and
  release/stop — the orange mic dot must never appear at idle. Logging: structured os_log
  only; transcript content never appears at the default log level (debug capture is an
  explicit, temporary toggle).
- **NFR-2 Performance**: idle footprint ≤ ~150 MB RAM with model unloaded, ≤ 1% CPU idle;
  model kept warm in RAM is a setting (default: warm; "unload after N min" option). Latency
  per FR-2.5.
- **NFR-3 Reliability**: 100 consecutive dictations without restart in soak test; no audio
  device wedging after sleep/wake, AirPods connect/disconnect, display changes.
- **NFR-4 Compatibility**: macOS 26+ (assumption A2), Apple Silicon only.
- **NFR-5 Accessibility of the app itself**: HUD respects Reduce Motion; settings fully
  keyboard-navigable; VoiceOver labels on all controls.
- **NFR-6 Code quality**: shared `DictationCore` package with the full text pipeline pure and
  unit-tested; CI green (build + tests + SwiftLint/swift-format) required to merge.

## 5. Permissions (macOS)

| Permission | Why | When asked |
|---|---|---|
| Microphone | capture | onboarding |
| Accessibility | hotkey event tap + ⌘V/typing synthesis (also implies Input Monitoring) | onboarding |
| Input Monitoring | **not requested** — covered by Accessibility (docs/03 §3.1) | — |
| Automation (per browser) | tab hostname for website profiles | first time a website route is created (optional feature, degradable) |

## 6. Acceptance criteria (v1 exit)

Each is demonstrated by a recorded checklist run (see roadmap M5 gate):

1. **AC-1 (FR-1, FR-3)**: In each of TextEdit, Safari (Gmail compose), Slack, VS Code,
   iTerm2/Terminal, Notes, IntelliJ IDEA CE: hold-key dictation inserts correct text at
   cursor. 7/7 apps.
2. **AC-2 (FR-2)**: 20-utterance EN set and 20-utterance ZH set (fixtures) transcribe with
   ≤ 5% WER (EN) / ≤ 8% CER (ZH) on the chosen model, measured by scripts/eval-asr.
3. **AC-3 (FR-2.5)**: p50 release→insert ≤ 1.5 s, p95 ≤ 2.5 s over 50 timed 10-s dictations
   (cleanup off), from the timings log.
4. **AC-4 (FR-7)**: The 60-case cleanup eval passes ≥ 90% hard-rule checks with the default
   local provider; "Friday, sorry Saturday" and 「周五，啊不对，周六」cases pass **through
   the full pipeline including the output validator** (they are validator test fixtures).
5. **AC-5 (FR-8)**: Focusing Slack then dictating uses Messages profile; Gmail tab in Chrome
   uses Email profile; iTerm2 gets verbatim mode; menu-bar "pin profile" override works.
   Shown via history log entries (profile name + route type — no hostname stored).
6. **AC-6 (FR-9)**: A dictionary entry corrects a repeated ASR error in live dictation and
   in file import; case-insensitivity demonstrated.
7. **AC-7 (FR-5)**: Chinese and English keyword searches each find a known history item;
   export produces valid files.
8. **AC-8 (FR-6)**: A 60-min m4a podcast transcribes to timestamped paragraphs without
   hallucinated repetition loops; progress and cancel work.
9. **AC-9 (NFR-1)**: Little Snitch (or equivalent) session recording shows zero outbound
   connections during 20 dictations with local cleanup.
10. **AC-10 (FR-1.6, FR-3.2, FR-3.6, NFR-3)**: cancel works; secure-field guard blocks
    insertion *and* persistence; lock-mode focus-change falls back to clipboard; sleep/wake +
    AirPods swap soak passes.
11. **AC-11 (FR-10)**: With a global style prompt set ("British spelling; never use the word
    'utilize'"), cleanup-enabled dictations in two different profiles demonstrably follow
    it, and a profile with "ignore global style" does not.

## 7. Out of scope (v1) — tracked for later

Command mode ("select last sentence, make it shorter"), Whisper-style whisper-detection,
context awareness from screen content, per-app language pinning, voice activity auto-stop in
lock mode (the v1 lock-mode cap is time-based, FR-1.3), iCloud sync (M8+), Burmese
(deferred), sherpa-onnx decode-time hotword boosting (note: the WhisperKit prompt-biasing
experiment and Apple contextualStrings *are* v1 — docs/04 §3), streaming partial-text
*insertion* (type-as-you-speak; the HUD *preview* is v1 per FR-4.1).
