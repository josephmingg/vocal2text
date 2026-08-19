import CleanupKit
import CoreModels
import Foundation

/// What happened to one case.
public struct CaseResult: Sendable {
    public var caseID: String
    public var category: String
    public var language: Language
    public var input: String
    public var reference: String
    /// Raw provider output, or nil when the call failed outright. Kept for
    /// diagnosis — it is not what gets scored when the validator rejects.
    public var output: String?
    /// The text the app would actually type. Cleanup's own output when the
    /// validator accepted it; the stage-2 transcript when it rejected or the
    /// provider failed, because that is what FR-7.3 falls back to delivering.
    public var deliveredText: String
    /// What the shipping validator decided. A rejection means cleanup did
    /// nothing and the user got their raw transcript — no error is shown, so
    /// the eval has to be the thing that notices.
    public var validatorRule: String?
    /// Scored against `deliveredText`, so an outcome always describes what the
    /// user ended up with rather than a string the app discarded.
    public var ruleOutcomes: [RuleOutcome]
    public var editDistance: Double?
    public var latency: Duration?
    public var error: String?

    /// Cleanup did its job: the provider answered, the shipping validator
    /// accepted the output, and every hard rule held. This is the strict
    /// reading, and the one AC-4 gates on.
    public var passed: Bool {
        error == nil && validatorRule == nil && ruleOutcomes.allSatisfy(\.passed)
    }

    /// The user ended up with acceptable text, whether or not cleanup is what
    /// produced it. A correct rejection lands here and not in `passed`: the
    /// dictation "what's the capital of France" answered as "Paris" is caught
    /// by the validator, so the user receives their own question back — every
    /// rule holds, and cleanup contributed nothing.
    public var deliveredPassed: Bool {
        ruleOutcomes.allSatisfy(\.passed)
    }
}

/// Runs the eval set against a live provider.
///
/// Everything except the network hop is the app's own code: `CleanupRequest` is
/// the same value the session builds, and the output goes through the same
/// `OutputValidator` before it is scored — so a green eval means the pipeline
/// would have delivered that text, not merely that a model produced it.
public struct EvalRunner: Sendable {

    private let provider: any CleanupProvider
    private let timeout: Duration

    public init(provider: any CleanupProvider, timeout: Duration = .seconds(30)) {
        self.provider = provider
        self.timeout = timeout
    }

    public func run(_ evalCase: EvalCase) async -> CaseResult {
        var result = CaseResult(
            caseID: evalCase.id,
            category: evalCase.category,
            language: evalCase.language,
            input: evalCase.input,
            reference: evalCase.reference,
            output: nil,
            // The floor for every path: if stage 3 never produces usable text,
            // the app types the transcript it already had (FR-7.3).
            deliveredText: evalCase.input,
            validatorRule: nil,
            ruleOutcomes: [],
            editDistance: nil,
            latency: nil,
            error: nil
        )

        let started = ContinuousClock.now
        let response: CleanupResponse?
        do {
            response = try await provider.cleanup(evalCase.request, timeout: timeout)
        } catch {
            // No early return: a failed call still delivers something to the
            // user, and its rules still have to be counted. Returning here
            // left the case contributing zero checks to *both* sides of the
            // rate, so a run with provider errors quietly scored itself over a
            // smaller denominator than the one it was supposed to answer.
            result.error = String(describing: error)
            response = nil
        }
        result.latency = ContinuousClock.now - started

        // Score what the user would actually receive. The validator strips
        // reasoning blocks before accepting and the app delivers that text; on
        // a rejection the app delivers the stage-2 transcript unchanged, so
        // that is what the rules are measured against. Scoring a rejected case
        // against the string the pipeline threw away would describe an outcome
        // nobody ever saw.
        if let response {
            result.output = response.text
            switch OutputValidator.validate(
                output: response.text, input: evalCase.input, language: evalCase.language
            ) {
            case .accepted(let cleaned):
                result.deliveredText = cleaned
            case .rejected(let rule):
                result.validatorRule = rule
            }
        }

        result.ruleOutcomes = evalCase.rules.map {
            RuleChecker.check(
                $0, output: result.deliveredText, input: evalCase.input,
                protectedTerms: evalCase.protectedTerms
            )
        }
        result.editDistance = RuleChecker.normalizedEditDistance(
            result.deliveredText, evalCase.reference
        )
        return result
    }

    /// Cases run one at a time on purpose: a local Ollama serves them serially
    /// anyway, and the latency numbers are only meaningful without contention.
    public func run(
        _ cases: [EvalCase], onProgress: @Sendable (CaseResult) -> Void = { _ in }
    ) async -> [CaseResult] {
        var results: [CaseResult] = []
        results.reserveCapacity(cases.count)
        for evalCase in cases {
            let result = await run(evalCase)
            onProgress(result)
            results.append(result)
        }
        return results
    }
}

/// Aggregate scorecard. `hardRulePassRate` is the number AC-4 is written
/// against (docs/01 §AC-4: ≥ 90% of hard-rule checks).
public struct EvalSummary: Sendable {
    public var total: Int
    public var passedCases: Int
    public var deliveredPassedCases: Int
    public var rulesChecked: Int
    public var rulesPassed: Int
    public var deliveredRulesPassed: Int
    public var validatorRejections: Int
    public var errors: Int
    public var medianEditDistance: Double
    public var medianLatencyMilliseconds: Int
    public var p95LatencyMilliseconds: Int

    public var casePassRate: Double {
        total == 0 ? 0 : Double(passedCases) / Double(total)
    }

    /// Did cleanup do its job? A case counts only when stage 3 produced text
    /// the validator accepted. This is what AC-4 gates on, deliberately: a
    /// pipeline that rejected everything would be safe and useless, and a
    /// number that called that success would be measuring the wrong thing.
    public var hardRulePassRate: Double {
        rulesChecked == 0 ? 0 : Double(rulesPassed) / Double(rulesChecked)
    }

    /// Did the user end up with acceptable text? Scored against what the app
    /// actually types, which is the stage-2 transcript whenever cleanup was
    /// rejected or failed. Always at least `hardRulePassRate`; the gap between
    /// them is the work cleanup declined to do — safely.
    public var deliveredRulePassRate: Double {
        rulesChecked == 0 ? 0 : Double(deliveredRulesPassed) / Double(rulesChecked)
    }

    public var meetsAcceptanceCriterion: Bool { hardRulePassRate >= 0.9 }

    public init(results: [CaseResult]) {
        total = results.count
        passedCases = results.filter(\.passed).count
        deliveredPassedCases = results.filter(\.deliveredPassed).count
        rulesChecked = results.reduce(0) { $0 + $1.ruleOutcomes.count }
        // The strict count: only cleanup's own accepted output earns credit.
        // Rules are now scored against the delivered text, so a rejected case
        // is measured against the raw transcript rather than against nothing —
        // which is what the vacuous-pass guard was really protecting against.
        // The qwen3:8b run that scored 64% with zero usable outputs did so
        // because every "must not contain" rule held against an empty string;
        // measured against the transcript the user actually received, those
        // same cases fail on their fillers and punctuation, honestly.
        rulesPassed = results.reduce(0) { partial, result in
            guard result.error == nil, result.validatorRule == nil else { return partial }
            return partial + result.ruleOutcomes.filter(\.passed).count
        }
        deliveredRulesPassed = results.reduce(0) { $0 + $1.ruleOutcomes.filter(\.passed).count }
        validatorRejections = results.filter { $0.validatorRule != nil }.count
        errors = results.filter { $0.error != nil }.count

        let distances = results.compactMap(\.editDistance).sorted()
        medianEditDistance = EvalSummary.percentile(distances, 0.5) ?? 0

        let latencies = results.compactMap { $0.latency.map(EvalSummary.milliseconds) }.sorted()
        medianLatencyMilliseconds = Int(EvalSummary.percentile(latencies, 0.5) ?? 0)
        p95LatencyMilliseconds = Int(EvalSummary.percentile(latencies, 0.95) ?? 0)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Nearest-rank percentile on a pre-sorted array.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
