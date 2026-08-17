# Burmese ASR benchmark (docs/11 G13)

Answers the question docs/04 Appendix A says must be answered before any
engine integration: **are the sherpa-onnx Omnilingual ASR CTC exports good
enough to be Vocal's Burmese engine?** The 7B model reports 4.4% CER on
Burmese; the 300M (iPhone-tier) and 1B (Mac-tier) exports are unpublished —
this measures them on the FLEURS `my_mm` test split.

Run it from the Actions tab ("Burmese ASR benchmark" → Run workflow), or push
a change under `scripts/burmese_bench/`. It does not run on ordinary pushes.

**CER is the decision metric** — the unspaced script makes WER misleading
(docs/04: 49% WER vs 13% CER observed on the same output). Syllable error
rate (sylbreak segmentation) is secondary; real-time factor on the runner's
CPU gives a latency sanity check (Apple-silicon RTF will be better).

Reading the result:

| Outcome | Decision |
|---|---|
| 300M CER roughly ≤ 15% | Wire the sherpa-onnx adapter for Mac **and** iPhone |
| Only 1B acceptable | Mac gets the engine first; iPhone stays on the caveat |
| Both ≫ 20% | Omnilingual path fails — evaluate Dolphin (`from_dolphin_ctc` exists in the same runtime) before writing any adapter |

Model assets are resolved at runtime (GitHub release listing, HF hub search
fallback) rather than hardcoded, and every failure path prints what it saw —
the harness was authored from a sandbox that cannot reach either host.
