import CleanupEval
import CleanupKit
import CoreModels
import Foundation

/// Stage-3 eval harness (docs/05 §7, docs/03 §scripts).
///
/// Runs the curated case set against a live OpenAI-compatible endpoint — Ollama
/// by default — and scores each output with the *shipping* validator, so a pass
/// means the pipeline would have delivered that text rather than falling back to
/// the stage-2 transcript.
///
///     swift run eval-cleanup --model qwen2.5:3b-instruct
///     swift run eval-cleanup --category self-correction --verbose
///
/// Needs a model serving locally; it is deliberately not part of `swift test`,
/// which must stay hermetic.
struct Options {
    var endpoint = "http://localhost:11434"
    var model = "qwen2.5:3b-instruct"
    var directory = "evals/cleanup"
    var output: String?
    var category: String?
    var language: Language?
    var timeoutSeconds = 30
    /// Greedy decoding by default. The app ships at 0.2, but a sampled run is
    /// not a measurement: two runs of the same prompt against the same model
    /// differed by two cases, which is the same size as the prompt effects
    /// being chased. Score the prompt deterministically, and pass
    /// `--temperature 0.2` when the question is what the app actually does.
    var temperature = 0.0
    var verbose = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    func take(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    if let value = take("--endpoint") { options.endpoint = value }
    if let value = take("--model") { options.model = value }
    if let value = take("--cases") { options.directory = value }
    if let value = take("--out") { options.output = value }
    if let value = take("--category") { options.category = value }
    if let value = take("--language") { options.language = Language(rawValue: value) }
    if let value = take("--timeout"), let seconds = Int(value) { options.timeoutSeconds = seconds }
    if let value = take("--temperature"), let degrees = Double(value) {
        options.temperature = degrees
    }
    options.verbose = arguments.contains("--verbose")

    if arguments.contains("--help") || arguments.contains("-h") {
        print(
            """
            eval-cleanup — score stage-3 cleanup against the curated case set.

              --endpoint URL   OpenAI-compatible server root (default http://localhost:11434)
              --model NAME     model tag (default qwen2.5:3b-instruct)
              --cases DIR      case directory (default evals/cleanup)
              --out FILE       write the Markdown report here
              --category NAME  run one category only
              --language en|zh|my
              --timeout SEC    per-case timeout (default 30)
              --temperature T  sampling temperature (default 0 — deterministic;
                               the app ships at 0.2)
              --verbose        print each output
            """
        )
        exit(0)
    }
    return options
}

let options = parseOptions()

let cases: [EvalCase]
do {
    var loaded = try EvalCaseLoader.load(directory: options.directory)
    if let category = options.category {
        loaded = loaded.filter { $0.category == category }
    }
    if let language = options.language {
        loaded = loaded.filter { $0.language == language }
    }
    guard !loaded.isEmpty else {
        FileHandle.standardError.write(Data("No cases matched the filters.\n".utf8))
        exit(2)
    }
    cases = loaded
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

guard let baseURL = URL(string: options.endpoint) else {
    FileHandle.standardError.write(Data("Invalid --endpoint: \(options.endpoint)\n".utf8))
    exit(2)
}

let provider = OpenAICompatibleProvider(
    baseURL: baseURL,
    model: options.model,
    temperature: options.temperature,
    id: .ollama(model: options.model)
)

print(
    "eval-cleanup: \(cases.count) cases → \(options.model) at \(options.endpoint) "
        + "(temperature \(options.temperature))\n"
)

guard await provider.isAvailable() else {
    FileHandle.standardError.write(
        Data(
            """
            Provider not reachable at \(options.endpoint).
            Start it first, e.g.  ollama serve  &&  ollama pull \(options.model)

            """.utf8
        )
    )
    exit(3)
}

let runner = EvalRunner(provider: provider, timeout: .seconds(options.timeoutSeconds))
let results = await runner.run(cases) { result in
    print(EvalReport.consoleLine(result))
    if options.verbose, let output = result.output {
        print("    → \(output)")
    }
}

let summary = EvalSummary(results: results)
print(
    """

    ── Summary ──────────────────────────────────────────────
    Hard-rule pass rate  \(String(format: "%.1f%%", summary.hardRulePassRate * 100)) \
    \(summary.meetsAcceptanceCriterion ? "✅ meets AC-4" : "❌ below AC-4 (90%)") \
    — did cleanup do its job (\(summary.rulesPassed)/\(summary.rulesChecked))
    Delivered-text rate  \
    \(String(format: "%.1f%%", summary.deliveredRulePassRate * 100)) \
    — what the user ends up with (\(summary.deliveredRulesPassed)/\(summary.rulesChecked))
    Cases passing        \(summary.passedCases)/\(summary.total) cleanup, \
    \(summary.deliveredPassedCases)/\(summary.total) delivered
    Validator rejections \(summary.validatorRejections) (app delivers the transcript)
    Provider errors      \(summary.errors)
    Latency p50 / p95    \(summary.medianLatencyMilliseconds) ms / \
    \(summary.p95LatencyMilliseconds) ms
    """
)

if let path = options.output {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let markdown = EvalReport.markdown(
        results: results,
        summary: summary,
        model: options.model,
        endpoint: options.endpoint,
        stamp: stamp,
        temperature: options.temperature
    )
    do {
        try markdown.write(toFile: path, atomically: true, encoding: .utf8)
        print("\nReport written to \(path)")
    } catch {
        FileHandle.standardError.write(Data("Could not write \(path): \(error)\n".utf8))
        exit(4)
    }
}

// Non-zero exit when the acceptance criterion is missed, so this can gate a
// prompt change the way a test would.
exit(summary.meetsAcceptanceCriterion ? 0 : 1)
