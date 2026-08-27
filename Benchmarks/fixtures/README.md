# Benchmark fixtures

Put `<name>.wav` (16 kHz mono PCM) + `<name>.txt` (the exact words spoken)
here, then run `swift run -c release vocal-bench Benchmarks/fixtures`.
See docs/benchmarks/README.md for the recording/conversion commands.

Audio files are gitignored (they are your voice); reference `.txt` files and
the generated reports in docs/benchmarks/ are committed.
