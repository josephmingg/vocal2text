#!/usr/bin/env python3
"""FLEURS my_mm benchmark for candidate Burmese ASR engines (docs/11 G13).

Decides whether the sherpa-onnx Omnilingual ASR CTC exports are good enough
to become Vocal's Burmese engine — the question docs/04 Appendix A says must
be answered before any integration work. Runs on a GitHub Actions runner
(open network); the dev sandbox cannot reach huggingface.co or foreign
GitHub releases, so this is CI-hosted by design.

Metrics, per docs/04 Appendix A: **CER is primary** — the unspaced script
makes WER misleading (49% WER vs 13% CER observed on the same output).
Syllable error rate (sylbreak segmentation) is secondary; whitespace WER is
reported for reference only.

Every failure path prints the evidence needed to fix it remotely (asset
lists, file trees), because this script's author cannot run it locally.
"""

import json
import os
import re
import sys
import tarfile
import time
import unicodedata
import urllib.request
from pathlib import Path

WORK = Path(os.environ.get("BENCH_WORK", "bench-work"))
RESULTS = Path(os.environ.get("BENCH_RESULTS", "results"))
MAX_UTTS = int(os.environ.get("MAX_UTTS", "250"))
MODELS = [m.strip() for m in os.environ.get("MODELS", "300m,1b").split(",") if m.strip()]
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")

FLEURS_BASE = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/my_mm"


def log(msg: str) -> None:
    print(msg, flush=True)


def fetch(url: str, dest: Path, headers: dict | None = None) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        log(f"  cached: {dest}")
        return dest
    log(f"  GET {url}")
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=600) as response, open(dest, "wb") as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)
    log(f"  -> {dest} ({dest.stat().st_size / 1e6:.1f} MB)")
    return dest


def api_json(url: str) -> object:
    headers = {"Accept": "application/vnd.github+json"}
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


# ── Model resolution ─────────────────────────────────────────────────────────
# Asset names are resolved at runtime rather than hardcoded: the author could
# not browse k2-fsa/sherpa-onnx from the sandbox, so the script discovers the
# omnilingual assets itself and prints what it saw when it cannot.


def resolve_model_from_github(size: str) -> str | None:
    """URL of the omnilingual CTC archive for `size` from sherpa-onnx releases."""
    assets: list[dict] = []
    page = 1
    while True:
        batch = api_json(
            "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/asr-models"
            f"?per_page=100&page={page}"
            if page == 1
            else f"https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/asr-models"
        )
        release_assets = batch.get("assets", [])
        # The tag endpoint returns up to 100 assets per page via assets_url.
        assets_url = batch.get("assets_url")
        if assets_url:
            page_number = 1
            assets = []
            while True:
                chunk = api_json(f"{assets_url}?per_page=100&page={page_number}")
                if not chunk:
                    break
                assets.extend(chunk)
                page_number += 1
            break
        assets.extend(release_assets)
        break

    def match(name: str) -> bool:
        lowered = name.lower()
        return (
            "omni" in lowered
            and size in lowered
            and "int8" in lowered
            and (lowered.endswith(".tar.bz2") or lowered.endswith(".tar.gz"))
        )

    for asset in assets:
        if match(asset["name"]):
            log(f"  matched GitHub asset: {asset['name']}")
            return asset["browser_download_url"]
    log(f"  no GitHub asset matched omni/{size}/int8. Assets containing 'omni':")
    for asset in assets:
        if "omni" in asset["name"].lower():
            log(f"    {asset['name']}")
    return None


def resolve_model_from_hf(size: str) -> str | None:
    """Fallback: search the HF hub for a sherpa-onnx omnilingual export."""
    url = "https://huggingface.co/api/models?search=sherpa-onnx%20omnilingual&limit=50"
    try:
        models = api_json(url)
    except Exception as error:  # noqa: BLE001 - report and move on
        log(f"  HF search failed: {error}")
        return None
    for model in models:
        model_id = model.get("modelId", model.get("id", ""))
        lowered = model_id.lower()
        if "omni" in lowered and size in lowered and "int8" in lowered:
            log(f"  matched HF repo: {model_id}")
            return f"hf:{model_id}"
    log("  no HF repo matched. Candidates seen:")
    for model in models:
        log(f"    {model.get('modelId', model.get('id'))}")
    return None


def download_and_extract_model(size: str) -> Path:
    target = WORK / f"model-{size}"
    if target.exists() and list(target.rglob("*.onnx")):
        return target
    source = resolve_model_from_github(size) or resolve_model_from_hf(size)
    if source is None:
        raise SystemExit(f"FATAL: could not locate an omnilingual {size} int8 export anywhere")
    if source.startswith("hf:"):
        repo = source[3:]
        tree = api_json(f"https://huggingface.co/api/models/{repo}/tree/main")
        target.mkdir(parents=True, exist_ok=True)
        for entry in tree:
            name = entry["path"]
            if name.endswith((".onnx", ".txt")):
                fetch(f"https://huggingface.co/{repo}/resolve/main/{name}", target / name)
    else:
        archive = fetch(source, WORK / Path(source).name)
        log(f"  extracting {archive.name}")
        with tarfile.open(archive) as tar:
            tar.extractall(target)
    return target


def find_model_files(model_dir: Path) -> tuple[str, str]:
    onnx_files = sorted(model_dir.rglob("*.onnx"), key=lambda p: p.stat().st_size)
    tokens_files = list(model_dir.rglob("tokens.txt"))
    if not onnx_files or not tokens_files:
        log(f"FATAL: expected .onnx + tokens.txt under {model_dir}. Tree:")
        for path in sorted(model_dir.rglob("*")):
            log(f"    {path}")
        raise SystemExit(1)
    # Largest .onnx is the model proper (small ones are preprocessor sidecars).
    return str(onnx_files[-1]), str(tokens_files[0])


# ── FLEURS my_mm ─────────────────────────────────────────────────────────────


def download_fleurs() -> list[tuple[Path, str]]:
    """Returns [(wav_path, reference_text)] for the my_mm test split."""
    tsv = fetch(f"{FLEURS_BASE}/test.tsv", WORK / "fleurs" / "test.tsv")
    audio_dir = WORK / "fleurs" / "audio"
    if not audio_dir.exists():
        archive = fetch(f"{FLEURS_BASE}/audio/test.tar.gz", WORK / "fleurs" / "test.tar.gz")
        with tarfile.open(archive) as tar:
            tar.extractall(audio_dir)
    wav_by_name = {p.name: p for p in audio_dir.rglob("*.wav")}
    pairs: list[tuple[Path, str]] = []
    with open(tsv, encoding="utf-8") as handle:
        for line in handle:
            columns = line.rstrip("\n").split("\t")
            if len(columns) < 4:
                continue
            filename, raw_transcription, transcription = columns[1], columns[2], columns[3]
            reference = raw_transcription.strip() or transcription.strip()
            wav = wav_by_name.get(filename)
            if wav is not None and reference:
                pairs.append((wav, reference))
    if not pairs:
        log("FATAL: no (wav, reference) pairs. TSV head + audio tree follow:")
        log(open(tsv, encoding="utf-8").read()[:2000])
        for path in list(audio_dir.rglob("*"))[:20]:
            log(f"    {path}")
        raise SystemExit(1)
    log(f"FLEURS my_mm test: {len(pairs)} utterances (using up to {MAX_UTTS})")
    return pairs[:MAX_UTTS]


# ── Scoring ──────────────────────────────────────────────────────────────────


def normalized(text: str) -> str:
    """NFC, punctuation/symbols/whitespace stripped, Latin lowercased."""
    text = unicodedata.normalize("NFC", text).lower()
    return "".join(
        ch
        for ch in text
        if not ch.isspace() and not unicodedata.category(ch).startswith(("P", "S"))
    )


# Burmese syllable segmentation in the spirit of Ye Kyaw Thu's sylbreak:
# break before a consonant that is neither stacked (preceded by U+1039) nor
# killed (followed by asat U+103A / stack U+1039); digits break singly.
SYLLABLE_BREAK = re.compile(r"(?<!္)([က-အ၀-၉])(?![်္])")


def syllables(text: str) -> list[str]:
    # "|" cannot survive normalized() — category Sm is stripped there — so it
    # is a safe separator to inject into already-normalized text.
    marked = SYLLABLE_BREAK.sub(r"|\1", text)
    return [s for s in marked.split("|") if s]


def edit_distance(a: list, b: list) -> int:
    if not a:
        return len(b)
    previous = list(range(len(b) + 1))
    for i, item_a in enumerate(a, 1):
        current = [i] + [0] * len(b)
        for j, item_b in enumerate(b, 1):
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (item_a != item_b),
            )
        previous = current
    return previous[-1]


# ── Benchmark ────────────────────────────────────────────────────────────────


def run_model(size: str, pairs: list[tuple[Path, str]]) -> dict:
    import numpy as np
    import sherpa_onnx
    import soundfile

    model_dir = download_and_extract_model(size)
    model, tokens = find_model_files(model_dir)
    log(f"[{size}] model={model}")
    recognizer = sherpa_onnx.OfflineRecognizer.from_omnilingual_asr_ctc(
        model=model, tokens=tokens, num_threads=os.cpu_count() or 4
    )

    char_errors = char_total = 0
    syllable_errors = syllable_total = 0
    audio_seconds = 0.0
    decode_seconds = 0.0
    samples_dump: list[dict] = []

    for index, (wav, reference) in enumerate(pairs):
        audio, sample_rate = soundfile.read(wav, dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        audio_seconds += len(audio) / sample_rate
        started = time.monotonic()
        stream = recognizer.create_stream()
        stream.accept_waveform(sample_rate, np.ascontiguousarray(audio))
        recognizer.decode_stream(stream)
        decode_seconds += time.monotonic() - started
        hypothesis = stream.result.text

        ref_norm, hyp_norm = normalized(reference), normalized(hypothesis)
        char_errors += edit_distance(list(hyp_norm), list(ref_norm))
        char_total += len(ref_norm)
        syllable_errors += edit_distance(syllables(hyp_norm), syllables(ref_norm))
        syllable_total += len(syllables(ref_norm))
        if index < 10:
            samples_dump.append({"ref": reference, "hyp": hypothesis})
        if (index + 1) % 50 == 0:
            log(f"[{size}] {index + 1}/{len(pairs)} CER so far: {char_errors / max(char_total, 1):.3f}")

    return {
        "model": f"omnilingual-asr-ctc-{size}-int8",
        "utterances": len(pairs),
        "audio_seconds": round(audio_seconds, 1),
        "cer": round(char_errors / max(char_total, 1), 4),
        "syllable_er": round(syllable_errors / max(syllable_total, 1), 4),
        "rtf": round(decode_seconds / max(audio_seconds, 1e-9), 3),
        "samples": samples_dump,
    }


def main() -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    pairs = download_fleurs()
    results = []
    for size in MODELS:
        try:
            results.append(run_model(size, pairs))
        except SystemExit:
            raise
        except Exception as error:  # noqa: BLE001 - keep other sizes running
            log(f"[{size}] FAILED: {error!r}")
            results.append({"model": f"omnilingual-asr-ctc-{size}-int8", "error": repr(error)})

    (RESULTS / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))

    lines = [
        "# FLEURS my_mm — Burmese ASR benchmark (G13)",
        "",
        "CER is the decision metric (docs/04 Appendix A). Reference: Omnilingual 7B",
        "reports 4.4% CER on Burmese; Whisper is 80–100% WER-class.",
        "",
        "| model | utts | audio (s) | CER | syllable ER | RTF (CPU) |",
        "|---|---|---|---|---|---|",
    ]
    for result in results:
        if "error" in result:
            lines.append(f"| {result['model']} | — | — | FAILED: {result['error']} | — | — |")
        else:
            lines.append(
                f"| {result['model']} | {result['utterances']} | {result['audio_seconds']} "
                f"| {result['cer']:.2%} | {result['syllable_er']:.2%} | {result['rtf']} |"
            )
    lines += ["", "First hypotheses vs references:", ""]
    for result in results:
        for sample in result.get("samples", [])[:5]:
            lines += [f"- ref: {sample['ref']}", f"  hyp: {sample['hyp']}"]
    summary = "\n".join(lines)
    (RESULTS / "summary.md").write_text(summary)
    log("\n" + summary)

    if any("error" in result for result in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
