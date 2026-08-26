import ASRKit
import BenchKit
import CoreModels
import Foundation
import TextPipeline

#if canImport(WhisperKit)
import ASREngineWhisperKit
#endif
import PersistenceKit
#if canImport(Darwin)
import Darwin
#endif

/// The docs/06 M0 evidence harness (Phase 0.2): transcribes fixture WAVs
/// through the real engine + text pipeline, and reports per-stage latency
/// percentiles, real-time factor, WER/CER against reference transcripts, and
/// memory footprint — as the markdown that `docs/benchmarks/` commits.
///
///     swift run -c release vocal-bench Benchmarks/fixtures \
///         [--runs 3] [--language auto|en|zh] [--model NAME] [--output FILE]
///
/// Fixture layout: `<name>.wav` (16 kHz mono is what the engine consumes;
/// see docs/benchmarks/README.md for the conversion command) with an optional
/// `<name>.txt` reference transcript enabling WER/CER for that fixture.
@main
struct VocalBench {

    struct Options {
        var fixturesDirectory: URL
        var runs = 3
        var languageMode = LanguageMode.auto
        var modelName: String?
        var outputPath: String?
    }

    struct FixtureResult {
        var name: String
        var audioSeconds: Double
        var transcribeSeconds: [Double]
        var pipelineSeconds: [Double]
        var wer: WordErrorRate.Score?
        var transcript: String
    }

    static func main() async {
        // docs/15 step 47: `vocal-bench latency` reads the real transcript
        // database instead of fixtures — daily-driving numbers for free.
        if CommandLine.arguments.dropFirst().first == "latency" {
            runLatency(arguments: Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        guard let options = parseOptions() else {
            printUsage()
            exit(2)
        }
        #if canImport(WhisperKit)
        await run(options)
        #else
        FileHandle.standardError.write(Data(
            "vocal-bench needs the WhisperKit engine — run it on macOS.\n".utf8
        ))
        exit(1)
        #endif
    }

    // MARK: - Latency-from-history (docs/15 step 47)

    static func runLatency(arguments: [String]) {
        // DatabaseStore exists only where GRDB does (Darwin builds); the
        // Linux stub of PersistenceKit has no store to read.
        #if canImport(Darwin)
        var databasePath: String?
        var remaining = arguments
        while !remaining.isEmpty {
            let argument = remaining.removeFirst()
            switch argument {
            case "--db":
                guard let value = remaining.first else {
                    FileHandle.standardError.write(Data("--db needs a path\n".utf8))
                    exit(2)
                }
                remaining.removeFirst()
                databasePath = value
            default:
                FileHandle.standardError.write(Data(
                    "usage: vocal-bench latency [--db /path/to/vocal.sqlite]\n".utf8
                ))
                exit(2)
            }
        }
        let path = databasePath ?? defaultDatabasePath()
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data(
                "no database at \(path) — pass --db or dictate first\n".utf8
            ))
            exit(1)
        }
        do {
            let store = try DatabaseStore(path: path)
            // Spoken takes with recorded timings only: imports are not the
            // user waiting on a release, and rows from before the timing
            // marks existed decode as all-zero — folding either in drags
            // every percentile toward 0.00 s.
            let samples = try store.allTranscripts()
                .filter { !$0.isCancelled && $0.source != .fileImport }
                .filter { $0.timings.totalPostReleaseSeconds > 0 }
                .map {
                    LatencyReport.Sample(
                        durationSeconds: $0.durationSeconds, timings: $0.timings
                    )
                }
            print(LatencyReport.render(samples: samples))
        } catch {
            FileHandle.standardError.write(Data(
                "could not read \(path): \(error)\n".utf8
            ))
            exit(1)
        }
        #else
        FileHandle.standardError.write(Data(
            "vocal-bench latency needs the GRDB-backed store — run it on macOS.\n".utf8
        ))
        exit(1)
        #endif
    }

    static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return appSupport
            .appendingPathComponent("Vocal", isDirectory: true)
            .appendingPathComponent("vocal.sqlite")
            .path
    }

    // MARK: - Argument parsing

    static func parseOptions() -> Options? {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { return nil }
        var options = Options(fixturesDirectory: URL(fileURLWithPath: "."))
        var directory: String?
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--runs":
                guard let value = arguments.first, let runs = Int(value), runs > 0 else {
                    return nil
                }
                arguments.removeFirst()
                options.runs = runs
            case "--language":
                guard let value = arguments.first else { return nil }
                arguments.removeFirst()
                switch value {
                case "auto": options.languageMode = .auto
                case "en": options.languageMode = .pinned(.english)
                case "zh": options.languageMode = .pinned(.chinese)
                default: return nil
                }
            case "--model":
                guard let value = arguments.first else { return nil }
                arguments.removeFirst()
                options.modelName = value
            case "--output":
                guard let value = arguments.first else { return nil }
                arguments.removeFirst()
                options.outputPath = value
            case "--help", "-h":
                return nil
            default:
                guard directory == nil else { return nil }
                directory = argument
            }
        }
        guard let directory else { return nil }
        options.fixturesDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        return options
    }

    static func printUsage() {
        print(
            """
            usage: vocal-bench <fixtures-dir> [--runs N] [--language auto|en|zh]
                               [--model NAME] [--output FILE]
                   vocal-bench latency [--db /path/to/vocal.sqlite]
            Fixtures: <name>.wav (+ optional <name>.txt reference transcript).
            `latency` prints p50/p95/p99 per stage from the app's own history.
            See docs/benchmarks/README.md.
            """
        )
    }

    #if canImport(WhisperKit)
    // MARK: - The run

    static func run(_ options: Options) async {
        let fileManager = FileManager.default
        let wavs = ((try? fileManager.contentsOfDirectory(
            at: options.fixturesDirectory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !wavs.isEmpty else {
            FileHandle.standardError.write(Data(
                "no .wav fixtures in \(options.fixturesDirectory.path) — see docs/benchmarks/README.md\n"
                    .utf8
            ))
            exit(1)
        }

        let engine: WhisperKitEngine
        if let modelName = options.modelName {
            engine = WhisperKitEngine(modelName: modelName)
        } else {
            engine = WhisperKitEngine()
        }

        let clock = ContinuousClock()
        print("Loading model (first run downloads + compiles)…")
        let loadStart = clock.now
        do {
            try await engine.prepare(languageMode: options.languageMode)
        } catch {
            FileHandle.standardError.write(Data("model load failed: \(error)\n".utf8))
            exit(1)
        }
        let loadSeconds = seconds(loadStart.duration(to: clock.now))
        print(String(format: "Model ready in %.1fs\n", loadSeconds))

        var results: [FixtureResult] = []
        for wav in wavs {
            let name = wav.deletingPathExtension().lastPathComponent
            let contents: WavFile.Contents
            do {
                contents = try WavFile.read(wav)
            } catch {
                print("skipping \(name): \(error)")
                continue
            }
            if contents.sampleRate != PCMChunk.sampleRate {
                print(
                    "warning: \(name) is \(contents.sampleRate) Hz, expected \(PCMChunk.sampleRate) — resample it (docs/benchmarks/README.md)"
                )
            }
            let chunk = PCMChunk(samples: contents.samples)
            let reference = try? String(
                contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"),
                encoding: .utf8
            )

            var transcribeSeconds: [Double] = []
            var pipelineSeconds: [Double] = []
            var transcript = ""
            var failed = false
            for runIndex in 1...options.runs {
                do {
                    let start = clock.now
                    let result = try await engine.transcribe(
                        chunk, languageMode: options.languageMode, dictionaryTerms: []
                    )
                    transcribeSeconds.append(seconds(start.duration(to: clock.now)))

                    let stageStart = clock.now
                    let normalized = Stage1Normalizer.normalize(
                        result.text,
                        language: result.detectedLanguage,
                        formatting: FormattingOptions()
                    )
                    transcript = Stage4Formatter.format(
                        normalized,
                        language: result.detectedLanguage,
                        formatting: FormattingOptions(),
                        precedingContext: nil
                    )
                    pipelineSeconds.append(seconds(stageStart.duration(to: clock.now)))
                } catch {
                    print("\(name) run \(runIndex) failed: \(error)")
                    failed = true
                    break
                }
            }
            guard !failed, !transcribeSeconds.isEmpty else { continue }

            let wer = reference.map {
                WordErrorRate.score(reference: $0, hypothesis: transcript)
            }
            results.append(FixtureResult(
                name: name,
                audioSeconds: contents.durationSeconds,
                transcribeSeconds: transcribeSeconds,
                pipelineSeconds: pipelineSeconds,
                wer: wer,
                transcript: transcript
            ))
            let median = Percentile.value(transcribeSeconds.sorted(), 50)
            print(String(
                format: "%@: %.1fs audio, transcribe p50 %.2fs%@",
                name, contents.durationSeconds, median,
                wer.map { String(format: ", \($0.isCharacterBased ? "CER" : "WER") %.1f%%", $0.rate * 100) }
                    ?? ""
            ))
        }

        let report = markdownReport(
            results: results, options: options, loadSeconds: loadSeconds
        )
        if let outputPath = options.outputPath {
            do {
                try report.write(
                    to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8
                )
                print("\nReport written to \(outputPath)")
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                print("\n" + report)
            }
        } else {
            print("\n" + report)
        }
    }

    static func markdownReport(
        results: [FixtureResult], options: Options, loadSeconds: Double
    ) -> String {
        let dateFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# Vocal benchmark results")
        lines.append("")
        lines.append("- Date: \(dateFormatter.string(from: Date()))")
        lines.append("- Model: \(options.modelName ?? "default (large-v3-turbo)")")
        lines.append("- Language mode: \(label(for: options.languageMode))")
        lines.append("- Runs per fixture: \(options.runs)")
        lines.append(String(format: "- Model load/warm-up: %.1f s", loadSeconds))
        if let footprint = memoryFootprintMB() {
            lines.append(String(format: "- Memory footprint after runs: %.0f MB", footprint))
        }
        lines.append("")
        lines.append(
            "| Fixture | Audio s | Transcribe p50 | p95 | RTF | Pipeline p50 | WER/CER |"
        )
        lines.append("|---|---|---|---|---|---|---|")
        var allTranscribe: [Double] = []
        for result in results {
            let sorted = result.transcribeSeconds.sorted()
            allTranscribe.append(contentsOf: sorted)
            let p50 = Percentile.value(sorted, 50)
            let p95 = Percentile.value(sorted, 95)
            let pipelineP50 = Percentile.value(result.pipelineSeconds.sorted(), 50)
            let rtf = result.audioSeconds > 0 ? result.audioSeconds / max(p50, 0.0001) : 0
            let werText = result.wer.map {
                String(format: "%.1f%% %@", $0.rate * 100, $0.isCharacterBased ? "CER" : "WER")
            } ?? "—"
            lines.append(String(
                format: "| %@ | %.1f | %.2f s | %.2f s | %.0fx | %.3f s | %@ |",
                result.name, result.audioSeconds, p50, p95, rtf, pipelineP50, werText
            ))
        }
        let overall = allTranscribe.sorted()
        lines.append("")
        lines.append(String(
            format: "Overall transcribe p50 %.2f s · p95 %.2f s across %d measurements.",
            Percentile.value(overall, 50), Percentile.value(overall, 95), overall.count
        ))
        lines.append("")
        lines.append("## Transcripts")
        lines.append("")
        for result in results {
            lines.append("### \(result.name)")
            lines.append("")
            lines.append("```")
            lines.append(result.transcript)
            lines.append("```")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func label(for mode: LanguageMode) -> String {
        switch mode {
        case .auto: return "auto"
        case .pinned(let language): return language.rawValue
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// phys_footprint — the number Activity Monitor's "Memory" column shows.
    static func memoryFootprintMB() -> Double? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
        #else
        return nil
        #endif
    }
    #endif
}
