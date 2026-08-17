# Reference Codebase Learnings

Engineering findings from studying existing open-source dictation apps. Licenses are noted —
**MIT-licensed code may be adapted with attribution; GPL code is study-only** (this repo is
not GPL).

## SpeakType (github.com/karansinghgit/speaktype) — MIT

macOS menu-bar dictation app, ~15k lines Swift/SwiftUI, WhisperKit 0.9.x + FluidAudio
(Parakeet) engines, analyzed 2026-08-16. The closest existing codebase to our macOS PRD.

### Validated choices (it works in the field)

- **WhisperKit (CoreML) + FluidAudio/Parakeet dual-engine behind a small protocol**
  (`SpeechToTextEngine`: load/transcribe/status) with a manager routing by selected model.
  Confirms our pluggable-engine plan (docs/03).
- **Batch transcription of the full utterance, not chunk stitching.** SpeakType built a 4 s
  chunk pipeline and abandoned it: "Chunk stitching caused repeated phrases at boundaries
  across languages." Streaming *preview* is fine; the committed text should come from one
  full-utterance pass.
- **Capture pre-matched to ASR format**: AVCapture → 16 kHz/mono/16-bit WAV directly, no
  resample step.
- **Models downloaded on demand, never bundled**, into Application Support, with an
  installed-check requiring config + compiled model + ≥80% of expected byte size (guards
  truncated downloads), and a delete-and-retry-once auto-repair path.

### Ideas to steal (with SpeakType file references)

| Idea | Where | Why |
|---|---|---|
| **Fn-key hotkey via suppressing CGEventTap** (`headInsertEventTap`, return `nil` for the hotkey's `flagsChanged`, self-re-enable on `tapDisabledByTimeout/ByUserInput`) | `AppDelegate.swift:230` | The re-enable dance is mandatory. Note: whether returning `nil` actually stops the *system* Globe action is **unverified** — the broader research (docs/03 §3.1) says it cannot; suppression here targets terminal CSI leakage, which is real |
| **Emoji-picker suppression via synthetic F19**, gated on the real `AppleFnUsageType` pref (`com.apple.HIToolbox`) and skipped for terminal bundle IDs | `AppDelegate.swift:127-198` | **Unverified on macOS 26** and contradicts the fleet finding that the Globe action fires below the tap — this is exactly M0 experiment 0.3. Plan of record remains the "Press 🌐 key to: Do Nothing" onboarding step (docs/03 §3.1); if the F19 trick survives the experiment, it removes that onboarding step |
| **50 ms hotkey debounce on systemUptime** when multiple event sources overlap | `AppDelegate.swift:354` | Event tap + NSEvent monitors both fire |
| **Full-fidelity clipboard snapshot/restore**: every NSPasteboardItem, every UTI's Data; restore refuses if pasteboard string ≠ what we pasted | `ClipboardService.swift:63-99` | Images/RTF survive; never clobbers user's new copy |
| **Fixed-size borderless NSPanel, content morphs in SwiftUI** (`minSize == maxSize`, `.nonactivatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`); click-through when idle via `ignoresMouseEvents` per phase | `MiniRecorderWindowController.swift:164` | Spring animations never clip; HUD never steals focus or blocks clicks |
| **Pill position as pure geometry function** over NSRect + unit tests; re-run on `didChangeScreenParametersNotification` | `PillPosition` | Testable, survives monitor changes |
| **Concurrent model-load coalescing** (in-flight task + variant token; same-variant awaits, different-variant waits then re-checks) | `WhisperService.swift:98` | Prevents double-load memory spikes |
| **Hardware-aware model recommendation** (sysctl chip parse → perf tier → speed/accuracy weighted score) | `DeviceCapability` | Good defaults per machine |
| **Output-format pinning on the capture connection** so level metering never sees an unexpected layout (Zoom/FaceTime mid-call switches) | `AudioRecordingService.swift:204` | Real-world bug fix |
| **Model-cache deletion hardening**: deletes restricted to exact per-variant dirs under repo-owned roots, unit-tested | `ModelDownloadService.swift:19` | Never `rm -rf` a user path by substring |
| **Escape-to-cancel keeps the take recoverable** instead of destroying it | `MiniRecorderView` cancel flow | We adapt rather than copy: SpeakType transcribes cancelled takes immediately; our FR-1.6 stores the *audio* for 24 h and transcribes only on an explicit "Recover" (and not at all when audio retention is "never") |
| **Dev script installs under separate bundle ID** (`SpeakType-Dev.app`) + `make uninstall` runs `tccutil reset` | `Makefile`, `scripts/run-dev.sh` | TCC-permission hygiene during development |
| **Stats split from history** so "clear all history" keeps usage statistics | `HistoryService` | Privacy wipe without losing the fun numbers |

### Mistakes to avoid (each maps to a requirement of ours)

1. **Paste-only insertion with silent failure** — one mechanism, no fallbacks, and a silent
   do-nothing when Accessibility isn't granted. → Our FR-3.1 ladder is *also* paste-primary
   (the consensus is right), but adds the Unicode-typing fallback for terminals, a
   clipboard+notification last resort, secure-input pre-flight, and explicit failure
   surfacing; AX direct insertion stays a post-v1 experiment (docs/03 §3.2).
2. **~850 ms of blind fixed sleeps** in the commit path (500 ms post-activate + 350 ms before
   clipboard restore). → We poll/observe `didActivateApplicationNotification` and pasteboard
   `changeCount` instead of sleeping (docs/03).
3. **No secure-input detection** (`IsSecureEventInput` never called): hotkey and paste die
   silently in password fields. → FR-3.2 requires delivery-time detection + HUD notice, and
   additionally blocks *persistence* (a secure-field dictation is likely a password).
4. **No sleep/wake/lock re-arming** of the event tap or capture session; no recovery if
   `tapCreate` fails at launch and permission arrives later. → NFR-3 soak explicitly tests
   sleep/wake; tap creation must be retryable without relaunch.
5. **UserDefaults as the database** (all history JSON-encoded into one key, re-encoded per
   add). → GRDB/SQLite from day one (docs/03).
6. **Recording state machine inside a 1100-line SwiftUI View**, NotificationCenter as control
   bus, singletons throughout → state desync guards like `isListening || isRecording`. → Our
   pipeline is an actor-owned state machine; views render state, never own it.
7. **Release-build debug logging of transcript prefixes to `/tmp`** — a privacy leak in a
   privacy app. → NFR-1: structured os_log only, no transcript content at default log level.
8. **No VAD / max-duration guard** (defined error never thrown; stuck hotkey records until
   disk fills). → FR-1.3's lock-mode time cap (default 15 min) + low-disk guard, plus
   FR-1.5's VAD zero-speech discard; silence-based auto-stop is post-v1 (roadmap "Later").
9. **CJK-blind text handling**: ASCII-only trailing-punctuation logic (never `。`),
   English-only filler regex, `\b` word boundaries applied around Han characters (unreliable
   matches), whitespace word-count. → docs/05 language-aware stages; dictionary `.phrase`
   mode for CJK entries.
10. **Left/right modifier detection by keycode only**, and any modifier+key press while
    holding the hotkey cancels the recording (so Fn+⌘C kills dictation). → Explicit
    left/right handling; only Escape cancels an *established* recording (the ~1 s
    chord-abort window at press, docs/03 §3.1, is a distinct never-started case).
11. **Self-update replaces the app bundle via `rm -rf` then copy** (failure = app gone). →
    We don't ship self-update at all (git-based personal updates, FR-11.3).
12. **30–60 s first-model-load delay** surfaced as a known issue; no prewarm at login. →
    NFR-2 keeps the model warm by default with an unload-after-idle option; prewarm on
    launch/login.

## Others (from research fleet — see docs/04 for engine detail)

- **VoiceInk** (macOS, **GPL-3.0** — study-only): whisper.cpp-based, has per-app "Power
  Modes" (profiles), AI enhancement, dictionary — the closest feature-set match to our PRD;
  useful as a behavioral reference for profiles UX. No code reuse (license).
- **Handy** (cross-platform, MIT): Tauri/Rust + whisper-rs; useful for its
  cross-platform hotkey/paste abstractions and VAD usage (Silero via ONNX), less for
  Swift specifics.
- **WhisperKit sample apps** (MIT): canonical streaming/batch usage of the engine we plan
  to use, incl. model download UX.
