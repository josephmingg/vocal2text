# Stage-3 cleanup eval set

The ~60 curated transcripts docs/05 §7 calls for, and the harness that scores them.
Feeds **AC-4** (docs/01): the set must pass ≥ 90% of hard-rule checks with the default
prompt before cleanup is considered shipped.

## Running it

Needs a model serving locally — this is not part of `make test`, which stays hermetic.

```sh
brew install ollama && ollama serve
ollama pull qwen2.5:3b-instruct

make eval-cleanup                              # default model, writes docs/benchmarks/
make eval-cleanup MODEL=qwen3:4b-instruct      # compare models
swift run eval-cleanup --category self-correction --verbose
swift run eval-cleanup --language zh
```

Exit code is non-zero when the hard-rule pass rate falls under 90%, so a prompt change
can be gated the way a test would be.

## What a "pass" means

A case passes only when all three hold:

1. the provider answered within the timeout,
2. the shipping `OutputValidator` **accepted** the output, and
3. every hard rule held.

Point 2 is the one worth dwelling on. When the validator rejects, the app silently
delivers the stage-2 text instead (FR-7.3) — the user sees no error, just cleanup
quietly doing nothing. The eval has to be the thing that notices, so a rejection is
scored as a failure even if every other rule passed.

Edit distance to the reference is **reported, never scored**. Several wordings are
legitimately correct, and a threshold there would make the harness argue with itself.

## Adding a case

One JSON file per category. Keep `id` stable when editing a case, or the report diff
stops being readable.

```json
{
  "id": "en-corr-011",
  "category": "self-correction",
  "language": "en",
  "input": "stage-2 text, as the pipeline would hand it to the provider",
  "reference": "what a good cleanup looks like",
  "profilePrompt": "",
  "stylePrompt": "",
  "protectedTerms": ["kubectl"],
  "rules": [{ "kind": "mustContain", "values": ["…"] }],
  "note": "why this case exists"
}
```

Four rule kinds, deliberately few — a rule a human has to interpret scores differently
on different days, and AC-4 is only meaningful if the checks are exact:

| kind | meaning |
|---|---|
| `mustContain` | every value appears (word-boundary aware for Latin, substring for Han/Myanmar) |
| `mustNotContain` | no value appears |
| `preservesTerms` | the shipping `ProtectedTermsVerifier` accepts the output |
| `maxWords` | word count within `limit` (Han counted per character) |

## Categories

| Category | Pins |
|---|---|
| `fillers` | um/uh/like/那个 removal without losing content |
| `self-correction` | "Friday sorry Saturday", 「不对」 — plus controls where the marker is content |
| `questions-not-answered` | the transcript is data, not a request; includes a prompt-injection case |
| `protected-terms` | dictionary written forms survive stage 3 |
| `code-switching` | embedded English stays English |
| `zh-punctuation` | full-width enforcement is not undone |
| `style-british` / `style-banned-words` / `style-ignored` | AC-11: the style prompt reaches the model, and the opt-out profile really opts out |

## Trusting the numbers

The scoring is unit-tested (`Tests/CleanupEvalTests`) and runs on Linux CI without a
model. The provider call cannot be tested without one — so what CI proves is that the
instrument measures correctly, not that any particular model passes.
