# MVP Cold Review — English dictation and auto-cleanup (2026-09-25)

An outside review of the dictation path from start to finish (capture → Whisper → stages 1–4 →
delivery), focused on English accuracy and the "auto clean" feature. It was done against
v0.1.1 and then re-checked against `main` after the docs/15 improvement plan (#27–#29)
landed. That plan had already fixed several of the same findings independently. This page
lists only what was still open on `main` and is fixed on this branch, plus what remains.

## Already fixed on main (confirmed, not changed here)

VAD trimming and the no-speech gate (Silero, step 16) · dictionary terms as Whisper prompt
tokens (step 24) · AX caret read plus last-insert fallback for smart spacing (step 29) ·
the deterministic cleanup-skip heuristic (step 20) · validator meta-marker false positives
("Sure…", 「好的…」) · per-take provider selection (G3).

## Fixed on this branch

| # | Finding on main | Impact | Fix |
|---|---|---|---|
| R1 | **Pinned language ignored on most takes.** `usePrefillPrompt = false` unless dictionary bias terms exist, and WhisperKit only forces the language token when prefill is on. Pinning EN with an empty dictionary let Whisper choose any language; the result was then *labelled* EN. | Wrong-language or translated output on short or accented takes, which is exactly when users pin | Prefill always on; `detectLanguage` is explicit (auto only) |
| R2 | **Auto mode can pick a third language.** Whisper detects 99 languages; English misread as `nl`/`cy`, or Mandarin as `ja`, is then decoded *as* that language. | Occasional garbled or translated output | An unsupported detection gets one re-decode pinned to ZH (for `ja`/`yue`/`wuu` or Han text) or EN |
| R3 | **No filler removal without the LLM.** "Um", "uh", "I I think" and "the the" survive whenever stage 3 is off (the default), unavailable, or skipped. | The core "clean text" promise fails out of the box | `EnglishCleanup` in stage 1: fillers (um/uh/er/erm/hmm/ah) and stuttered function words. Conservative: `uh-huh`, `mhm`, "that that", "had had", "very very" untouched; verbatim profiles skip it. It also lets the skip heuristic avoid a model round trip on takes whose only issue was an "um" |
| R4 | **Empty takes are delivered and saved.** A transcript that normalizes to "" (`[BLANK_AUDIO]`, a lone "Um.") still pastes an empty string and writes an empty history row. | Junk history rows and pointless pastes | Treated like VAD "no speech": nothing is delivered or saved |
| R5 | **Answers that keep the length pass the validator.** The ratio floor catches "Paris" but not "The capital of France is Paris.". | The model's words are pasted instead of the user's | `answered-question` rule (the question mark disappeared) and `rewrite` rule (>50% new words; space-separated scripts only) |
| R6 | **LLM packaging leaks into output.** Small models echo the `<TRANSCRIPT>` fence or wrap the answer in quotes. | Tags or quotes pasted into documents | Stripped (a single wrapping pair only, and never when the speaker's own text opens with a quote) |
| R7 | **AI cleanup did nothing without Ollama on Mac.** `FoundationModelsProvider` exists but was never selected. | Turning cleanup on without Ollama silently delivered raw text on every take | `selectCleanup` uses Apple's on-device model when a profile pins it or Ollama isn't answering. The Ollama probe runs only where the Apple model exists, so older Macs keep the probe-free path. History records the provider that actually ran |
| R8 | **No cleanup at all on iPhone.** | — | Apple's on-device model is wired on iOS 26. Settings shows the switch only where it can run (keeps the W16 truth-pass rule) |
| R9 | **Prompt and temperature.** Temperature 0.2 adds run-to-run variance to a transform task; the prompt didn't say a question stays a question, or what to do with already-clean text. | Inconsistent cleanup | Temperature 0; those rules added. Few-shot examples were deliberately *not* added: `PromptDoesNotQuoteTheEvalSetTests` protects eval integrity |

## Remaining weaknesses, by priority

1. **Real-audio verification.** R1/R2 change decoding options. They were checked against the
   WhisperKit source, but WER and latency need a vocal-bench run on the owner's Mac. Watch
   for Whisper echoing prompt terms on near-silent takes; the VAD gate should prevent it.
2. **Ollama `keep_alive` and cold starts** (docs/15 step 19). The first cleanup after 5
   idle minutes can exceed the 6 s budget and silently fall back.
3. **Reasoning-model latency.** Qwen3-class models think by default; send
   `think: false` / `/no_think` for known families.
4. **Master switch ships OFF** (FR-7.1). With the Apple fallback in place, consider
   defaulting it ON on Apple-Intelligence machines.
5. **Mid-sentence continuation casing.** A take that continues a sentence keeps its capital
   letter. A small safe-list (the, a, and, but, so…) would cover most cases without touching
   "I" or names.
6. **Messages profile terminal period.** Stage 1 adds a period to 3+ word takes, which
   conflicts with the Messages prompt when cleanup is off.
7. **"Scratch that" when stated as its own sentence** could be resolved deterministically,
   like the layout commands. It stays with the model per the docs/15 plan; revisit if
   cleanup-off users ask for it.

## Self-review and QA of this branch

An adversarial pass over this branch's own changes found four bugs, all fixed before merge:

| Bug found | Example | Fix |
|---|---|---|
| Acronyms and names that spell a filler were deleted | "She's in the **ER** now" → "She's in the now"; also UH, UM, HMM, "the Er river" | Fillers match case-sensitively: lowercase anywhere, capitalised only at a sentence start, never all-caps |
| Two-word interjections lost their first word | "Uh oh, the build broke" → "Oh, …"; "Uh huh" → "Huh" | "uh" followed by "oh"/"huh" is left alone |
| "ah" treated as a filler | "Ah, I see what you mean" → "I see what you mean" | Removed; the filler list now matches the prompt's and `CleanupSkipHeuristic`'s |
| Expressive doubles collapsed | "so so", "he he", "my my" | Removed from the stutter list |

Regression checks added or run:
- `ValidatorAcceptsEvalReferencesTests`: all 62 curated references in `evals/cleanup` pass the
  validator, so no rule (including the new `answered-question` / `rewrite` rules) rejects a
  known-good cleanup.
- All 41 English references pass through `EnglishCleanup` unchanged, so clean text is never
  altered.

Known limitations, accepted:
- The `rewrite` rule also rejects a user profile that *asks* for translation between two
  Latin-script languages (EN→ES). Main's `language-mismatch` rule already rejects EN↔ZH and
  EN↔MY translation, so translation was not a working feature before this branch either.
- `answered-question` falls back to the raw text when a self-correction legitimately drops the
  question ("Can we meet Friday? Sorry, no, let's do Saturday."). That is the safe direction:
  the user gets their own words.
- The always-on Whisper prefill (R1) replaces a setting that dates from the first commit and
  never had a stated reason. It is standard Whisper decoding, but it changes every Whisper take
  and **must be checked with vocal-bench on real audio before merging**.
- On macOS 26 machines, the Apple fallback probes Ollama once per cleaned take (≤2 s timeout).
  That is instant on localhost; a slow *remote* Ollama URL would add latency.
