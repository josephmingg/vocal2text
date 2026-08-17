# ASR Engines & Language Strategy

Distilled from the research fleet run of 2026-08-16 (13 web-research agents; sources at the
bottom of each section's underlying report, preserved in the PR description and session
notes). Facts marked **[verify]** must be confirmed on the target hardware in milestone M0 —
they are load-bearing but come from secondary sources or benchmarks on different machines.

## 1. Decision: engines for v1 (EN + ZH)

### macOS — primary: WhisperKit `large-v3-turbo`

**WhisperKit** (Argmax `argmax-oss-swift`, MIT, v1.1+) running **Whisper large-v3-turbo,
quantized (~626 MB)**:

- One model covers **English + Mandarin including intra-sentence code-switching** — the
  decisive advantage for our bilingual dictation (assumption B6). Apple's engine is
  single-language-per-session; Parakeet v3 has no Chinese at all.
- CoreML/ANE execution; streaming partial results (`AudioStreamTranscriber`) for the HUD
  preview; word timestamps; ~14–18× real-time on recent Apple Silicon **[verify]** →
  a 10 s utterance finalizes well within our 1.5 s budget.
- v1.1 added ~70% peak-memory reduction for long-file transcription — directly serves the
  audio-import requirement (FR-6).
- Model downloaded on first run (resumable, checksum-verified), never bundled.

### macOS — secondary: Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+)

- Locales include `en_*` ×9 and `zh_CN`/`zh_TW`/`zh_HK`/`yue`; benchmark WER 2.12% clean
  LibriSpeech at ~3× Whisper-small speed **[verify — no published Mandarin WER]**.
- Zero model management (OS-managed assets), tiny memory. Ideal "fast path" when the
  utterance language is pinned and no code-switching is expected.
- **Custom-dictionary hook**: only the `DictationTranscriber` module honors
  `AnalysisContext.contextualStrings` (~100-phrase soft cap) and custom LM configs — the
  Apple-path adapter must use DictationTranscriber, not SpeechTranscriber, whenever the
  user dictionary is non-empty. Biasing is a nudge, not a guarantee: our deterministic
  stage-2 replacement (docs/05 §2) stays mandatory on every path.
- Shipped as a second `TranscriptionEngine` adapter; user-selectable per language mode.
  Chinese contextual-biasing quality is unproven — A/B spike in M1 **[verify]**.

### iPhone

- **WhisperKit large-v3-turbo (626 MB)** on iPhone 15 Pro-class and newer (8 GB RAM);
  `whisper-small` (~244 MB) as the low-RAM fallback. Reported ~7× real-time on iPhone
  15 Pro, <4%/hr battery **[verify]**.
- **Apple DictationTranscriber** as the fast path for pinned-language EN/ZH with dictionary
  contextualStrings.
- **Background constraint (verified via Apple DTS statements + whisper.cpp issue reports):**
  background **GPU (Metal) work is banned on all iPhones** through iOS 26.x, and iOS 26.2+
  crashes ggml apps with in-flight GPU work at backgrounding. Therefore the iOS build must
  pin WhisperKit compute units to **CPU+ANE only** (no Metal), keep any MLX inference
  Mac-only, and treat "transcribe while backgrounded/locked" as CPU/ANE-only. iOS 27 SDK
  is expected to require a `continued-processing.inference` entitlement for background ANE —
  revisit at first beta **[verify]**.

### Explicitly not chosen (v1) — and why they stay pluggable

| Engine | Why not v1 | Keep in mind |
|---|---|---|
| sherpa-onnx (Apache-2.0, Swift/SPM) | Extra runtime + model zoo for a need WhisperKit already covers in EN/ZH | The future backbone for: streaming zipformer zh-en **hotword biasing** (dictionary at decode time), SenseVoice zh, and any Burmese revival (see appendix). The `TranscriptionEngine` protocol must not preclude it. |
| Parakeet v3 / FluidAudio ASR | 25 European languages — **no Chinese** | FluidAudio's **Silero VAD v6 CoreML** is still used for VAD (docs/03) |
| Qwen3-ASR (Apache-2.0) | Best open Mandarin WER but no mature Apple-native runtime; streaming needs vLLM | Optional future Mac batch backend for imports |
| Voxtral Mini 4B Realtime | ~4.4 B params — too heavy for iPhone; Mac-only gain unclear | — |
| Moonshine zh | Non-commercial community license; quality tier below turbo | — |
| whisper.cpp | Same models as WhisperKit but more glue for us on Apple platforms | Fallback runtime if WhisperKit regresses; also runs Parakeet since v1.9 |

## 2. Language layer (three languages as of v1.1)

```
LanguageMode = .auto | .english | .chinese | .burmese   // menu-bar quick toggle + per-profile pin
```

- **Auto**: resolved per utterance by `ASRKit.LanguageDetector`. Script in the decoded text
  wins over the engine's reported tag — Myanmar or Han characters are proof, whereas
  Whisper's language ID is a whole-clip guess made before decoding and is routinely wrong on
  short utterances. The reported tag only settles Latin-script languages.
  Wispr Flow's own docs list auto-detect as its top failure mode — so the manual pin is a
  first-class UI element, not buried in settings, and a pin outranks every other signal.
- **Pinned**: passes the language token to Whisper (or selects the Apple-engine locale).
  Pinning also gates language-specific post-processing (docs/05 stage 1/4 rule sets).
- **Chinese specifics**:
  - Script: detect Simplified vs Traditional from output; optional deterministic
    OpenCC-style conversion table (offline) per settings (interview B5).
  - Punctuation: Whisper zh punctuation is inconsistent → stage-4 full-width enforcement
    is always on; cleanup LLM prompt includes the full-width rule.
  - Anti-hallucination (from audio-pipeline research, applies to all Whisper decoding):
    VAD pre-trim; drop zero-speech takes; `condition_on_previous_text=false`;
    temperature ladder 0.0→1.0 step 0.2; `no_speech_threshold` 0.6; `logprob_threshold`
    −1.0; `compression_ratio_threshold` 2.4; canned-phrase blacklist applied only to
    near-silent segments; repetition penalty if zh loops persist.
- **Burmese specifics** (v1.1, appendix A): unspaced script, so it takes the Chinese side of
  every word-boundary decision — phrase-mode dictionary entries, no Latin space hygiene, no
  capitalization. NFC normalization runs before anything matches. Spoken punctuation
  commands supply ။ and ၊ because recognizers do not. Digit set is a per-profile preference.
  Cleanup is off by default: small local models corrupt Burmese rather than tidy it.
- Adding a language later = new enum case + engine adapter + rule files. No pipeline
  changes — verified in practice: Burmese landed in v1.1 without one.

## 3. Custom dictionary ↔ ASR integration points

| Path | Mechanism | Status |
|---|---|---|
| All engines | Deterministic stage-2 replacement (docs/05 §2) | **v1, mandatory backstop** |
| WhisperKit | Prompt-token injection of dictionary terms (Whisper `initial_prompt` biasing) | v1 experiment (M3) — cheap, sometimes effective |
| Apple path | `DictationTranscriber` + `contextualStrings` | v1 on the Apple adapter |
| sherpa zipformer | True decode-time hotword boosting (`term :2.0`) | Future — the reason sherpa stays pluggable |

## 4. Cleanup LLM selection (details in docs/05; sizing here)

| Provider | Model | Where | Notes |
|---|---|---|---|
| Apple Foundation Models | ~3 B on-device (OS-managed) | Mac + iPhone (OS 26+, Apple-Intelligence hardware) | Zero-install default. EN + ZH in its 15 supported languages. 4,096-token context caps a cleanup round at ≈1,500 words. Catch `guardrailViolation` and `unsupportedLanguage` → fall back to raw. Only LLM engine documented to work from a **backgrounded** iOS app. |
| Bundled local (MLX) | Qwen3.5-4B-instruct 4-bit (~2.3 GB) Mac; Qwen3.5-2B iPhone-optional | Mac (iPhone optional, foreground-only) | The "downloadable Local model" of requirement F7. Strongest small-model Chinese. `think:false` equivalent; trimmed ~300-token system prompt keeps Mac latency ≈1–1.3 s **[verify]**. |
| Ollama | any pulled model (suggest `qwen3.5:4b` / `:9b`) | Mac, auto-detected at `localhost:11434` | `keep_alive:-1` + a `max_tokens:1` prewarm fired at hotkey-press so the model is hot before the transcript lands. |
| OpenAI-compatible | user URL+key+model | anywhere (clearly badged "leaves device") | Also covers LM Studio/llama-server/a Mac serving the iPhone over LAN. |

Latency budget math (from research benchmarks **[verify]**): 100-word cleanup with a warm
2B–4B model and ~300-token system prompt ≈ 0.7–1.3 s on M-series — inside the FR-2.5 ≤3 s
target. iPhone 100-word cleanup ≈ 2.5–4 s → default profile on iPhone keeps cleanup off or
uses Apple FM with the "show raw instantly, swap when clean" UX (FR-i2.1 actions).

## 5. Model management

- Storage: `Application Support/<bundle-id>/Models/<engine>/<variant>/` (iOS:
  `isExcludedFromBackup`). Never inside the App Group container (keyboard can't run models).
- Download: resumable background `URLSession` from Hugging Face; SHA-256 manifest checked
  before a variant is marked installed; installed-check also requires expected file set +
  ≥80% expected byte size (SpeakType's truncation guard, docs/09).
- Apple-engine assets are OS-managed via `AssetInventory` — request, don't download.
- Deletion hardening: removals restricted to exact variant directories under our root
  (docs/09 lesson #11), unit-tested.
- Concurrent-load coalescing + RAM check before load (docs/09 lessons).

## 6. Verification checklist for M0 (spike week)

Every **[verify]** above collapses into these bench tasks on the actual target Mac + iPhone:

1. WhisperKit large-v3-turbo: RTF + release→text latency for 10 s/30 s/60 s EN, ZH, and
   mixed utterances; memory high-water mark.
2. Apple SpeechTranscriber zh_CN quality vs turbo on the same fixtures; DictationTranscriber
   contextualStrings effect on 10 planted dictionary terms (EN and ZH).
3. Fn-key CGEventTap observation on macOS 26 + the AppleFnUsageType suppression experiment
   (docs/03 §3).
4. Cleanup: Apple FM vs MLX Qwen3.5-4B vs Ollama on the 60-case eval set; latency each.
5. iPhone: turbo model load time, 30 s-utterance latency, thermal behavior over 10 runs;
   SpeechTranscriber-while-backgrounded validation (gap report flags this as undocumented).

Results get committed to `docs/benchmarks/M0-results.md` — the plan's numbers become
evidence-backed or get revised.

---

## Appendix A — Burmese (v1.1: text layer shipped, recognition pending)

Owner decision 2026-08-16 deferred Burmese out of v1; v1.1 ships the half of it that can be
done well today. The research below is why the split falls where it does — the text layer is
tractable and complete, while recognition quality depends on a model that is not wired yet.

### What v1.1 ships

| Piece | Status | Where |
|---|---|---|
| `Language.burmese` (`my`), pinning, per-utterance auto-detect | Done | `CoreModels`, `ASRKit/LanguageDetector` |
| Script detection (Myanmar + Extended-A/B) | Done | `Unicode.isMyanmarScalar` |
| NFC normalization before anything matches | Done | stage 1 |
| Spoken punctuation ပုဒ်မ/ပုဒ်မကြီး → ။, ပုဒ်ဖြတ်/ပုဒ်မငယ် → ၊ (plus English "full stop"/"comma") | Done | `MyText` |
| Myanmar vs Western digit preference | Done | stage 4, per profile |
| Unspaced-script handling: phrase-mode dictionary, no Latin space hygiene, no capitalization | Done | stages 1/2/4 |
| Zawgyi *detection* for imported dictionary text | Done (heuristic) | `ZawgyiDetector` |
| Zawgyi → Unicode *conversion* | Not shipped | docs/11 G14 |
| Cleanup prompt + validator guards (no translation, no transliteration) | Done | `lang_my.txt`, `OutputValidator` |
| Cleanup off by default for Burmese | Done | `Language.allowsCleanupByDefault` |
| Burmese-capable ASR engine | **Not shipped** — Whisper is used and is poor | docs/11 G13 |

The honest summary shown to users lives in one place, `BurmeseSupportNote`, so both apps say
the same thing.

### Why recognition is the hard half

- **Vanilla Whisper is unusable for Burmese** (~80–100% WER / ~88% CER, hallucination
  loops; 2026 "myMediWhisper" paper puts global commercial models >80% WER). Apple's
  SpeechAnalyzer has no Burmese locale. Fine-tuned Whisper reaches ~23% WER only in a
  narrow domain.
- **The promising path is Meta's Omnilingual ASR (Nov 2025, Apache-2.0)**: 7 B variant
  reports 4.4% CER on Burmese; **sherpa-onnx already ships CTC exports**
  (`omniASR_CTC_1B` int8 for Mac, `omniASR_CTC_300M` int8 ≈ 348 MB for iPhone) with Swift
  API, VAD chunking (<40 s windows), character timestamps. Sub-7B Burmese CER is
  unpublished — a FLEURS `my_mm` benchmark day would be step one.
- Alternative: DataoceanAI **Dolphin** small 0.4 B (Apache-2.0, `my` supported, no English).
- The text-layer requirements this research identified are the ones v1.1 implemented, and
  they were right: Unicode-only with NFC normalization; spoken punctuation commands for
  ၊ (U+104A) and ။ (U+104B) since CTC engines emit none; Myanmar vs Arabic digits as a
  preference; no LLM cleanup by default (small local LLMs corrupt Burmese) — dictionary and
  punctuation commands only. Two are still open: Zawgyi *conversion* (detection ships; the
  google/myanmar-tools table does not — G14), and Mac-only Sailor2-8B via Ollama as an
  opt-in cleanup experiment, which the per-profile Burmese pin now makes reachable.
- Architecture already accommodated it, as designed: v1.1 needed a new `Language` case, a
  Burmese rule file for stages 1/4, and catalog entries — **no pipeline changes**, which is
  the claim §2 makes. The remaining work is the sherpa-onnx adapter behind
  `TranscriptionEngine`.

### Engine status in v1.1

`WhisperKitEngine.availability(for: .burmese)` returns `.readyWithCaveat` rather than
`.ready`: Whisper accepts a `my` token and returns something, so blocking it outright would
remove a path some users still want, but reporting it as ready would promise EN/ZH-grade
accuracy the engine cannot deliver. `AppleSpeechEngine` returns `.unsupported` — there is no
Burmese locale to select.

`ModelCatalog` lists both Omnilingual CTC exports (`omni-asr-ctc-1b-int8` for Mac,
`omni-asr-ctc-300m-int8` for iPhone). The catalog is data, so listing them costs nothing and
`ModelStore` can already track their on-disk footprint; wiring the runtime is G13.

### Measuring it

When the engine lands, measure **CER / syllable error rate, not WER** — the unspaced script
makes WER misleading (49% WER vs 13% CER observed on the same output). Step one is a FLEURS
`my_mm` benchmark day against the 300M and 1B exports.
