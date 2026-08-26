# Benchmarks — the M0 evidence harness

This directory holds committed benchmark results (`M0-results.md` and later
runs). The harness itself is the `vocal-bench` SwiftPM executable — Phase 0.2
of docs/14, paying down the docs/06 M0 debt: every latency/WER claim gets a
measured number on the actual hardware.

## 1. Record fixtures

Fixtures live in `Benchmarks/fixtures/` as `<name>.wav` plus an optional
`<name>.txt` reference transcript (enables WER for English / CER for 中文).
Audio files are gitignored — they are your voice; only reference texts and
results are committed.

Suggested set (docs/06 spike 0.1): 10 s / 30 s / 60 s utterances in EN, ZH,
and mixed code-switching — e.g. `en-10s.wav`, `zh-30s.wav`, `mixed-60s.wav`.
Record with any tool (QuickTime, Voice Memos), then convert to what the
engine consumes (16 kHz mono PCM):

```sh
# macOS built-in:
afconvert -f WAVE -d LEI16@16000 -c 1 input.m4a Benchmarks/fixtures/en-10s.wav
# or ffmpeg:
ffmpeg -i input.m4a -ar 16000 -ac 1 -sample_fmt s16 Benchmarks/fixtures/en-10s.wav
```

Write the exact words you spoke into `Benchmarks/fixtures/en-10s.txt`.

## 2. Run

```sh
swift run -c release vocal-bench Benchmarks/fixtures \
    --runs 3 --output docs/benchmarks/M0-results.md
```

Flags: `--language auto|en|zh` (default auto), `--model NAME` (default
large-v3-turbo), `--runs N` (default 3). The first run downloads and compiles
the model; the reported load time reflects a warm start once cached.

## 3. What the report contains

- Model load / warm-up seconds (the cost the preload work in Phase 2 removes
  from the first dictation).
- Per fixture: transcribe p50/p95, real-time factor, text-pipeline p50, and
  WER (word, EN) or CER (character, ZH) against the reference.
- Overall p50/p95 across all measurements, and process memory footprint.
- The produced transcripts, so accuracy regressions are reviewable in diffs.

Commit the generated markdown; the Phase 2 speed work (preload, Parakeet,
quantized variants, VAD trimming) is judged against these numbers.
