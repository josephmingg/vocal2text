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
    /// Raw provider output, or nil when the call failed outright.
    public var output: String?
    /// What the shipping validator decided. A rejection means the app would
    /// have silently delivered the stage-2 text instead — cleanup did nothing,
    /// which is a failure even though the user sees no error (FR-7.3).
    public var validatorRule: String?
    public var ruleOutcomes: [RuleOutcome]
    public var editDistance: Double?
    public var latency: Duration?
    public var error: String?

    /// A case passes only when the provider answered, the shipping validator
    /// accepted the output, and every hard rule held.
    public var passed: Bool {
        error == nil && validatorRule == nil && ruleOutcomes.allSatisfy(\.passed)
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
            validatorRule: nil,
            ruleOutcomes: [],
            editDistance: nil,
            latency: nil,
            error: nil
        )

        let started = ContinuousClock.now
        let response: CleanupResponse
        do {
            response = try await provider.cleanup(evalCase.request, timeout: timeout)
        } catch {
            result.error = String(describing: error)
            result.latency = ContinuousClock.now - started
            return result
        }
        result.latency = ContinuousClock.now - started

        // Score what the user would actually receive: the validator strips
        // reasoning blocks before accepting, and the app delivers that text.
        switch OutputValidator.validate(
            output: response.text, input: evalCase.input, language: evalCase.language
        ) {
        case .accepted(let cleaned):
            result.output = cleaned
        case .rejected(let rule):
            result.output = response.text
            result.validatorRule = rule
        }

        let scored = result.output ?? ""
        result.ruleOutcomes = evalCase.rules.map {
            RuleChecker.check(
                $0, output: scored, input: evalCase.input,
                protectedTerms: evalCase.protectedTerms
            )
        }
        result.editDistance = RuleChecker.normalizedEditDistance(scored, evalCase.reference)
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
    public var rulesChecked: Int
    public var rulesPassed: Int
    public var validatorRejections: Int
    public var errors: Int
    public var medianEditDistance: Double
    public var medianLatencyMilliseconds: Int
    public var p95LatencyMilliseconds: Int

    public var casePassRate: Double {
        total == 0 ? 0 : Double(passedCases) / Double(total)
    }

    public var hardRulePassRate: Double {
        rulesChecked == 0 ? 0 : Double(rulesPassed) / Double(rulesChecked)
    }

    public var meetsAcceptanceCriterion: Bool { hardRulePassRate >= 0.9 }

    public init(results: [CaseResult]) {
        total = results.count
        passedCases = results.filter(\.passed).count
        rulesChecked = results.reduce(0) { $0 + $1.ruleOutcomes.count }
        // Rules only count as passed on output the user would actually receive.
        // A rejected or errored case delivered nothing, and `mustNotContain`
        // passes vacuously against nothing — the qwen3:8b run scored 64% with
        // zero usable outputs, because every "must not contain" rule held
        // against an empty string. A model that produces nothing must score
        // nothing.
        rulesPassed = results.reduce(0) { partial, result in
            guard result.error == nil, result.validatorRule == nil else { return partial }
            return partial + result.ruleOutcomes.filter(\.passed).count
        }
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
