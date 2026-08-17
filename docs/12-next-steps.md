# Next Steps & Goals (handoff, 2026-08-17)

Status at handoff: **v0.1 shipped and field-verified.** Mac app installed and dictating
daily on two machines (owner's Mac + spouse's M2/Sonoma); iOS main app CI-green; all five
CI jobs green on `main`. Evidence: CI runs 32004944289 (all targets) and 32011357060
(macOS 14 target). Field findings already fixed: first-run model-download visibility,
`make generate` signing reset, Sonoma support, quarantine-stripping share flow.

**Landed since, and not yet run on hardware:** the customizable push-to-talk hotkey (A7)
and the Mac profile editor (A6). Both are on `main` and CI-green, but CI compiles the Mac
app without executing it, so the verification debt is real rather than ceremonial — the
hotkey change alters what keystrokes other applications receive, and the profile editor is
the first pane that writes to the database from the UI. **The next `make install` should
start with the A6 and A7 checklists, before any new feature work.**

**How to resume in a new session:** point Claude at this repo and this file. Working
branch convention: `claude/offline-voice-text-app-oy19q9` (restart it from `main`).
Read `docs/11-known-gaps.md` alongside — G-numbers below refer to it.

## Phase A — daily-driver polish (highest value per hour)

| # | Goal | Notes |
|---|---|---|
| A1 | **Turn on AI cleanup for real** | **Harness built, never run against a model.** The 62-case eval set and `make eval-cleanup` now exist (`evals/cleanup/`) — they did not before, which is why "run the 60-case eval" had no way to happen. Owner installs Ollama (`brew install ollama`, `ollama pull qwen2.5:3b-instruct` or newer Qwen), flips Settings → Cleanup, runs `make eval-cleanup`, commits the report, then tunes `Sources/CleanupKit/Resources/Prompts/` against it. Showcase cases are `en-corr-001` ("meet Friday, sorry Saturday") and `zh-corr-001` (「周五，啊不对，周六」). Gates AC-4: ≥ 90% hard-rule pass rate |
| A2 | **Live HUD feedback** (G2) | Feed real mic levels into WaveformView; wire `engine.transcribeStream` partials into `hudState.partialText` |
| A3 | **Audio retention + cancel recovery** (G9) | Encode takes to Opus/AAC in `MicrophoneCapture.finish`, honor the retention setting, add History playback + the 24 h cancelled-take Recover flow |
| A4 | **Insertion edge-case sweep** | Collect real paste failures from daily use; grow the per-app strategy table; expose overrides in Advanced settings |
| A5 | **Benchmark evidence (M0 debt)** | Run the docs/06 M0 spike checklist on the owner's Mac; commit `docs/benchmarks/M0-results.md` (latency p50/p95, WER on the fixture sets) |
| A6 | ~~**Profile editing UI + persistence**~~ | **Shipped on the Mac (#13, G17), unverified on hardware.** Settings → Profiles is a master–detail editor: name/icon, per-profile cleanup opt-in + prompt, language pin (incl. မြန်မာ → Burmese engine), Myanmar digits, spoken punctuation, ZH formatting, app/website routes, priority, default handling. `ProfileBootstrap.loadOrSeed` seeds the built-ins once and is Linux-tested; edits apply at the next press with no relaunch. **Left over:** iOS still has no editor (its seeded set is read-only), and `providerOverride` has no UI — pointless until G3/G15's provider-selecting factory exists. Verification checklist below |
| A7 | **Hotkey customization: hardware pass** | **Code complete, five CI jobs green, nothing executed.** PRs #6 and #11 shipped the preset dropdown, the custom recorder, the extracted decision core, the onboarding key step and the live key tester. CI compiles the Mac app but never runs it, so every runtime claim below is unproven. Closes when each row of the checklist has a result |

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
- Cold-review before merge for any substantial new subsystem (the two review fleets each caught ~2 dozen real bugs).
- `make generate` resets the Xcode signing Team — warn whenever a change touches `project.yml`.
