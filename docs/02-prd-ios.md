# PRD — Vocal for iPhone

Owner: Joseph · Status: Draft for review · Platform: iOS (recent iPhone, assumption A3)
Shares `DictationCore` with macOS; implementation notes in `docs/03-architecture.md`.

> **Honest framing.** iOS does not allow the Mac experience ("hold a key in any app, text
> appears in place") to be copied exactly — the OS restricts inter-app control. This PRD
> defines the closest legal-on-iOS equivalents, phased so the highest-certainty path ships
> first. Sections marked ⚠️RESEARCH are finalized against `docs/04` findings.

## 1. Summary

An iPhone dictation app with (a) an instant "dictate → text ready to paste/share" main-app
flow launchable from Action Button / Lock Screen / Control Center, (b) a custom keyboard for
in-place delivery inside other apps, and (c) the same history, dictionary, profiles, and
optional AI cleanup as the Mac — all on-device.

## 2. User stories

- **US-i1**: Walking, I press the Action Button, speak a thought, and the text is on my
  clipboard (and in history) before I've opened the target app.
- **US-i2**: In WeChat, I switch to the Vocal keyboard, tap-hold the mic key, speak Chinese,
  and the text is typed into the chat box — without leaving WeChat.
- **US-i3**: I record a long voicemail-style note; later on my Mac I find it in history
  (if sync milestone M8 is enabled) or AirDrop the transcript.
- **US-i4**: On airplane mode, everything above works identically.
- **US-i5**: I import a WhatsApp voice note via the Share sheet → transcript in seconds.

## 3. Delivery modes (the iOS core problem)

| Mode | How text reaches other apps | Constraints |
|---|---|---|
| **D1 Main-app dictation** (v1, M6) | Auto-copy to clipboard + share sheet + "recent transcripts" widget. Launch via app icon, Action Button (App Intent), Lock Screen widget, Control Center control, Back-Tap | One paste step. Rock-solid: full app resources for ASR + cleanup |
| **D2 Custom keyboard** (M7) | Types directly into the host app's text field via `textDocumentProxy.insertText` | Research resolved (2026-08-16): in-keyboard mic recording is **not reliable** (Apple QA1872 forbids it; current attempts fail with entitlement errors — open bug FB16791704 — despite an Apple-suggested config); keyboard jetsam ceiling ~48–80 MB means **no ASR model fits in-extension**. Design D2b (§3.1) is therefore the architecture; D2a is a feature-flagged progressive enhancement only. iOS 26 requires Full Access even to launch the container app from a keyboard. |
| **D3 Share/Action extension** (M6) | Send audio files/voice notes *into* Vocal from any app's share sheet | Import path, not live dictation |

### 3.1 D2 keyboard — two designs, chosen by research outcome

- **D2b (the architecture — Wispr Flow's own "session" pattern, made offline)**: the
  keyboard is a *delivery + remote-control* surface, never a capture surface. The main app
  arms a time-boxed **capture session** (background audio mode keeps it resident with the
  screen on another app; auto-expiry 5/15/60 min). While a session is armed, the keyboard's
  mic key signals the main app via App Group + Darwin notification — recording and ASR run
  in the main app, the result is written to the App Group, and the keyboard inserts it via
  `textDocumentProxy`. Only when **no** session is armed does the mic key deep-link to the
  container app (allowed; DTS-confirmed) — one bounce per session, and iOS offers no API to
  hop back automatically (system back-arrow; documented friction).
- **D2a (progressive enhancement, feature-flagged)**: direct in-keyboard recording, enabled
  only if a runtime probe succeeds on the installed iOS version. Never load ASR models
  in-extension regardless (memory ceiling).

## 4. Functional requirements

### FR-i1 Capture & transcription
- FR-i1.1 Main app: large push-to-talk button (hold or tap-to-toggle), waveform, live
  elapsed time; on-device EN/ZH transcription with the same language auto-detect/override as
  macOS.
- FR-i1.2 Launchers: App Intent ("Start Dictation") exposed to Shortcuts → Action Button,
  Back Tap, Lock Screen widget, Control Center control. Cold-launch-to-listening ≤ 1.5 s on
  target hardware.
- FR-i1.3 Continue capturing with screen locked / app backgrounded during an active session
  (audio background mode), with Dynamic Island / Live Activity showing recording state.
- FR-i1.4 Model management mirrors macOS (download/verify/delete), with iPhone-appropriate
  model size defaults; storage usage visible in Settings.

### FR-i2 Delivery
- FR-i2.1 On completion in main app: transcript shown full-screen with actions Copy (default,
  auto), Share, Clean up (re-run with profile picker), Delete. Auto-copy toggle in settings
  (default on).
- FR-i2.2 Keyboard (M7): inserts pending/dictated text at cursor via textDocumentProxy;
  respects host-app bundle-ID profile routing; shows a one-line preview before insert with
  ✓/✗ (configurable to auto-insert).
- FR-i2.3 Share extension accepts audio (and video) files and voice memos → import queue.

### FR-i3 Parity features
- FR-i3.1 History: same record shape as macOS (raw + delivered + metadata + optional audio),
  same search (EN + ZH), retention settings; local by default.
- FR-i3.2 Dictionary: same semantics (docs/05 §2); entries editable on phone.
- FR-i3.3 Profiles: same model; routing by host-app bundle ID (keyboard) or manually chosen
  profile (main app); no hostname routing on iOS (documented limitation).
- FR-i3.4 AI cleanup: off by default; providers = **Apple Foundation Models** (default —
  out-of-process, EN/ZH, the only LLM engine documented to work from a backgrounded app),
  optional in-app MLX small model (foreground-only), and OpenAI-compatible remote (incl. the
  Mac serving Ollama over LAN — clearly network-labeled). See docs/04 §4.
- FR-i3.5 Audio file import from Files app and share sheet; long-file chunked transcription
  with progress, Live Activity, and cancel.

### FR-i4 Sync (M8, optional milestone)
- FR-i4.1 CloudKit private-database sync of history, dictionary, profiles between Mac and
  iPhone. Offline-first: every device fully functional without it; sync is eventual, last-
  writer-wins per field, with tombstones for deletes.
- FR-i4.2 Toggle default **off** (pure-offline stance); turning it on shows exactly what data
  goes to the user's private iCloud.

## 5. Non-functional requirements

- **NFR-i1** No telemetry; no network in core path (same test harness as macOS).
- **NFR-i2** A 30 s dictation transcribes in ≤ 5 s on target hardware (model per docs/04);
  thermal soak: 10 consecutive 1-min dictations without thermal throttle failure.
- **NFR-i3** Battery: an average day with ~30 dictations costs ≤ 5% battery attributable to
  the app (measured via Xcode Energy gauges, best-effort).
- **NFR-i4** Storage budget: default model set ≤ 1.5 GB on phone; clear per-model sizes in UI.
- **NFR-i5** All UI usable one-handed; Dynamic Type; VoiceOver.

## 6. Permissions (iOS)

Microphone (first capture); Notifications (optional, import completion); keyboard **Full
Access** — required (iOS 26 mandates it for the keyboard→container-app launch and for App
Group writes; onboarding explains that despite the scary system prompt, the keyboard makes
no network calls — verifiable in code). Speech-recognition permission only if the Apple
Speech adapter requires it at runtime (checked in M0 spike).

## 7. Acceptance criteria (iOS v1 = M6+M7 exit)

1. **AC-i1**: Action Button press → speaking → transcript on clipboard, demonstrated ≤ 4 s
   end-to-end for a 5 s utterance (screen recording + timing log).
2. **AC-i2**: Same 20+20 EN/ZH fixture sets meet the same WER/CER bars as macOS AC-2 on
   device (eval harness runs on-device via test target).
3. **AC-i3**: Keyboard delivery works in Messages, WeChat, Safari form field, Mail (D2b path
   at minimum), with host-app profile routing shown in history log.
4. **AC-i4**: Full flow in Airplane Mode (screen recording).
5. **AC-i5**: Voice-note share-sheet import produces correct transcript in history.
6. **AC-i6**: Lock-screen-continued capture: 3-min dictation with screen locked completes
   with Live Activity state correct throughout.

## 8. Out of scope (iOS v1)

Apple Watch app; iPad-optimized layout (runs, but not optimized); Vision Pro; in-keyboard
partial streaming text; keyboard on iPad hardware keyboards; Burmese (deferred).
