# Deep Review & Improvement Plan — "Match Wispr Flow" (2026-08-26)

> **Status addendum (same day):** this review was written against the v0.1.1 snapshot;
> main's v1.1 (through `f669569`) independently resolved several findings before the
> review landed — W1 (mic-first press), W8 (both-modifiers edge, via the extracted
> `HotkeyDecisionCore`), W12/G7 (FTS5 surrogate-rowid migration), the fake waveform,
> audio retention + cancelled-take recovery (G9), Escape-in-lock (G5), the low-disk
> guard (G4), per-take provider routing (G3/G15), app names in history (G8), and the
> per-row delete-all. The remaining Phase 0–1 items — W3 concurrent takes, W9 dead-tap
> failure surfacing, W10 provisional short-taps, latency surfacing, structured logging,
> diagnostics counters, the benchmark harness, and the lint gate — are implemented on
> this branch, adapted to the v1.1 architecture. Phase 2+ recommendations stand.
>
> **Phase 2 status (2026-08-26, this branch):** implemented — step 13 (launch/mode-change
> preload, gated so it never surprise-downloads), step 14 (Parakeet TDT v2 via FluidAudio
> 0.9.1, pinned-EN route behind a Settings toggle that ships OFF pending vocal-bench
> numbers), step 15 (Settings → Models pane; primary model is a live setting, not a
> hardcoded name), step 16 (Silero VAD via the existing sherpa-onnx dep: silence delivers
> nothing, the engine decodes only the padded speech envelope; hands-free auto-stop
> deferred to the Phase 3 streaming work), step 17 in its superseded AX-first form
> (verified Accessibility insertion, paste as fallback), step 18 (pinned ComputeOptions;
> quantized-variant comparison remains a vocal-bench exercise), step 19 (real-prompt
> prewarm, keep_alive, shared URLSession, no press-path probe), step 20 (deterministic
> skip heuristic, eval-guarded), and adopted steps 48 (dictionary cache), 49 (post-settle
> archive/history write), 50 (preheated capture engine, hoisted start-path I/O).
> Step 13's optional idle-unload setting is not built (keep-resident is the default);
> steps 47 and 51–54 remain open.

**Scope**: a full product + engineering review of Vocal v0.1.1 against the 2026 dictation
market (Wispr Flow, superwhisper, VoiceInk, Aqua Voice, Handy, MacWhisper), followed by a
step-by-step, phased improvement plan. **This document recommends; it does not implement.**
No code changes accompany it.

> Note on sources: the requested YouTube video could not be fetched from the review
> environment (network egress to youtube.com is blocked). The competitive baseline below
> comes instead from primary research on Wispr Flow's documented architecture and feature
> set, plus the rest of the 2026 dictation market. Repo findings come from reading the
> code and docs on `main` at `92b44ed`.

---

## Part 1 — Where Vocal stands today

### What is genuinely excellent (keep doing this)

- **Architecture discipline.** One actor (`DictationSession`) owns the lifecycle; every
  platform seam is injected; the whole core runs and tests on Linux. ~200 tests cover the
  pure logic exhaustively (Stage-1 loops, CJK dictionary boundaries, validator showcase
  cases, path-traversal-hardened model deletion).
- **The tap hygiene.** The CGEventTap work (`HotkeyMonitor.swift`) shows deep platform
  knowledge: re-enable-from-callback only, Fn-latching keycodes excluded, synthesized
  release on tap-disable, never consuming events.
- **The cleanup safety story.** Prompt hard rules + length-aware validators +
  Damerau-Levenshtein protected-terms verification + never-lose-the-dictation fallback is
  *better designed* than what superwhisper ships (whose LLM famously sometimes answers the
  dictation instead of cleaning it — Vocal's validator catches exactly that).
- **Privacy-first positioning.** Offline by default, no telemetry, transient+concealed
  pasteboard marking, secure-input pre-flight that persists nothing. Wispr Flow's biggest
  2026 controversy (periodic active-window screenshots sent to cloud subprocessors) is
  the market opening Vocal is perfectly shaped to exploit.
- **Documentation.** 14 design docs with honest known-gaps tracking is rare and valuable.

### The honest gap vs. Wispr Flow

Wispr Flow's pipeline is **<700 ms end-to-end at p99** (cloud ASR + a fine-tuned Llama
cleanup step doing 100+ tokens in <250 ms on TensorRT-LLM). Local apps closed the speed
gap in 2026 via **NVIDIA Parakeet TDT on the Apple Neural Engine** (~0.5 s per minute of
audio; FluidAudio's CoreML build measures 110x+ real-time on M-series). Vocal today:

| Dimension | Wispr Flow | Vocal v0.1.1 |
|---|---|---|
| ASR | cloud Whisper-class, streaming | WhisperKit large-v3-turbo, **batch only**, lazy-loaded |
| Feels-fast tricks | streaming UI, <700 ms p99 | none measured; fixed 350–650 ms paste sleeps |
| Cleanup | fine-tuned Llama, <250 ms | Ollama HTTP (unbounded model), 6 s timeout, off by default |
| Live feedback | Flow Bar with live state | synthesized sine waveform, blank partial-text line |
| Context awareness | screenshots → cloud (controversial) | none |
| Dictionary | yes + auto-learning | yes (regex replacement) — **not fed to the ASR model** |
| Command mode | yes (Pro) | no |
| Hands-free | double-tap lock, 20 min cap | double-tap lock, 15 min cap |
| Languages | 100+, auto code-switching | EN + ZH incl. code-switching (deliberate scope) |

### Critical weaknesses found in the code (the "weakness box", deep-dived)

**Latency — the ones that actually cost time on every single dictation:**

- **W1. Mic start waits for profile resolution.** `DictationSession.pressBegan` awaits
  `profileResolution()` *before* `audio.start()`, and that resolution can block up to
  **1.5 s** inside `osascript` fetching a browser URL (`BrowserURLFetcher`). A slow
  browser delays the microphone itself — the head of the utterance is lost. This is the
  single worst latency bug in the app.
- **W2. Fixed paste sleeps.** 100 ms + 250 ms blind `Task.sleep`s on every paste (250+400
  for Electron apps) instead of observing `NSPasteboard.changeCount`. That is 350–650 ms
  of pure, avoidable, *perceived* latency after transcription finishes.
- **W3. Serialized session control.** `enqueueControl` chains each press on the previous
  take's completion — you cannot start dictating while the previous take is still
  transcribing/cleaning (up to the 6 s cleanup timeout). Wispr Flow users rapid-fire.
- **W4. Lazy model load, no warm-up at launch.** First dictation of the session pays the
  full WhisperKit load; warm-up is a buried onboarding button. The docs' own reference
  study (docs/09, lesson #12) warns about exactly this.
- **W5. Batch-everything transcription.** `transcribeStream` is a fake stream (accumulate,
  one pass at the end). No partial results possible; a 60 s utterance transcribes only
  after you release the key.
- **W6. No VAD.** docs/03 specifies Silero VAD; nothing is wired. FR-1.5's "has speech"
  check is a duration heuristic; silence is transcribed (Whisper hallucination food).
- **W7. Per-press cleanup probe.** Every hotkey press fires an HTTP availability probe +
  prewarm request and builds a fresh ephemeral `URLSession` per request.

**Correctness — bugs that will bite:**

- **W8. Right-modifier up-edge misread.** Hold Left-⌘, tap Right-⌘: the up-edge still has
  `.maskCommand` set, so the code reads it as a *down* edge — recording starts and never
  stops. Known in docs/13 ("both-keys-held caveat") but not in known-gaps.
- **W9. `startTap()` can report success with a dead tap.** 2 s semaphore timeout, then
  returns `true` regardless; retry timer stops; hotkey silently dead.
- **W10. First tap of a double-tap delivers.** A short tap emits `pressEnded`; if >0.5 s
  of audio existed, the take transcribes *and pastes* before the second tap locks.
- **W11. Audio held twice per take.** The `chunks` AsyncStream is produced but never
  consumed, and buffers unboundedly — a 15-min lock take holds ~58 MB twice.
- **W12. FTS5 tables keyed on rowid over a TEXT-PK table** (G7) — corrupts on VACUUM.
- **W13. Latent deadlock seam**: `DispatchQueue.main.sync` from the session actor in
  `FrontmostContext`, safe only by an undocumented invariant.

**Trust & observability:**

- **W14. Zero structured logging** — six `print()`s in a privacy app, going to stdout in
  Release. No validation-failure counters (docs/07 R5 names them the early-warning signal).
- **W15. Failed takes vanish.** A failed transcription produces no history row and the
  crash-recovery `.pcmf32` sidecar is never read back by anything — recovery is half-built
  and cancelled-take files leak into /tmp forever.
- **W16. Dead or lying UI.** iOS shows an AI-cleanup toggle wired to `nil`; the
  audio-retention picker stores a value nothing reads; `ModelStore`/`ModelCatalog`/
  `ModelDownloader` and both `AppleSpeechEngine` + `FoundationModelsProvider` are
  complete, tested… and unreachable from any UI (the macOS 14 deployment target can never
  run the `@available(26)` code paths).
- **W17. Dictionary is not re-applied after the LLM**, contradicting docs/07's stated R4
  mitigation; the verifier rejects wholesale instead of repairing.
- **W18. No benchmarks exist.** No `docs/benchmarks/`, no `scripts/` — every latency and
  accuracy claim in the docs is still an assumption (tracked as "M0 debt", A5).

**Assist-features gap (what makes Wispr Flow feel like an assistant, not a transcriber):**

- No streaming partial text or real waveform in the HUD (G2 — the two biggest
  "feels instant" levers).
- Dictionary terms never bias the ASR model (`dictionaryTerms` accepted and ignored by
  both engines) — proper nouns still mis-transcribe even when the user taught the app.
- No snippets/text expansion, no command mode, no "re-paste last transcript", no
  edit-and-retry, no auto-learned vocabulary, no code mode (camelCase/snake_case), no
  per-app language pinning, no context awareness of any kind (not even the local,
  privacy-safe kind: selected text, clipboard, AX preceding text).
- Stage-4 smart spacing is built and tested but always receives `precedingContext: nil`,
  so consecutive dictations never join correctly (FR-3.3 dead path).
- Profiles are hard-coded built-ins; no CRUD UI, no persistence (A6).

---

## Part 2 — The improvement plan

Ordered phases; each phase is shippable on its own and sequenced so that measurement
precedes optimization, correctness precedes features, and features precede platform
expansion. Effort keys: S (≤1 day), M (2–4 days), L (1–2 weeks) — solo + AI-agent pace.

### Phase 0 — Measure before touching anything (the "no more guessing" phase)

The app already timestamps five pipeline stages into every history row and displays none
of it. Instrument first; every later phase then proves its win with numbers.

1. **[S] Latency HUD/overlay (FR-11.4).** Surface the existing `TimingBreakdown` in
   History detail and as an optional post-dictation toast: capture / transcribe / clean /
   deliver, plus total press-release→text-visible.
2. **[M] Benchmark harness (`scripts/dictate-file` + fixtures).** The M0 spike checklist
   from docs/06, finally: p50/p95 latency for 5/15/30/60 s EN, ZH, mixed fixtures; WER
   against reference transcripts; RAM high-water. Commit `docs/benchmarks/M0-results.md`.
   This is the baseline every optimization in Phase 2 is judged against.
3. **[S] Structured logging (W14).** Replace `print` with `os_log`/`Logger`, privacy-safe
   categories (session, audio, engine, cleanup, delivery), a debug log window or
   log-export button. Add counters: validator rejections, paste fallbacks, tap re-enables.
4. **[S] Truth pass.** README "Status: planning" → shipped v0.1.1; remove or wire the
   lying iOS cleanup toggle and the dead audio-retention picker (W16); add the missing
   SwiftLint/swift-format CI job the docs already claim exists.

### Phase 1 — Correctness hot-fixes (small, high-severity, all pre-conditions for speed work)

5. **[S] Start the mic first (W1).** Reorder `pressBegan`: start audio capture
   immediately on press; resolve the profile *concurrently* (it is only needed at
   release). Cap the browser-URL fetch with a short timeout off the critical path. This
   alone removes up to 1.5 s of worst-case lost speech.
6. **[S] Fix the both-modifiers up-edge bug (W8).** Track the pressed state per keycode
   (edge = transition of *that key's* state), not via `flags.contains`.
7. **[S] Fail loudly on dead tap (W9).** Treat semaphore timeout as failure; keep the
   retry timer running; surface a menu-bar warning state when the hotkey is not armed.
8. **[S] Double-tap must not deliver (W10).** Hold the first short-tap's take in a
   pending state for the 0.35 s double-tap window before releasing it to the pipeline.
9. **[S] Consume or drop the chunks stream (W11)** so audio is held once. (Phase 2 will
   start consuming it for real — streaming + VAD.)
10. **[S] Concurrent takes (W3).** Let a new press start capture while the previous
    take is still in transcribe/clean/deliver; queue only *delivery* per target app.
11. **[M] FTS5 rowid hardening (G7/W12)** — INTEGER PRIMARY KEY surrogate + FTS rebuild
    migration, before any sync/export feature multiplies the data at risk.
12. **[S] HUD timer restart fix; remove the `DispatchQueue.main.sync` seam (W13).**

### Phase 2 — Raw speed: the "match Wispr Flow" phase

Target: **press-release → text visible in under 1 second** for a 10 s utterance, measured
by the Phase 0 harness. The 2026 recipe used by the fastest local apps:

13. **[M] Preload + keep-resident (W4).** Load WhisperKit at app launch (background,
    QoS-utility), warm with a 1 s silent inference; optional unload-after-idle setting
    (NFR-2). First-dictation-of-the-day should feel identical to the tenth.
14. **[L] Add a Parakeet fast path.** Integrate FluidAudio's Parakeet TDT CoreML models
    (v2 English-only; v3 25-language) as a second `TranscriptionEngine`. On Apple
    Silicon this runs ~110x real-time on the ANE — a 30 s utterance in ~0.3 s, versus
    multi-second Whisper turbo. Engine choice per language mode: Parakeet for pinned-EN
    (and pinned-ZH stays Whisper; auto mode stays Whisper for code-switching). This is
    the single biggest raw-speed lever available and it's exactly what VoiceInk,
    superwhisper, and Handy adopted.
15. **[M] Resurrect ModelStore (W16).** Wire the already-built, already-tested
    catalog/downloader/delete into a Settings → Models pane: choose turbo vs small vs
    Parakeet, see disk usage, delete/re-download. Kills the hardcoded model name.
16. **[M] VAD gate (W6).** Silero (or FluidAudio FSMN) VAD on the live chunk stream:
    real has-speech for FR-1.5, trim leading/trailing silence before ASR (less audio =
    faster decode + fewer hallucinations), and auto-stop for hands-free mode.
17. **[M] Event-driven paste (W2).** Replace fixed sleeps with `changeCount` observation
    and a short poll for paste-completion; per-app delay table becomes a fallback cap,
    not a fixed cost. Saves ~300–600 ms per dictation.
18. **[M] Pin WhisperKit ComputeOptions** (ANE/GPU per platform; docs/04 already mandates
    CPU+ANE on iOS to avoid the background-Metal crash) and benchmark quantized variants
    (turbo q5 class) via the Phase 0 harness.
19. **[S] Cleanup transport efficiency (W7).** One shared `URLSession`; probe on settings
    change and cache availability instead of per-press; prewarm only when cleanup is on.
20. **[M] Fast cleanup path.** The Wispr lesson: cleanup must be <250 ms to feel free.
    Benchmark small local models (Qwen 3B class via Ollama today; an MLX in-process
    provider later) at temperature 0.2 with tight max_tokens; auto-skip cleanup for
    short utterances (< ~8 words) where Stage 1/2/4 already suffice.

### Phase 3 — Perceived speed: streaming feedback (the "feels instant" phase)

21. **[M] Real waveform (A2/G2).** Feed live mic levels from the capture actor into
    `WaveformView` — the synthesized sine is the first thing a demo viewer notices.
22. **[L] Streaming partial text in the HUD (G2/W5).** Consume the live chunk stream:
    with Parakeet, re-decode a growing window and commit the agreed prefix
    (LocalAgreement-style); with Whisper, chunk on VAD boundaries. Display-only per
    FR-4.1 — the final batch pass remains the correctness path, so accuracy is untouched.
    Aqua Voice's reviews prove streaming UI *reads* faster than batch even at equal
    total latency.
23. **[S] Sound + state polish.** Distinct arm/deliver/error sounds (exists), plus a
    subtle HUD "delivering" flash so the paste moment is visible; show the final
    latency number briefly (ties into #1).

### Phase 4 — Assist features: from transcriber to assistant (the user-facing "wow" phase)

24. **[M] Feed the dictionary to the ASR (W17-adjacent).** WhisperKit `initial_prompt`
    biasing with enabled dictionary terms (the M3 experiment docs/04 already planned);
    Parakeet/Apple-Speech `contextualStrings` equivalents. Measure with planted-term
    fixtures. This is the difference between "corrects Kubernetes after the fact" and
    "hears Kubernetes correctly".
25. **[S] Re-apply the dictionary after the LLM (W17)** — repair instead of reject when
    the verifier finds a mutated protected term; keeps more cleanups.
26. **[M] Snippets / voice shortcuts.** "insert my address", "sign off" → expansion
    table (a natural extension of `DictionaryEngine`, spoken-phrase → multi-line
    written form). CSV import/export for dictionary + snippets together.
27. **[M] Auto-learned vocabulary.** Mine history: when the user's delivered text is
    later corrected (edit-distance clusters of the same unknown word), or when rare
    proper nouns recur, suggest dictionary entries ("Add 'Anthropic' to your
    dictionary?"). Wispr Flow does this invisibly; doing it *visibly and locally* is
    better and on-brand.
28. **[M] Re-paste + retry.** Menu-bar & hotkey "paste last transcript again"
    (Wispr: ⌘⌃V), and History "re-run cleanup with profile X" — cheap, loved features.
29. **[L] Local context awareness — the privacy-respecting answer to Wispr's
    screenshots.** Three graduated, all-local sources: (a) `precedingContext` from the
    session's own last-insert record → smart spacing/joining finally works (FR-3.3);
    (b) selected text via the Accessibility API → dictating replaces/extends selection
    correctly; (c) focused-field value reads where AX allows → capitalization and tone
    hints for cleanup. All on-device, no screenshots, no cloud — make that a marketing
    line, not just an implementation detail.
30. **[L] Command mode (parked in docs/06 "Later" — promote it).** A small grammar,
    not an agent: "new line/paragraph", "scratch that", "select last sentence",
    "make it shorter" (routes selected text through cleanup with an edit prompt).
    Detection via a leading trigger word or a dedicated chord, so normal dictation
    never false-triggers.
31. **[M] Code mode.** A Terminal/Code profile upgrade: spoken → `camelCase`,
    `snake_case`, `CONSTANT_CASE`, symbol names ("open paren", "arrow"), dictation into
    Cursor/Claude Code/iTerm2. The 2026 "voice coding" niche is real and underserved
    locally (only Whisperer does it, batch-only).
32. **[M] Profile CRUD + persistence (A6)** — the built-ins become editable rows;
    per-profile language pin; per-app auto-switch visible in Settings (VoiceInk's
    "Power Mode" is its most-praised feature; Vocal's ProfileKit is already 80% of it).
33. **[S] Hands-free polish.** Configurable lock cap (15 min is hardcoded), Escape
    discards a locked take (G5), auto-stop on trailing silence via the Phase 2 VAD.

### Phase 5 — Reliability & trust (the "it keeps working" phase — users' #1 retention factor)

34. **[M] Failed-take recovery (W15/G9).** Every take's audio survives until delivery
    succeeds: encode to Opus/AAC at finish, a History "recover audio" row for failed or
    cancelled takes (24 h window), retention setting actually enforced, /tmp leak fixed.
35. **[S] Failure visibility.** Failed transcriptions get a history row with the error
    and the recoverable audio; HUD error states name the stage that failed.
36. **[M] Device-change resilience.** Handle `AVAudioEngineConfigurationChange`
    (AirPods connect/disconnect mid-take), input-device picker, converter tail flush,
    low-disk guard (G4).
37. **[S] Permission health.** Detect mic-permission loss and TCC resets; menu-bar
    warning state instead of silent dead hotkey (pairs with #7).
38. **[M] Kill the deployment-target contradiction (W16).** Either raise targets so
    `AppleSpeechEngine`/`FoundationModelsProvider` are reachable and ship as real
    options, or excise them and the docs' "two engines, four providers" claim until
    they're real. Dead code that looks alive is a maintenance tax.

### Phase 6 — Distribution & platform polish

39. **[M] Notarized, Sparkle-updated builds.** $99 Apple Developer enrollment,
    hardened runtime on, one-command signed+notarized DMG, auto-update feed. The
    AirDrop-a-zip flow caps Vocal at two users forever.
40. **[M] Onboarding upgrades (G11).** Hotkey test playground, per-permission health
    checks re-runnable from Settings, first-run model download with progress from the
    resurrected ModelStore.
41. **[L] Custom hotkeys (docs/13).** The already-written plan: `HotkeySpec` +
    preset dropdown + recorder, with the state machine extracted Linux-testable —
    fixes W8 structurally and unlocks non-Fn setups (external keyboards).

### Phase 7 — The moonshots (pick by appetite, after the above)

42. **[L] iOS keyboard extension (B2)** — dictate inside WeChat/Messages; the design in
    docs/02 §3.1 is ready. This is what makes iOS Vocal daily-usable.
43. **[L] iCloud private sync (M8)** for history/dictionary/profiles.
44. **[L] File import (FR-6)** — drag a podcast → timestamped transcript. The current
    text pipeline has quadratic spots (DictionaryEngine, loop-collapse regex) flagged in
    review; fix them as part of this, not before.
45. **[M] Whisper-mode tuning** — verify quiet-speech accuracy (Wispr markets this);
    likely mostly a VAD-threshold + gain question once Phase 2's VAD exists.
46. **[L] Streaming type-as-you-speak insertion** (parked in docs/06) — only after
    streaming preview (#22) proves stable; insertion-with-retraction is the hard part.

---

## Part 2b — Adopted from the second review (2026-08-27, "Release to Text")

A second, independent review of the same v1.1 codebase (run locally, full read of
Sources/ + MacApp + docs at `f669569`) converged with Parts 1–2 on most findings —
streaming decode as the one change that matters, model preload, VAD, AX insertion,
context-aware cleanup, the learning loop. Where it went further, the following items
are adopted into the phases below. Its framing is worth keeping verbatim: *ASR decode
is ~85% of the release-to-text wait; delivery, cleanup, and the text pipeline could
all be made infinitely fast and the app would still feel slow.*

**Upgrades to existing steps:**

- **Step 22 (streaming preview) is upgraded from display-only to commit-the-prefix.**
  Stream during the utterance, *commit* the stable prefix as it settles, and run the
  final accuracy pass over the unfinalized tail only. This converts streaming from a
  perceived-speed feature into most of the real ~10× win (their model: ~3,000 ms →
  ~355 ms for a 15 s take). The stability threshold is the accuracy dial; the WER
  harness (already built) arbitrates. Speculative cleanup then runs on the committed
  prefix while the user is still talking (upgrades step 20).
- **Step 16 (VAD): use the Silero VAD that already ships inside the sherpa-onnx
  dependency** (pulled in for the Burmese engine) — wiring, not a new dependency.
- **Step 17 (paste) is superseded by AX-first insertion:** Accessibility-API insertion
  as tier 0 (no clipboard round-trip, no sleeps), paste as fallback — and an AX read
  of the focused element after insertion is the success signal the docs said didn't
  exist, so the ladder can finally descend on failure. This demotes the hand-maintained
  Electron bundle-ID list from correctness requirement to optimization.
- **Step 19 (cleanup transport): prewarm with the real system prompt, not `"hi"`.**
  The ~700-token system prompt is byte-identical on every take; prewarming it puts the
  reusable prefix in the server's KV cache. Also send `keep_alive` explicitly and drop
  the `isAvailable()` HTTP round-trip from the press path.
- **Step 20 (fast cleanup): the skip heuristic is deterministic**, not length-based —
  no fillers, no correction cues, punctuation already sane → skip the LLM; guard the
  heuristic with the existing cleanup eval. Revisit the 7B model only after cleanup is
  off the serial path (their "don't do" list is right: model-shopping before Phase 2/3
  is premature).
- **Step 28 (re-paste/retry) sharpened into undo:** one shortcut that replaces the last
  insertion with the stage-2 raw text or removes it entirely — the safety net that
  makes aggressive cleanup acceptable. Ship before command mode.
- **Step 27 (auto-learned vocabulary) gains a concrete mechanism:** detect the
  "dictate → immediately re-dictate a fix" pattern, diff the two takes, propose the
  dictionary entry. Always propose, never auto-apply.

**New steps (adopted wholesale):**

47. **[S] `make bench-latency` from live history.** The fixture harness measures
    fixtures; this reads `TimingBreakdown` back out of the transcript table and prints
    p50/p95/p99 per stage bucketed by utterance length — real daily-driving numbers
    for free. Add the two marks the breakdown is missing: press→mic-open and
    release→text-visible (the two numbers the user actually feels).
48. **[S] Dictionary cache in memory, invalidated on edit** — removes a synchronous
    SQLite read from every take's critical path for data that changes monthly.
49. **[S] Fire archive + history write after idle** — neither affects delivered text;
    today both are awaited inside the pipeline before the session settles.
50. **[M] Pre-create the audio engine; hoist capture-start I/O.** Everything between
    key-down and mic-open (disk stat, sidecar file create, FileHandle open) is speech
    the user already spoke. Keep a prepared AVAudioEngine; cache the free-space check.
51. **[M] Deterministic number/date/unit formatting in stages 1/4** — "twenty twenty
    six" → "2026", "three thirty pm" → "3:30 pm". Faster and more reliable than the
    3B model, and removes a class of cleanup-eval failures.
52. **[M] Gate CI on the cleanup eval's pass rate** — the 139-check eval runs by hand
    today; a prompt or validator regression should fail a PR, not a vibe check.
53. **[S] Fix G6** — whitespace loss in the repeated-token collapse destroys paragraph
    breaks in exactly the long imports where they matter.
54. **[M] Usage dashboard** (words, WPM, streaks, hours saved) on data already stored;
    natural home for the latency percentiles. Personal-tool priority call — skip it if
    Vocal stays single-user.

**Four decisions the owner must make** (verbatim from the second review, still open):
(1) macOS 26 as a floor? — the two biggest free wins (Apple Speech streaming engine,
FoundationModels cleanup) both require it, and the app ships with a macOS 14 minimum;
(2) how much WER is acceptable for the 10× streaming win? — sets the prefix-commit
threshold; (3) does cleanup stay off by default? — if yes, Phases 3–4 reorder behind
Phase 2; (4) personal tool or shipped product? — decides the dashboard's and the
notarization work's priority.

## Part 3 — What "done" looks like

Measured by the Phase 0 harness, on the owner's Mac:

- **Latency**: press-release → text visible **p50 < 800 ms, p95 < 1.5 s** for a 10 s EN
  utterance with Parakeet; < 2.5 s p95 with Whisper turbo ZH. (Wispr Flow p99 ≈ 700 ms
  *plus* network round-trip and their own perceived 1–2 s; local can win.)
- **First dictation of the day**: indistinguishable from the tenth (preload).
- **Accuracy**: planted-term fixture set ≥ 95% with dictionary biasing on; zero
  hallucinated text on silent takes (VAD).
- **Trust**: zero silent failures — every failed take visible and recoverable; hotkey
  never silently dead.
- **Feel**: live waveform + streaming partial text; paste lands without a perceptible
  post-transcription pause.

The strategic position worth saying out loud: **Vocal's winning story is "Wispr Flow's
feel, nothing leaves your Mac."** Wispr's 2026 privacy controversy, subscription fatigue
($144/yr), and cloud-only architecture are exactly the gaps a polished, Parakeet-fast,
context-aware-but-local, open personal app fills. The codebase's bones — the actor
architecture, the test culture, the validator stack — are already better than most of the
paid competition. What's missing is speed engineering (Phases 1–2), visible feedback
(Phase 3), and the assistant layer (Phase 4).
