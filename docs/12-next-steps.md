# Next Steps & Goals (handoff, 2026-08-17)

Status at handoff: **v0.1 shipped and field-verified.** Mac app installed and dictating
daily on two machines (owner's Mac + spouse's M2/Sonoma); iOS main app CI-green; all four
CI jobs green on `main`. Evidence: CI runs 32004944289 (all targets) and 32011357060
(macOS 14 target). Field findings already fixed: first-run model-download visibility,
`make generate` signing reset, Sonoma support, quarantine-stripping share flow.

**How to resume in a new session:** point Claude at this repo and this file. Working
branch convention: `claude/offline-voice-text-app-oy19q9` (restart it from `main`).
Read `docs/11-known-gaps.md` alongside — G-numbers below refer to it.

## Phase A — daily-driver polish (highest value per hour)

| # | Goal | Notes |
|---|---|---|
| A1 | **Turn on AI cleanup for real** | Owner installs Ollama (`brew install ollama`, `ollama pull qwen2.5:3b-instruct` or newer Qwen), flips Settings → Cleanup. Then: run the 60-case eval against it, tune the prompt files in `Sources/CleanupKit/Resources/Prompts/`, and iterate on real dictations. The showcase test: "meet Friday, sorry Saturday" and 「周五，啊不对，周六」 |
| A2 | **Live HUD feedback** (G2) | Feed real mic levels into WaveformView; wire `engine.transcribeStream` partials into `hudState.partialText` |
| A3 | **Audio retention + cancel recovery** (G9) | Encode takes to Opus/AAC in `MicrophoneCapture.finish`, honor the retention setting, add History playback + the 24 h cancelled-take Recover flow |
| A4 | **Insertion edge-case sweep** | Collect real paste failures from daily use; grow the per-app strategy table; expose overrides in Advanced settings |
| A5 | **Benchmark evidence (M0 debt)** | Run the docs/06 M0 spike checklist on the owner's Mac; commit `docs/benchmarks/M0-results.md` (latency p50/p95, WER on the fixture sets) |
| A6 | **Profile editing UI + persistence** | Profiles are in-memory built-ins today; add CRUD in Settings, seed the database once, make the pin durable |

## Phase B — finish the iPhone

| # | Goal | Status |
|---|---|---|
| B1 | **Run VocalIOS on the owner's iPhone** | **Open — owner-only.** Cannot be done from CI: it needs the phone, Xcode signing, and a paid account for App Groups. Checklist and the measurements to record: `docs/14-running-on-your-iphone.md` |
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
- ~~**Burmese revival**~~ — shipped in v1.1: text layer, detection, dictionary and formatting are complete. What remains is the *engine* (G13): a sherpa-onnx adapter, benchmarked on FLEURS `my_mm` first
- Remaining known-gaps: G1 (secure-field anonymous event), G3 (per-profile provider routing), G4 (low-disk guard), G5 (Escape in lock mode), G7 (FTS5 rowid hardening), G8 (app names in history)

## Standing engineering rules (unchanged)

- Every change lands via the working branch → PR → all four CI jobs green → merge.
- Evidence-backed "done": benchmarks and screen recordings for behavior claims.
- Cold-review before merge for any substantial new subsystem (the two review fleets each caught ~2 dozen real bugs).
- `make generate` resets the Xcode signing Team — warn whenever a change touches `project.yml`.
