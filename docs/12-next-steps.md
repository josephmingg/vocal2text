# Next Steps & Goals (handoff, 2026-08-17)

Status at handoff: **v0.1 shipped and field-verified.** Mac app installed and dictating
daily on two machines (owner's Mac + spouse's M2/Sonoma); iOS main app CI-green; all five
CI jobs green on `main`. Evidence: CI runs 32004944289 (all targets) and 32011357060
(macOS 14 target). Field findings already fixed: first-run model-download visibility,
`make generate` signing reset, Sonoma support, quarantine-stripping share flow.

**Landed since, and not yet run on hardware:** the customizable push-to-talk hotkey (A7),
the Mac profile editor (A6), and the Mac stabilization batch (#19 — audio retention,
cancelled-take recovery, low-disk guard, Escape-in-lock, per-take cleanup provider,
VACUUM-safe search, real HUD microphone levels). All on `main` and CI-green, but CI
compiles the Mac app without executing it, so the verification debt is real rather than
ceremonial — the hotkey change alters what keystrokes other applications receive, and the
profile editor is the first pane that writes to the database from the UI. **The next
`make install` should start with the A6 and A7 checklists, before any new feature work.**

**Where the Mac stands (2026-08-19):** code-complete for v1. What is missing is execution,
not code. The open code gaps are small and named — G2's partial-text preview is the only
one a user would notice — while A6, A7 and A3 are all "shipped, never run". The iPhone
(Phase B, G10 and G19–G24) is parked by choice.

**How to resume in a new session:** point Claude at this repo and this file. Working
branch convention: `claude/offline-voice-text-app-oy19q9` (restart it from `main`).
Read `docs/11-known-gaps.md` alongside — G-numbers below refer to it.

## Phase A — daily-driver polish (highest value per hour)

| # | Goal | Notes |
|---|---|---|
| A1 | **Turn on AI cleanup for real** | **Harness built and run; hovering at the AC-4 line.** Ollama is installed on the owner's Mac and `make eval-cleanup` has real numbers against qwen2.5:3b-instruct — see the A1 log below for the run history and what each change bought. Latest committed report: **90.6% hard-rule (126/139), 0 validator rejections, 0 provider errors, p50 176 ms** against a 6 s budget. Two fixes landed after it that move the number and are described below; re-run before reading the score. Remaining work is prompt-and-model, not plumbing. Gates AC-4: ≥ 90% hard-rule pass rate |
| A2 | **Live HUD feedback** (G2) | **Half done.** Mac stabilization fed real microphone levels into WaveformView, replacing the synthesized ripple. Still open: wire `engine.transcribeStream` partials into `hudState.partialText` so words appear while you speak — the most visible gap left on the Mac |
| A3 | ~~**Audio retention + cancel recovery**~~ (G9) | **Shipped in Mac stabilization, unverified on hardware.** Delivered takes encode to AAC under `Application Support/Vocal/audio/`, History plays them back, deletion and Delete-All remove them, a launch sweep enforces the retention window, and the menu bar offers back a cancelled take for 24 h. Worth a row on the next hardware pass alongside A6/A7 |
| A4 | **Insertion edge-case sweep** | Collect real paste failures from daily use; grow the per-app strategy table; expose overrides in Advanced settings |
| A5 | **Benchmark evidence (M0 debt)** | Run the docs/06 M0 spike checklist on the owner's Mac; commit `docs/benchmarks/M0-results.md` (latency p50/p95, WER on the fixture sets) |
| A6 | ~~**Profile editing UI + persistence**~~ | **Shipped on the Mac (#13, G17), unverified on hardware.** Settings → Profiles is a master–detail editor: name/icon, per-profile cleanup opt-in + prompt, language pin (incl. မြန်မာ → Burmese engine), Myanmar digits, spoken punctuation, ZH formatting, app/website routes, priority, default handling. `ProfileBootstrap.loadOrSeed` seeds the built-ins once and is Linux-tested; edits apply at the next press with no relaunch. **Left over:** iOS still has no editor (its seeded set is read-only), and `providerOverride` has no UI — pointless until G3/G15's provider-selecting factory exists. Verification checklist below |
| A7 | **Hotkey customization: hardware pass** | **Code complete, five CI jobs green, nothing executed.** PRs #6 and #11 shipped the preset dropdown, the custom recorder, the extracted decision core, the onboarding key step and the live key tester. CI compiles the Mac app but never runs it, so every runtime claim below is unproven. Closes when each row of the checklist has a result |

### A1 log — what the eval has actually measured

Kept because the scores are only comparable if you know what changed between them, and
two of these runs are not comparable to anything.

| Run | Hard-rule | What changed |
|---|---|---|
| 82.0% | 114/139 | First live run. Exposed three scorer bugs, not model bugs: Han treated as a word character, `.widthInsensitive` equating `,` with `，`, and a case-insensitive capitalisation test |
| 87.1% | — | Scorer fixed. Also the validator's ratio floor, which was rejecting a legitimate self-correction collapse (`en-corr-007`) |
| 87.8% | 122/139 | `max_tokens` floored at 1024 — a reasoning model spends its budget thinking before it emits anything, so the old cap returned empty `content` and cleanup silently no-opped on every take |
| 85.6% | 119/139 | **Regression, reverted.** A style-override paragraph shipped unconditionally above a literal "(none)" gave the model standing permission to change word choice with nothing to bind it to, and a 3B model generalised into translation |
| **90.6%** | **126/139** | Style section rendered only when a style prompt exists; prompt decontaminated (see below); temperature 0 |

Two methodology fixes matter more than any single score:

- **The eval was sampling.** It ran at the app's shipping temperature of 0.2, so two runs
  of the same prompt differed by about two cases — the same size as the effects being
  chased. Nothing before the 90.6% run is a measurement. It defaults to greedy decoding
  now, takes `--temperature` to sample deliberately, and records what it used in the
  report header.
- **The prompt quoted the eval set.** Three of the 62 cases had their text verbatim in the
  shipped prompt (`en-corr-010`, `zh-corr-005`, and `zh-corr-001`, which predated this
  work), so the model could read the answers in its own instructions. Worse, one example
  placed an English sentence beside its exact Chinese translation and the model copied the
  Chinese — an English dictation came back in the wrong language. `PromptDoesNotQuoteTheEvalSetTests`
  walks the real case files and fails if any input or reference reappears in the prompt.

**Landed after the 90.6% report; re-run before trusting the number:**

- **A floor for short dictations.** The ratio floor only applied above 60 characters, so
  the worst failure the pipeline can produce walked through it: "what's the capital of
  France" came back as "Paris" — 0.18 of its input — and the app would have typed the
  model's answer in place of the user's words. The floor now applies at every length,
  measured against the content after the last self-correction cue so a correction may
  still discard its false start. 0.4 is calibrated against the case set: the tightest
  correct answer sits at 0.50, the answer-instead-of-clean failures at 0.18.
- **Two rates instead of one.** Rules are scored against the text the app actually types —
  cleanup's output when the validator accepts it, the stage-2 transcript when it rejects
  (FR-7.3). **Hard-rule pass rate** asks whether cleanup did its job and is what AC-4
  gates on, deliberately: a pipeline that rejected everything would be safe and useless.
  **Delivered-text pass rate** asks what the user ended up with. The gap is work cleanup
  declined to do rather than damage it caused.

Expect the next run to read **89.9% hard-rule (125/139) / 92.1% delivered (128/139)** with
one validator rejection. The drop is the floor catching "Paris": the strict rate loses the
one rule that answer had banked, and the delivered rate gains the three the user's own
question satisfies. That is the fix working.

### A1 — what is still failing, and why it matters

Nine cases fail in the 90.6% run. They are not one problem:

| Cases | Nature | Worth fixing? |
|---|---|---|
| `style-001/002/008` | British spelling. The model returns the input **byte-identical** — not even the missing full stop added. It is declining to act, not choosing American spelling. 5 of the 13 failing checks | Undiagnosed; needs a look at why the style instruction produces identity output |
| `en-corr-005/006`, `zh-corr-001` | Corrections resolved backwards ("three no four" → "three") | Model capacity — qwen3:8b gets these right |
| `en-quest-001` | Answers the question instead of transcribing it | Now caught by the validator; the user gets their question back |
| `mix-004` | 响应 substituted for the spoken `response` | Model capacity |
| `en-fill-007` | "hmm" survived | Minor |

Two cue-list gaps surfaced while calibrating the floor and are deliberately unfixed:
`zh-corr-003` says 「啊不是」 and `en-corr-008` says "wait no", neither of which is in
`SelfCorrectionCues`. Adding them changes the shipped prompt, so they want their own run.

**On model choice:** qwen3:8b scores higher (89.6%) and is the wrong model. Its median
latency is 9550 ms against a 6 s `cleanupTimeout`, so more than half of all dictations
would blow the deadline and silently fall back — a score the shipping app cannot collect.
qwen2.5:3b runs at 176 ms. If the remaining failures still matter after real use, the
answer is likely qwen2.5:7b at roughly 1 s, not a reasoning model.

### A6 checklist — the profile editor on hardware

`ProfileBootstrap` is unit-tested; `ProfilesPane` (~450 lines of new SwiftUI) is not, and
nothing here has been executed. Lower risk than A7 — no event tap, nothing that changes
what other apps receive — but it is the first pane that writes to the database from the UI.

| # | Check | Why this one |
|---|---|---|
| 1 | Fresh install: the built-in profiles appear once, and relaunching does not duplicate them | `loadOrSeed` is seed-once; a re-seed bug only shows on the second launch |
| 2 | **Existing** install (a profile database that predates #13) upgrades without losing or duplicating anything | The seeding path behaves differently against a non-empty store, and only an old profile can exercise it |
| 3 | Edit a profile, then dictate **without relaunching** — the change applies | Profiles are read from the live store at every press; the whole no-relaunch claim rests on that |
| 4 | The menu-bar pin picker reflects an edit or a new profile immediately | Pin UUIDs must stay aligned with the resolver's (FR-8.3); a stale copy makes pinning a silent no-op |
| 5 | Pin a profile to မြန်မာ, dictate — it routes to the Burmese engine | Per-profile language pins are the intended route to Burmese now that auto mode stays on Whisper (G13) |
| 6 | Delete the default profile, or demote it — routing still resolves | Exactly one profile owns the default route; the editor now lets you touch it |
| 7 | Every other Settings pane still lays out correctly | The window grew to 680×560 for the master–detail pane, which changes every sibling pane — including the hotkey control from A7 |

### A7 checklist — what "verified" means for the hotkey

Ordered by risk. The first three exercise code paths that did not exist before this
change, so a regression there would be new damage rather than a pre-existing gap.

| # | Check | Why this one |
|---|---|---|
| 1 | Hold the hotkey in TextEdit, dictate, release — no stray characters before the transcript | The tap now **consumes** a keyed binding's press, release and autorepeat (#6). It forwarded everything unconditionally until now, so this is the only change that alters what other apps receive. Highest risk in the whole feature |
| 2 | Press the key while Settings → General → **Test Your Key** is listening — ✓ appears, with no HUD, no sound, no transcript | Test-mode routing diverts hotkey edges away from dictation (#11). Exists only at runtime |
| 3 | Open the recorder, press the **current** hotkey — it captures, and no dictation starts behind the sheet | The sheet suspends the global tap (#6). Before that fix this started a real take, HUD and all |
| 4 | Bind Left ⇧. Hold Left ⇧, add Right ⇧, release Left ⇧ — the take must end | Device-specific modifier bits (`NX_DEVICE*KEYMASK`, #6). **A pass here is ambiguous:** when the hardware does not report those bits the code falls back to the old shared-bit behaviour, which also ends the take in the single-key case. Only the both-Shifts sequence distinguishes them |
| 5 | Record ⌥Space; confirm the amber secure-input caveat shows; then confirm it does **not** fire while a password field is focused | The keyed-vs-modifier asymmetry documented in docs/03 §3.1 — the reason Fn and Right ⌘ are the recommended pair |
| 6 | Press ⏎ in the recorder on a good capture — it commits rather than erasing it | Capture swallows key events, so the blue default button cannot fire on its own (#11) |
| 7 | Delete the `onboardingComplete` default, relaunch, walk onboarding — the key step appears, and the Globe page follows **only** when Fn is chosen | The step list is rebuilt when the key changes (#11) |
| 8 | F13/F14/F15 from an external keyboard | Presets no built-in Mac keyboard has |
| 9 | Press a bare F-key (say F4) in the recorder — does anything register at all? | **Open question, not a bug report.** In macOS's default media-key mode F1–F12 may emit no `keyDown`, which would make them recordable but dead. The recorder warns; it does not block. If they are dead, block them in `HotkeySpec.validationError` |
| 10 | A profile that predates the change keeps its key (Right ⌘ stays Right ⌘) | One-time migration from `settings.hotkeyChoice`; only observable on an existing install, never on a fresh one |

**Rollback if row 1 fails:** `HotkeyDecisionCore.handle` returns `Outcome.consumesEvent`;
forcing it `false` restores always-forward behaviour with no other change. The rest of the
feature is independent of it.

## Phase B — finish the iPhone

| # | Goal | Status |
|---|---|---|
| B1 | **Run VocalIOS on the owner's iPhone** | **Open — owner-only.** Cannot be done from CI: it needs the phone, Xcode signing, and a paid account for App Groups. Checklist and the measurements to record: `docs/14-running-on-your-iphone.md`. Note the account fork: a free Apple ID cannot provision App Groups, so `make generate-free` builds the app + Dynamic Island without the keyboard and share extensions (docs/14 §1a) |
| B2 | **Keyboard extension (D2b)** | **Code complete, compiles in CI, unverified on device.** `Sources/BridgeKit` holds the whole App Group contract (Linux-tested); `apps/iOSKeyboard` is the insert-only surface; `CaptureSessionCoordinator` is the app-side host. Closes when AC-i3 has screen recordings |
| B3 | **Share-extension import + Live Activity** | **Code complete, compiles in CI, unverified on device.** `apps/iOSShareExt` + `ImportProcessor` + `AudioFileDecoder`; `apps/iOSWidgets` renders the Dynamic Island. Closes when AC-i5 and AC-i6 have recordings |
| B4 | **iOS background audio session polish** | **Partly done.** Auto-expiry 5/15/60 and `AudioSessionManager`/`CaptureResidency` are in. Still open: the G22 latency spike and the NFR-i3 battery number |

**Where Phase B actually stands:** everything Phase B asked for is written and
builds, and the logic behind it is tested on Linux — but no line of it has run
on an iPhone. Treat B2/B3 as "ready for the device pass", not as shipped.
`docs/11-known-gaps.md` G10 and G19–G23 track exactly what is unproven.

## Phase C — deeper features (pick by appetite)

- **Notarized builds** — one-command signed+notarized dmg so sharing needs no Terminal tricks (requires $99/yr Apple Developer enrollment)
- **File import UI on Mac** (FR-6): drag-a-podcast → timestamped transcript with progress
- **iCloud private sync** (M8): per-Apple-ID — syncs the owner's Mac↔iPhone; spouse's data stays hers
- **Traditional Chinese toggle** (deterministic OpenCC-style table — deferred by owner choice)
- **Command mode** ("select last sentence, make it shorter") — parked in roadmap Later
- ~~**Burmese revival**~~ — text layer *and* the Mac engine have both landed: `SherpaOnnxEngine` (Omnilingual CTC 1B int8, 10.78% CER on FLEURS `my_mm`) serves pinned မြန်မာ via `LanguageRoutingEngine`. Left to verify (G13): the real-audio path has never run on a Mac — only the file-absence paths are CI-tested — and the iPhone 300M call waits on on-device RTF
- Remaining known-gaps: G1 (secure-field anonymous event), G3 (per-profile provider routing), G4 (low-disk guard), G5 (Escape in lock mode), G7 (FTS5 rowid hardening), G8 (app names in history)

## Standing engineering rules (unchanged)

- Every change lands via the working branch → PR → all five CI jobs green → merge.
- **CI green ≠ mergeable.** Check `mergeable_state` separately; `main` moved under an
  open PR three times in one afternoon, and the conflict is invisible in the checks.
- **CI compiles the app targets but never runs them.** Anything that only exists at
  runtime — event taps, SwiftUI flows, permissions — carries verification debt no matter
  how green the checks are. Say so explicitly rather than letting green imply working.
- Evidence-backed "done": benchmarks and screen recordings for behavior claims.
- **A benchmark harness is a measurement instrument, and instruments need calibrating
  before their readings mean anything.** The cleanup eval spent four runs producing
  numbers that could not be compared: it sampled at temperature 0.2, and the prompt
  quoted three of the cases it was grading. Both were invisible in the score. Before
  believing a harness, ask what it holds fixed and whether the answers can leak into
  the question.
- **Change a prompt, update its tests in the same commit.** Three CI failures on this
  branch were the same mistake: a prompt string edited, its assertion left pinning the
  old text. Prompt resources are code.
- Cold-review before merge for any substantial new subsystem (the two review fleets each caught ~2 dozen real bugs).
- `make generate` resets the Xcode signing Team — warn whenever a change touches `project.yml`.
