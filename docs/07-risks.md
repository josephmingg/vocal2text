# Risk Register

Ordered by (impact × likelihood). Each risk names its mitigation and its early-warning
signal. Research provenance: 2026-08-16 fleet run + reference-codebase issue archaeology
(docs/09).

## R1 — Text insertion fails in some target app (High / High)

The paste ladder is the industry consensus *because* nothing is universal: Electron apps
need longer delays, terminals intercept ⌘V, secure input silently eats keystrokes.
**Mitigation**: tiered ladder with configurable delays (docs/03 §3.2); secure-input
pre-flight with culprit identification; per-app test matrix in every milestone gate; the
transcript always lands in History regardless (nothing is ever lost).
**Signal**: M0 spike 0.4 table shows any red cell → add app-specific handling early.

## R2 — Fn hotkey friction (Medium / High)

Bare-Fn PTT requires the user-level "Press 🌐 key to: Do Nothing" setting; Apple could
change `AppleFnUsageType` semantics; third-party keyboards may never emit Fn; the tap can
be silently disabled.
**Mitigation**: Right-⌘ as an equal-citizen fallback sharing the same code path; onboarding
detection + deep link; tap re-enable hygiene + synthetic-release recovery (docs/03 §3.1);
never poll `CGEventTapIsEnabled` (documented kernel-panic path).
**Signal**: M0 spike 0.3; any macOS point-release changing Globe behavior.

## R3 — TCC/permission wedging during development (Medium / High)

Ad-hoc-signed rebuilds silently kill Accessibility grants (CDHash keying); permissions
survive weirdly across upgrades.
**Mitigation**: stable Apple Development signing from day one; separate dev bundle ID;
`make reset-tcc`; onboarding shows live grant status and a re-arm path that doesn't need
an app restart.
**Signal**: hotkey "stops working" after a rebuild — expected until signing is set up;
treat any recurrence after M1 as a bug.

## R4 — Chinese quality gaps (Medium / Medium)

Whisper zh punctuation is inconsistent; Apple engine's zh WER is unpublished; small-LLM
cleanup can mangle Traditional↔Simplified or destroy code-switched English; full-width
punctuation drift.
**Mitigation**: stage-4 deterministic full-width/spacing formatter runs regardless of LLM;
script-preservation as a top-priority prompt rule with character-pair examples; ZH-specific
eval fixtures from day one (AC-2, AC-4); dictionary re-applied post-LLM.
**Signal**: M0 spikes 0.1/0.2/0.5 ZH numbers; user-reported corrections clustering on
punctuation or script.

## R5 — Cleanup LLM misbehavior (Medium / Medium)

Known failure modes: answering the dictation instead of cleaning it, hallucinating
content, reasoning-trace leakage, over-eager "correction" removal, Apple FM guardrail
false-positives.
**Mitigation**: docs/05 §3.3 output validators (length ratio, meta-text markers, language
match, protected terms) with automatic raw-text fallback; temperature ≤0.3; think-mode off;
raw transcript always stored; cleanup off by default.
**Signal**: validation-failure counter in diagnostics; eval-suite regressions on model or
prompt changes.

## R6 — iOS keyboard expectations vs platform reality (Medium / Medium)

No in-keyboard recording; Full Access scary prompt; one-bounce session arming; no
auto-return API. The iPhone can never equal the Mac's hold-anywhere UX.
**Mitigation**: PRD written around the honest D2b design; Action-Button/Control path as
the primary iPhone habit; expectations set in docs/02 up front (no surprise in M7).
**Signal**: if the M6 gate shows the session pattern feels bad in daily use, elevate the
clipboard/Action-Button flow to primary and demote the keyboard.

## R7 — OS churn mid-project (Medium / Medium)

macOS/iOS 27 ship ~Sept 2026: possible SpeechAnalyzer changes, background-ANE entitlement
requirement (`continued-processing.inference`), MenuBarExtra behavior changes, Metal/ggml
backgrounding regressions (already seen in iOS 26.2).
**Mitigation**: explicit OS-release checkpoints in the roadmap; **[verify]** tags in
docs/03/04 double as the re-verification checklist; deployment target already at 26 so we
adopt 27 features deliberately, not accidentally.
**Signal**: first 27 betas; WhisperKit/FluidAudio release notes.

## R8 — Model/runtime ecosystem drift (Low / High)

The 2026 local-AI ecosystem moves monthly (WhisperKit renamed mid-year; Ollama switched
engines; Qwen releases quarterly). Pinned choices rot.
**Mitigation**: protocol seams (docs/03 §8) make engines/providers replaceable; versioned
model catalog manifest; pinned SPM versions with a scheduled quarterly bump.
**Signal**: dependency release notes; benchmark regressions after bumps.

## R9 — Latency creep (Low / Medium)

Each stage is fast; the sum can stop feeling instant (SpeakType shipped ~850 ms of pure
sleeps).
**Mitigation**: per-stage timings recorded on every dictation (FR-11.4); p50/p95 budget in
AC-3 enforced at the M5 gate; no fixed sleeps allowed in the delivery path (poll/observe
instead — code-review rule).
**Signal**: timings overlay trend; any new `Task.sleep` in review.

## R10 — Scope creep vs. shipping (Low / Medium)

Wispr Flow has years of surface area (command mode, notetaker, snippets…). Cloning
everything before using anything is the failure mode.
**Mitigation**: v1 scope frozen in docs/00 §3; everything else in roadmap "Later"; the
M2 gate already produces a personally useful tool (dictate → console/history), M3 a real
one (insertion) — daily-driving starts at M3, feedback drives the rest.
**Signal**: any milestone growing past its listed contents.

## R11 — Privacy leaks from our own tooling (Low / Low)

SpeakType shipped transcript logging to a world-readable /tmp file in release builds.
**Mitigation**: structured os_log only; no transcript content at default log level;
network-free integration test (NFR-1/AC-9); remote-provider badge; export path reviewed.
**Signal**: log audit in each milestone gate checklist.
