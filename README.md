# vocal2text — "Vocal"

A personal, fully-offline voice-to-text dictation system for macOS and iPhone, inspired by
Wispr Flow. Hold a hotkey anywhere, speak in English or Chinese, release — polished text lands
in whatever app has focus. All speech recognition and AI cleanup runs on-device.

**Status: planning.** This repository currently contains the product requirements and
technical plan. Implementation milestones are defined in [`docs/06-roadmap.md`](docs/06-roadmap.md).

## Core loop

```
hold hotkey ──▶ speak ──▶ release
                             │
              on-device ASR (EN/ZH)
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
| [04 · ASR engines & languages](docs/04-asr-engines-and-languages.md) | Engine selection, EN/ZH strategy, Burmese appendix (deferred) |
| [05 · AI cleanup & profiles](docs/05-ai-cleanup-and-profiles.md) | Cleanup pipeline, profiles, dictionary, style prompts |
| [06 · Roadmap](docs/06-roadmap.md) | Milestones with acceptance criteria |
| [07 · Risks](docs/07-risks.md) | Risk register |
| [08 · Interview questions](docs/08-interview-questions.md) | Open questions for the product owner |

## Ground rules

- **Offline by default.** No network calls in the core dictation path, ever.
- **Personal use.** One user, personally signed builds, no App Store, no telemetry.
- **v1 languages:** English + Mandarin Chinese. Burmese deferred (pluggable language layer).
- **Clean code.** Protocol-boundaried modules, testable pure pipeline, evidence-backed "done".
