# Roadmap — Milestones & Acceptance Gates

Rules of the road:

- Every milestone ends with a **gate**: listed evidence produced and committed (benchmark
  files, screen recordings, checklist runs). "Done" is only claimed with the evidence
  linked — no evidence, not done.
- Milestones are sequential where they build on each other, but M6 (iOS) can start after M3.
- Each OS-release checkpoint (macOS/iOS 27, ~Sept 2026) triggers a re-verify pass of the
  **[verify]**-tagged assumptions in docs/03 and docs/04.

## M0 — Spike week: kill the unknowns (≈1 week)

Purpose: convert every load-bearing **[verify]** into measured fact on the actual hardware
before we build on it.

| # | Spike | Evidence |
|---|---|---|
| 0.1 | WhisperKit large-v3-turbo on the Mac: latency for 10/30/60 s EN, ZH, mixed utterances; RAM high-water | `docs/benchmarks/M0-results.md` |
| 0.2 | Apple SpeechTranscriber zh_CN vs turbo on same fixtures; DictationTranscriber contextualStrings A/B (10 planted terms EN + ZH) | 〃 |
| 0.3 | Fn-key CGEventTap: observation on macOS 26; AppleFnUsageType suppression experiment; Right-⌘ path | 〃 + short screen recording |
| 0.4 | Paste ladder prototype vs 6 target apps (TextEdit, Gmail-in-Safari, Slack, VS Code, iTerm2, Notes) | checklist table |
| 0.5 | Cleanup providers (Apple FM / MLX Qwen / Ollama): latency + first 20 eval cases | 〃 |
| 0.6 | iPhone: turbo load time + 30 s utterance latency + thermal over 10 runs; SpeechTranscriber-while-backgrounded probe | 〃 |

Gate: results doc committed; engine/model defaults in docs/04 updated or confirmed;
interview answers folded in.

## M1 — DictationCore foundation (≈1–2 weeks)

- Repo scaffolding: XcodeGen, DictationCore SwiftPM package, CI (build + test + lint),
  Makefile, fixtures layout.
- CoreModels + TextPipeline stages 1/2/4 complete with golden tests (EN + ZH fixture sets).
- PersistenceKit: GRDB schema v1 + migrations + dual-FTS5 search + repositories, tested.
- ASRKit protocol + WhisperKit adapter transcribing fixture WAVs; ModelStore with
  download/verify/delete.
- Gate: `swift test` green in CI; a CLI harness (`scripts/dictate-file`) transcribes a
  fixture m4a end-to-end through stages 1/2/4 and stores it in a real database.

## M2 — macOS capture & hotkey (≈1–2 weeks)

- AudioPipeline: capture actor, converter, level meter, Silero VAD gate, crash-safe temp
  recording, device handling (AirPods policy).
- Hotkey tap (Fn + Right-⌘ + config UI), press semantics, tap hygiene, permissions
  onboarding flow (mic + Accessibility + AppleFnUsageType detection with deep link).
- Menu-bar shell + HUD panel (idle/listening/processing states, waveform).
- Gate: hold-Fn anywhere → speak → release → transcript appears in a debug console +
  history DB. Screen recording; soak: 50 consecutive dictations, sleep/wake, AirPods swap.

## M3 — Text delivery + full core loop (≈1 week)

- Insertion ladder (paste primary + Unicode-typing fallback + clipboard notice), secure-
  input pre-flight, spacing/capitalization stage-4 integration.
- Dictionary UI (CRUD, CSV import/export, add-from-history) wired into the pipeline.
- WhisperKit prompt-biasing experiment with dictionary terms (keep if it measurably helps).
- Gate: **AC-1** (6/6 apps) demonstrated on recording; **AC-3** latency numbers from the
  timings log; **AC-6** dictionary demo.

## M4 — AI cleanup & profiles (≈1–2 weeks)

- CleanupKit + three providers (FM, MLX, HTTP/Ollama+OpenAI-compat), prompt templates
  v1 (EN/ZH), output validators, protected terms, prewarm-at-press.
- ProfileKit: routing (bundle ID + browser hostname via AppleScript with Automation
  degradation), built-in profile set, profile CRUD UI, custom style prompt setting.
- 60-case cleanup eval harness + committed baseline results.
- Gate: **AC-4** (≥90% hard-rule pass incl. both self-correction showcase cases),
  **AC-5** (profile routing shown via history log), cleanup-failure fallback demo
  (kill Ollama mid-dictation → raw text still delivered).

## M5 — macOS v1 polish & exit (≈1–2 weeks)

- History window (search EN+ZH, filters, actions, export, retention), audio import
  (formats, long-file chunked pipeline, progress/cancel), settings panes, onboarding
  playground, launch-at-login, logging/diagnostics, Reduce Motion/VoiceOver pass.
- Soak + edge cases: secure fields, full-screen apps, multi-display, 100-dictation run.
- Gate: **the full AC-1…AC-10 checklist** run and recorded; tag `v1.0-mac`.

## M6 — iOS core app (≈2 weeks)

- iOS app shell: capture UI, session model (background audio + auto-expiry), App Intents
  ("Start Dictation"), Control Center control + Action Button, Live Activity, auto-copy
  delivery, history/dictionary/profiles UI (shared DictationCore), share-extension import.
- iPhone engine defaults per M0 measurements; Apple FM cleanup path.
- Gate: **AC-i1, AC-i2, AC-i4, AC-i5, AC-i6** demonstrated (recordings + on-device eval).

## M7 — iOS keyboard (≈1–2 weeks)

- Keyboard extension (D2b): mic key ↔ session signaling, pending-transcript insertion,
  host-app profile routing, minimal QWERTY fallback layout, Full Access onboarding.
- D2a runtime probe behind a feature flag (attempt in-keyboard capture; fall back).
- Gate: **AC-i3** in Messages, WeChat, Safari, Mail — recording; extension memory profile
  ≤40 MB under Instruments.

## M8 — Sync & niceties (optional, ≈1 week)

- CloudKit private-DB sync (SQLiteData) for history/dictionary/profiles, off by default.
- Menu-bar "pin profile", import-queue niceties, stats screen.
- Gate: two-device sync demo; airplane-mode regression run (everything still works).

## Later / parked

AX direct-insertion fast path for native apps; sherpa-onnx adapter (hotword biasing);
command mode ("select last sentence…"); streaming type-as-you-speak insertion; VAD
auto-stop refinements; Burmese revival via Omnilingual ASR (docs/04 appendix A); Apple
Watch remote; per-app language pinning; OS 27 `LanguageModel` provider unification.

## Timeline honesty

Solo + AI-agent development, part-time: **M0–M5 ≈ 6–9 weeks; M6–M7 ≈ 3–4 weeks.** The
long poles historically (per every reference app studied) are insertion edge cases and
permission/TCC weirdness, not ASR.
