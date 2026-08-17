# Known Gaps (v1) — deliberate, tracked

Deferred with intent after the 2026-08-16 cold review; each names its spec anchor and the
planned resolution. Nothing here is silently missing — the code comments cross-reference
this file.

| # | Gap | Spec | Plan |
|---|---|---|---|
| G1 | Secure-field block persists no anonymous "blocked" event (nothing is stored at all — the stronger privacy reading) | FR-3.2 | Add a `recordBlockedSecureFieldEvent()` seam on TranscriptStoring in M5 polish |
| G2 | HUD streaming partial-text preview is a blank placeholder (committed text is unaffected; transcribe-on-release is the correctness path) | FR-4.1 | Wire `engine.transcribeStream` partials into `hudState.partialText` alongside live waveform levels |
| G3 | Per-profile cleanup `providerOverride` is stored/edited but one pipeline is injected per launch; history records the provider that actually ran | docs/05 §3.2 | Provider-selecting factory in `DictationSession.Dependencies` |
| G4 | Low-disk (<1 GB) recording guard not implemented (the 15-min lock cap is) | FR-1.3 | Free-space check in MicrophoneCapture chunk loop |
| G5 | Escape cannot discard a hands-free (locked) take once the physical press ended — taps finish it, chords/Escape-with-press cancel it | FR-1.6 | Monitor gains a lock-aware Escape path |
| G6 | Repeated-token-loop collapse rebuilds whitespace as single spaces when a loop is found (long-import paragraph breaks lost in that rare case) | FR-6.2 | Range-splice rebuild preserving separators |
| G7 | FTS5 external-content tables key on rowid over a TEXT-PK table; safe today (nothing VACUUMs), corrupts on VACUUM | docs/03 §5 | INTEGER PRIMARY KEY surrogate + FTS rebuild migration |
| G8 | History rows store bundle ID but `targetAppName` stays nil (HistoryView falls back to bundle ID) | FR-5.1 | Resolve via NSRunningApplication at save time |
| G9 | Audio files are not yet retained in history (text + metadata are; retention setting is wired for when persistence lands); cancelled-take 24 h recovery pending same work | FR-5.1/1.6 | Opus/AAC encode of the capture buffer in MicrophoneCapture.finish |
| G10 | ~~iOS app not yet built~~ — built; the *keyboard extension* (docs/02 mode D2) is what remains, main-app dictation with auto-copy delivery ships | docs/02 | Keyboard extension phase |
| G11 | Onboarding hotkey-choice + test-playground pages trimmed to the pragmatic v1 subset | FR-11.1 | M5 polish |
| G12 | `AppleSpeechEngine` does not pass `dictionaryTerms` to `DictationTranscriber.contextualStrings` yet; stage 2 is the backstop either way | docs/04 §3 | Wire contextualStrings in the adapter |
| G13 | **Burmese recognition runs on Whisper, which is poor at it** (80–100% WER). The text layer, detection, dictionary, and formatting are complete; only the engine is not. `availability(for: .burmese)` reports `.readyWithCaveat` and both apps say so plainly via `BurmeseSupportNote` | docs/04 App. A | sherpa-onnx adapter behind `TranscriptionEngine` + the `omni-asr-ctc-*` catalog entries already listed; benchmark FLEURS `my_mm` first — harness: `scripts/burmese_bench/` + the "Burmese ASR benchmark" workflow |
| G15 | The cleanup provider is built once in `AppState.init` from `settings.ollamaModel`, so changing the model in Settings persists but does not take effect until relaunch | docs/05 §3.2 | Same fix as G3 — a provider-selecting factory read per dictation |
| G16 | `AppState.startDictation`'s first-run "downloading the model" hint is set from a Task that can land after the take ends, leaving the text in a hidden HUD; iOS can likewise race `.processing` past the delivered `.result` | FR-2.4/FR-i2.1 | Tag both against a take id and drop stale updates |
| G14 | Zawgyi handling is not shipped at all: the rule-based detector prototype misclassified legitimate Unicode Burmese (မြေပုံ, ငွေကြေး) and real Shan digits, and was removed in the v1.1 review rather than left as dead code | docs/04 App. A | Port google/myanmar-tools (Markov detector + conversion table) when Zawgyi input proves to be a real nuisance |
| G17 | No profile editor exists in either app: `Profile.languageOverride`, `myanmarDigits`, and `myanmarSpokenPunctuation` are engine-complete but unsettable, so the Burmese cleanup opt-in and digit preference are unreachable; profiles are also never persisted (`save(_ profile:)` has no callers) | docs/05 §4 | Profile editor pane — the single unlock for G3, G15, and the Burmese options |
| G18 | Burmese spoken-punctuation command vocabulary needs native-speaker validation: the Myanmar-script commands were removed after review found them byte-identical to ordinary words (ပုဒ်မ = "section"), and the remaining English commands ship disabled | docs/04 App. A | Validate a command vocabulary with a native speaker, then re-enable per profile |
