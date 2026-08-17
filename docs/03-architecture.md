# Technical Architecture

Stack decisions distilled from the 2026-08-16 research fleet + SpeakType/VoiceInk/Handy
codebase analysis (docs/09). Items marked **[verify]** land in the M0 spike checklist
(docs/04 §6).

## 1. Toolchain & repo layout

- **Xcode 26.x, Swift 6.2/6.3**, approachable concurrency: app targets use MainActor
  default isolation; `DictationCore` pipeline targets use `nonisolated` default with
  explicit actors.
- **Deployment targets: macOS 26, iOS 26** (assumptions A2/A3 — the Apple Speech and
  Foundation Models frameworks require it; revisit only if the interview contradicts).
- **XcodeGen** (`project.yml`, generated `.xcodeproj` gitignored) — file-based project
  definition, git-friendly, agent-friendly; `xcodegen generate` on fresh clone. Tuist is
  the upgrade path if complexity grows.
- **~90% of code in a local SwiftPM package** so `swift build && swift test` works without
  Xcode (and in CI) for everything that isn't an app shell.

```
vocal2text/
  project.yml                     # XcodeGen manifest (app shells)
  Makefile                        # bootstrap / generate / build / test / lint
  DictationCore/
    Package.swift
    Sources/
      CoreModels/                 # Transcript, Utterance, Profile, DictionaryEntry, Settings — pure value types
      AudioPipeline/              # capture actor, converter, VAD gate, level meter, file import
      ASRKit/                     # TranscriptionEngine protocol + shared types (zero heavy deps)
      ASREngineWhisperKit/        # argmax-oss-swift adapter (primary EN/ZH)
      ASREngineAppleSpeech/       # SpeechAnalyzer/DictationTranscriber adapter (fast path + dictionary biasing)
      TextPipeline/               # stages 1/2/4: normalizer, dictionary, formatter (pure functions)
      CleanupKit/                 # stage 3: CleanupProvider protocol, prompt templating, validators
      CleanupProviderFM/          # Apple Foundation Models adapter
      CleanupProviderMLX/         # MLX Swift adapter (Mac; iPhone optional)  — macOS-only Metal use
      CleanupProviderHTTP/        # Ollama + OpenAI-compatible adapter
      PersistenceKit/             # GRDB schema, migrations, FTS5, repositories
      ModelStore/                 # model catalog, downloads, SHA-256 verify, disk layout
      ProfileKit/                 # profile resolution (bundle-id/hostname → profile)
    Tests/
      ...Tests/  Fixtures/{audio,cleanup,text}/
  apps/
    MacApp/                       # menu bar, HUD panel, hotkey tap, insertion, browsers, onboarding
    iOSApp/                       # SwiftUI app, capture UI, App Intents, Live Activity
    iOSKeyboard/                  # keyboard extension (M7): UI + insertion only, ≤40 MB, no models
    iOSShareExt/                  # audio import share extension
  scripts/                        # eval-asr, eval-cleanup, fixture tooling
  docs/
```

Dependency injection: plain constructor injection (research flagged property-wrapper DI
frameworks as fragile under Swift 6.2 MainActor defaults). Engines/providers resolved from
a small composition root per app.

## 2. The pipeline (core state machine)

One actor owns the dictation session lifecycle; views render its published state and never
own logic (anti-pattern lesson from SpeakType, docs/09 §avoid-6).

```
                 ┌────────────────────────────────────────────────┐
 hotkey press ──▶│ DictationSession (actor)                       │
 hotkey release ▶│  idle → arming → recording → transcribing →    │──▶ TextDeliverer (macOS)
 esc/cancel ────▶│  cleaning → delivering → idle   (+ cancelled)  │──▶ HistoryStore
                 └────────────────────────────────────────────────┘
   AudioCapture actor ──AsyncStream<PCMBuffer>──▶ TranscriptionEngine (streaming partials → HUD)
   ProfileResolver (at press: frontmost bundle ID → hostname → Profile)
   TextPipeline stages 1/2/4 (pure)   CleanupProvider (stage 3, cancellable, timeout)
```

- **Press** (not release) resolves the profile, pre-arms the audio engine, and fires the
  cleanup-provider prewarm (`max_tokens:1`-style request) so everything is hot at release.
- Audio callback does nothing but copy buffers into an `AsyncStream` (bounded,
  `.bufferingNewest`); all work happens off the render thread.
- Crash-safety: PCM is appended to a temp file during capture; on relaunch after crash the
  file is offered for recovery (FR-11.3).
- Every stage records timings into the history row (FR-11.4 debug overlay).

## 3. macOS system integration (the hard-won specifics)

### 3.1 Hotkey — hold-Fn default, Right-⌘ first-class fallback

Research resolved the Fn contradiction definitively (VoiceInk/Handy shipping behavior +
issue-tracker forensics):

- One **CGEventTap**: `.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`, mask
  `keyDown|keyUp|flagsChanged`. Requires **Accessibility permission only** (which also
  covers the paste synthesis; Accessibility implies Input Monitoring — the app never asks
  for IM separately). No IOHIDManager (broken on macOS 15+ for this), no DriverKit.
- Fn detection: edge-detect `flagsChanged` with keyCode 63 + `.maskSecondaryFn`. Never read
  Fn from `CGEventSourceFlagsState` (the flag latches after arrow/F-keys); strip
  `.function` from F-key/arrow events before matching.
- **The Globe system action (emoji picker) cannot be suppressed by the tap** — it fires at
  the IOHID layer. Onboarding must read `com.apple.HIToolbox AppleFnUsageType` and, if ≠0,
  deep-link System Settings → Keyboard for the user to set "Press 🌐 key to: **Do
  Nothing**" (never `defaults write` it ourselves — ignored until re-login). Also surface
  the "press Fn twice = system Dictation" shortcut to disable. M0 runs the one unpublished
  experiment (suppress-and-see) to confirm **[verify]**.
- Press semantics (VoiceInk-proven, unified with FR-1.5): hold ≥0.5 s = push-to-talk
  (release → transcribe); a press <0.5 s is discarded **unless the VAD detected speech**
  during it (then transcribe normally); double-tap = hands-free lock (FR-1.3, with the
  15-min default cap + low-disk guard); any non-modifier keyDown within ~1 s of Fn-down =
  chord → abort-before-start (distinct from cancelling an established recording, which only
  Escape does). 50 ms debounce on systemUptime.
- Tap hygiene: re-enable only from inside the callback on `tapDisabledByTimeout/ByUserInput`;
  emit a synthetic release for a held PTT on any tap interruption; reconcile modifiers from
  `CGEventSourceFlagsState(CombinedSessionState)`; **never poll `CGEventTapIsEnabled`**
  (documented IPC-voucher leak → kernel panic on macOS 26.5.2).
- Modifier-only hotkeys survive secure-input sessions ( `flagsChanged` keeps flowing where
  keyed chords die) — one more reason Fn/Right-⌘ beat ⌥Space.
- External third-party keyboards often handle Fn in firmware (never reaches macOS) —
  detect "Fn never seen while other keys flow" and suggest Right-⌘.

### 3.2 Text insertion — paste-primary tiered ladder

Industry consensus is unanimous (VoiceInk, Handy, Wispr Flow, SpeakType all paste):

1. **Primary — pasteboard + synthesized ⌘V**: snapshot every `NSPasteboardItem`/UTI →
   write transcript marked `org.nspasteboard.TransientType` + `ConcealedType` (clipboard
   managers must ignore it) → ~100 ms → CGEvent ⌘-down/V-down/V-up/⌘-up (0x37/0x09, ~10 ms
   spacing, posted to `cghidEventTap`) → restore snapshot after ≥250 ms **only if** the
   pasteboard still holds our text. Delays configurable (Electron/Java targets need more).
   The HUD panel is `.nonactivatingPanel` so focus never leaves the target app — no
   activate-and-wait sleeps (SpeakType's 850 ms mistake, docs/09).
2. **Fallback — CGEvent Unicode typing** (`keyboardSetUnicodeString`, ≤20 UTF-16-unit
   chunks): for terminals that intercept ⌘V and for "never touch my clipboard" mode
   (FR-3.5). Layout-independent, works for CJK.
3. **Last resort — clipboard + notification** "Copied — ⌘V to paste" (FR-3.4).
4. **AX direct insertion** (`kAXSelectedTextAttribute`): *not* in the ladder for v1 —
   Electron/Chromium breakage is well-documented. Tracked as an optional fast-path
   experiment for known-good native apps (roadmap "Later"). (A *read-only* AX query for the
   preceding character is used by stage 4's spacing logic, with a degraded default when it
   fails — docs/05 §6.)

**Tier selection is configuration-driven, not failure-driven**: a synthesized ⌘V produces
no reliable success signal, so descent through the ladder cannot be detected at runtime.
A per-bundle-ID strategy table ships with sane defaults (terminals → Unicode typing;
Electron apps → paste with longer delays; default → paste) and is user-overridable per app
in Advanced settings. Any runtime detection idea (pasteboard changeCount observation)
is an M0 spike 0.4 experiment, not an assumption.

Pre-flight **at delivery time** (not press — the ~1–3 s gap matters, FR-3.6):
`IsSecureEventInputEnabled()` → if on, block insertion *and persistence* per FR-3.2,
identify the culprit via `kCGSSessionSecureInputPID` for the HUD notice (PID can be wrong
when set by a background app — phrase the UI accordingly). Profile stays pinned from press;
lock-mode deliveries into a different app than at press fall back to clipboard (FR-3.6).

### 3.3 Profile detection

- `NSWorkspace.shared.frontmostApplication` at hotkey-down; observe
  `didActivateApplicationNotification` for the menu-bar status display.
- Browser hostname: per-browser compiled AppleScript via `/usr/bin/osascript` with a
  **1.5 s timeout** (hung browser must not stall dictation). Bundle-ID→dialect table covers
  Safari + the Chromium family (Chrome/Arc/Edge/Brave/Vivaldi/Opera/…). Firefox exposes no
  scriptable tab URL → app-level routing only (documented in FR-8.2). Requires per-browser
  Automation permission; degrade to app-level routing when denied. Reduce to hostname
  immediately; never persist the URL (history stores profile name + route type only).

### 3.4 App shell

- `LSUIElement` accessory app; menu bar via `MenuBarExtra(.window)` **but** settings and
  history windows are AppKit-managed `NSWindow`s (SwiftUI `openSettings` is broken from
  menu-bar apps on macOS 26 **[verify]**).
- HUD: fixed-size borderless `NSPanel` — `.nonactivatingPanel + .fullSizeContentView`,
  `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`,
  `hidesOnDeactivate = false`, content morphs in SwiftUI inside the constant frame
  (SpeakType pattern — animations never clip, panel never steals focus); click-through
  when idle, interactive while recording; position = pure geometry function, re-run on
  screen-parameter changes.
- **Un-sandboxed** (AX control + CGEvent posting are incompatible with App Sandbox);
  launch-at-login via `SMAppService.mainApp`.
- **Signing (the #1 personal-app pitfall)**: TCC keys Accessibility grants to the CDHash of
  ad-hoc-signed builds — every rebuild silently kills the grant. Sign all builds, dev
  included, with a stable Apple Development certificate from day one; dev builds use a
  separate bundle ID (`….dev`) so a debug build never wedges the daily-driver grant;
  `make reset-tcc` wraps `tccutil reset`. No notarization needed (never quarantined).
- Sleep/wake/lock: observe workspace notifications; re-arm the tap and audio engine on
  wake (SpeakType gap, docs/09 §avoid-4).

## 4. Audio pipeline

- `AVAudioEngine.inputNode` tapped at its **native hardware format** (tap format requests
  are ignored; expect ~100 ms callbacks) → `AVAudioConverter` → 16 kHz mono Float32.
  Rebuild the converter on `AVAudioEngineConfigurationChange` (device swap, AirPods).
- `setVoiceProcessingEnabled` **off** (gain drop, aggregate-device bugs; we play no audio
  during capture). System-sound ducking is therefore skipped in v1.
- **Mic policy**: default to built-in mic even when AirPods are connected (Mac BT capture
  degrades system-wide in HFP). iOS 26: opt into
  `AVAudioSession.CategoryOptions.bluetoothHighQualityRecording` (AirPods 4/Pro 2+ get the
  studio-quality link). Mic picker in settings; mid-recording device swap keeps the session.
- **VAD**: FluidAudio Silero v6 CoreML (256 ms hops, ANE). v1 uses: trim leading/trailing
  silence before ASR (anti-hallucination), discard zero-speech takes (FR-1.5), and
  VAD-boundary chunking for long file imports. (Silence auto-stop in lock mode is post-v1 —
  roadmap "Later"; the v1 lock-mode guard is the time cap + low-disk stop, FR-1.3.)
- File import: `AVAudioFile` decodes wav/m4a/mp3/flac/caf; **ogg/opus needs a bundled
  decoder** (libopus). Long files: VAD-boundary chunks with concurrent workers
  (WhisperKit `chunkingStrategy: .vad`), never fixed 30 s windows.
- History audio storage: **Opus-in-CAF 16–24 kbps mono (~7–11 MB/h)**, AAC-LC 32 kbps m4a
  fallback if decode friction appears; per-segment timestamps stored for scrub/replay.

## 5. Persistence

- **GRDB 7 (SQLite)** — SwiftData still lacks FTS. Single database:
  `history`, `history_audio` (file refs), `profiles`, `routes`, `dictionary`, `settings_kv`
  (scalars stay in UserDefaults only when truly trivial), `timings`.
- **Search**: dual FTS5 — `unicode61` index for Latin + **trigram** index for Chinese
  substring search, with a LIKE fallback for 1–2-character CJK queries (AC-7 covers both
  scripts).
- Stats decoupled from content so "delete all history" keeps usage statistics
  (SpeakType idea, docs/09).
- Sync (M8, off by default): Point-Free SQLiteData (GRDB-based, MIT) CloudKit private-DB
  sync — offline-first by construction; requires paid developer account (interview A4).
- Export: JSON (full), Markdown/plain text (selection).

## 6. iOS specifics

- Delivery modes and phasing per docs/02 (D2b handoff confirmed as the design: research
  verified in-keyboard mic recording fails with entitlement errors on current iOS and the
  keyboard jetsam ceiling is ~48–80 MB — no model fits; keyboard = UI + `textDocumentProxy`
  insertion only, ≤40 MB, App Group + Darwin notifications, **Full Access required on
  iOS 26** even to launch the container app).
- Wispr-style **capture session** model: main app arms a background audio session
  (`UIBackgroundModes: audio`) with auto-expiry (5/15/60 min) so the keyboard can trigger
  recording without a foreground bounce after the first arm. There is **no API to return
  the user to the host app** — the one-bounce-per-session friction is real and documented
  in the PRD.
- Lock-screen/Action-Button path: `ControlWidget` + `AudioRecordingIntent` (iOS 18+;
  **must start a Live Activity or recording stops**) → transcribe → auto-copy.
- Compute in background: CPU+ANE only (no Metal — see docs/04); memory budget ~1.5 GB
  resident despite the ~6.1 GB `increased-memory-limit` entitlement ceiling (jetsam favors
  killing big background apps); ship the entitlement anyway for import headroom.
- Cleanup on iOS defaults to Apple FM (out-of-process, background-legal); MLX-in-app is a
  foreground-only option.

## 7. Testing & CI

- **Swift Testing** (parameterized) on the package: golden WAV fixtures per language for
  engine adapters; exact-equality goldens for TextPipeline stages; property tests for
  dictionary invariants (docs/05 §7); a fake `TranscriptionEngine`/`CleanupProvider` for
  deterministic session-actor tests.
- Eval harnesses (`scripts/eval-asr`, `scripts/eval-cleanup`) produce the AC-2/AC-4
  numbers; results committed under `docs/benchmarks/`.
- CI: GitHub Actions `macos-26` (arm64) — `swift test` on DictationCore + one `xcodebuild`
  job per app shell + SwiftLint/swift-format. The network-free integration test (NFR-1)
  runs the pipeline with sockets denied.
- On-device checks that CI can't cover (TCC, hotkey, insertion across real apps) live in a
  scripted manual checklist per milestone gate (roadmap).

## 8. Future-proofing seams (explicit)

1. `TranscriptionEngine` protocol — engines are data-driven registry entries; adding
   sherpa-onnx/Omnilingual (Burmese revival) or replacing WhisperKit touches one target.
2. `CleanupProvider` protocol — on OS 27+ the Apple `LanguageModel` /
   `ChatCompletionsLanguageModel` protocol can unify FM/Ollama/remote behind one adapter
   **[verify at iOS 27 SDK]**.
3. `TextOutputPort` per platform — macOS ladder vs iOS keyboard/clipboard are
   implementations of one interface; a future platform adds a port, not a fork.
4. Language rule files (stages 1/4) and `LanguageMode` cases are additive.
5. Model catalog is a versioned manifest — new model releases are data updates.
6. OS-release checkpoints in the roadmap (Xcode 27 / macOS 27 land mid-project).
