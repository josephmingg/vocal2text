# Burmese ASR benchmark — FLEURS `my_mm` (2026-08-17)

The G13 decision data. Run: [Actions run 32020960391](https://github.com/josephmingg/vocal2text/actions/runs/32020960391),
commit `ba98476`, harness `scripts/burmese_bench/`. 250 utterances of the
FLEURS `my_mm` test split (880 total), 3 810 s of audio, greedy CTC decoding,
ubuntu-latest 4-vCPU runner.

## Results

| model | CER | syllable ER | RTF (CPU) |
|---|---|---|---|
| omnilingual-asr-ctc-**300M**-int8 (iPhone tier, ~293 MB) | **15.19%** | 31.94% | 0.205 |
| omnilingual-asr-ctc-**1B**-int8 (Mac tier, ~786 MB) | **10.78%** | 22.42% | 0.513 |

CER converged steadily across the 250 utterances (300M: 17.0% → 15.2%;
1B: 12.1% → 10.8%), so these are stable estimates, not small-sample noise.
Exact assets: `sherpa-onnx-omnilingual-asr-1600-languages-{300M,1B}-ctc-int8-2025-11-12`
from the k2-fsa/sherpa-onnx `asr-models` release.

## Reading

- **Versus the status quo:** Whisper on Burmese is 80–100% WER-class with
  hallucination loops (docs/04 Appendix A). 10.8% CER is a different world —
  usable dictation with occasional corrections, in line with the 7B model's
  published 4.4% CER scaled down.
- **Error texture** (from the hypothesis dumps): real Burmese with local
  errors — dropped tone marks (ကျိန် → ကျိမ်), syllable confusions
  (ယာယီ → ရာယီ), and notably **dropped Myanmar numerals** (၂၉, ၁၅ vanish) —
  numbers are the weakest category. No punctuation is emitted at all, as
  predicted; the stage-1 terminal-mark rule and (future) spoken punctuation
  carry that load.
- **Latency:** RTF 0.51 for 1B on weak CPU cores means a 10 s utterance
  decodes in ~5 s there; Apple-silicon performance cores should land well
  under transcribe-on-release tolerance. Needs measuring on-device (M0-style
  spike) before the iPhone call.

## Decision (per the harness README's table)

- **GO on the Omnilingual path.** 1B is clearly good enough for the Mac.
- **300M sits exactly at the ≤15% line** with a rough 32% syllable ER:
  ship Mac-first with 1B; decide iPhone (300M vs nothing) after on-device
  RTF/memory measurement, keeping the accuracy caveat visible either way.
- Dolphin evaluation not needed unless on-device latency surprises.

Next step: the sherpa-onnx adapter behind `TranscriptionEngine` (G13),
Mac/1B first.
