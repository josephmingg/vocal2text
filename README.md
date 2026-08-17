# vocal2text — "Vocal"

A personal, fully-offline voice-to-text dictation system for macOS and iPhone, inspired by
Wispr Flow. Hold a hotkey anywhere, speak, release — polished text lands in whatever app has
focus. All speech recognition and AI cleanup runs on-device.

**Status: v1.1.** macOS and iOS apps build and run; the shared engine is covered by tests on
Linux and Apple platforms. Milestones live in [`docs/06-roadmap.md`](docs/06-roadmap.md);
deliberate gaps are tracked in [`docs/11-known-gaps.md`](docs/11-known-gaps.md).

### Languages

| Language | Recognition | Text layer |
|---|---|---|
| English | Whisper large-v3-turbo | Full |
| 中文 (Simplified) | Whisper large-v3-turbo | Full |
| မြန်မာ (Burmese) — **new in 1.1** | Whisper, **poor quality** (see below) | Core (see below) |

Burmese ships with an uneven story, stated plainly rather than papered over. Working today:
Unicode NFC normalization, per-utterance script detection, and the custom dictionary in
phrase mode. In the engine but dormant: a Myanmar/Western digit preference and spoken
punctuation, both awaiting a profile editor (docs/11 G17) — and the spoken-command
vocabulary additionally needs native-speaker validation before it can ship on (G18).
Recognition: on the Mac, pinning မြန်မာ routes to a dedicated Burmese engine — Meta's
Omnilingual ASR via sherpa-onnx, measured at 10.78% CER on FLEURS `my_mm`
(docs/benchmarks) — with a ~790 MB first-use download. Auto-detect and iPhone still fall
to Whisper, which transcribes Burmese at 80–100% WER (G13). AI cleanup is off for Burmese
because small local models corrupt it.
See [`docs/04` Appendix A](docs/04-asr-engines-and-languages.md).

## Core loop

```
hold hotkey ──▶ speak ──▶ release
                             │
            on-device ASR (EN/ZH/MY)
                             │
        custom dictionary overrides
                             │
     optional local AI cleanup (per-app profile)
                             │
      text inserted into the focused app
                             │
            saved to local history
```

## Documentation

| Doc | Contents |
|---|---|
| [00 · Product overview](docs/00-product-overview.md) | Vision, scope, principles, feature list |
| [01 · macOS PRD](docs/01-prd-macos.md) | Full product requirements: macOS menu-bar app |
| [02 · iOS PRD](docs/02-prd-ios.md) | Full product requirements: iPhone app + keyboard |
| [03 · Architecture](docs/03-architecture.md) | Tech stack, shared core, data model, pipeline |
| [04 · ASR engines & languages](docs/04-asr-engines-and-languages.md) | Engine selection, EN/ZH strategy, Burmese appendix (v1.1) |
| [05 · AI cleanup & profiles](docs/05-ai-cleanup-and-profiles.md) | Cleanup pipeline, profiles, dictionary, style prompts |
| [06 · Roadmap](docs/06-roadmap.md) | Milestones with acceptance criteria |
| [07 · Risks](docs/07-risks.md) | Risk register |
| [08 · Interview questions](docs/08-interview-questions.md) | Open questions for the product owner |
| [09 · Reference codebases](docs/09-reference-codebases.md) | Learnings from SpeakType, VoiceInk, Handy |
| [10 · Running on your Mac](docs/10-running-on-your-mac.md) | Build, install, and grant permissions |
| [11 · Known gaps](docs/11-known-gaps.md) | Deliberate, tracked omissions |

## Ground rules

- **Offline by default.** No network calls in the core dictation path, ever.
- **Personal use.** One user, personally signed builds, no App Store, no telemetry.
- **Languages:** English + Mandarin Chinese since v1; Burmese added in v1.1 through the
  pluggable language layer — additive branches in the shared pipeline stages, no
  architectural change.
- **Clean code.** Protocol-boundaried modules, testable pure pipeline, evidence-backed "done".
