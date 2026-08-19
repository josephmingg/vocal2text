import CoreModels
import Foundation

/// Renders results as Markdown for `docs/benchmarks/`, so prompt and model
/// changes are diffable rather than remembered (docs/05 §7).
public enum EvalReport {

    public static func markdown(
        results: [CaseResult],
        summary: EvalSummary,
        model: String,
        endpoint: String,
        stamp: String,
        temperature: Double
    ) -> String {
        var out = """
            # Cleanup eval — \(model)

            - Endpoint: `\(endpoint)`
            - Run: \(stamp)
            - Cases: \(summary.total)
            - Temperature: \(temperature)\
            \(temperature == 0 ? "" : " — sampled, so run-to-run drift is expected")

            | Metric | Value |
            |---|---|
            | **Hard-rule pass rate (AC-4 ≥ 90%)** | **\(percent(summary.hardRulePassRate))** \
            \(summary.meetsAcceptanceCriterion ? "✅" : "❌") |
            | Delivered-text pass rate | \(percent(summary.deliveredRulePassRate)) |
            | Cases fully passing | \(summary.passedCases)/\(summary.total) \
            (\(percent(summary.casePassRate))) |
            | Cases whose delivered text is acceptable | \
            \(summary.deliveredPassedCases)/\(summary.total) |
            | Rules passing (cleanup's own output) | \
            \(summary.rulesPassed)/\(summary.rulesChecked) |
            | Rules passing (text the app types) | \
            \(summary.deliveredRulesPassed)/\(summary.rulesChecked) |
            | Validator rejections (app delivers stage-2 text) | \(summary.validatorRejections) |
            | Provider errors | \(summary.errors) |
            | Median edit distance to reference | \(twoPlaces(summary.medianEditDistance)) |
            | Latency p50 / p95 | \(summary.medianLatencyMilliseconds) ms / \
            \(summary.p95LatencyMilliseconds) ms |

            Two rates, because they answer different questions. **Hard-rule pass \
            rate** asks whether cleanup did its job: a case counts only when the \
            provider answered, the shipping `OutputValidator` accepted the output, \
            and every hard rule held. AC-4 gates on it. **Delivered-text pass \
            rate** asks what the user ended up with, scoring the rules against the \
            text the app actually types — which is the stage-2 transcript whenever \
            cleanup was rejected or failed (FR-7.3). The gap between them is work \
            cleanup declined to do rather than damage it caused. Edit distance is \
            reported, never scored — several wordings can be equally right.


            """

        out += byCategory(results)
        out += "\n## Failures\n\n"
        let failures = results.filter { !$0.passed }
        if failures.isEmpty {
            out += "None.\n"
        } else {
            for result in failures {
                out += failureSection(result)
            }
        }
        return out
    }

    /// Both rates per category, so a category that looks weak can be read for
    /// which kind of weak it is: cleanup getting it wrong, or cleanup backing
    /// out and leaving the transcript.
    private static func byCategory(_ results: [CaseResult]) -> String {
        var out = "## By category\n\n"
        out += "| Category | Cases | Rules (cleanup) | Rules (delivered) |\n|---|---|---|---|\n"
        let categories = Set(results.map(\.category)).sorted()
        for category in categories {
            let inCategory = results.filter { $0.category == category }
            let rules = inCategory.reduce(0) { $0 + $1.ruleOutcomes.count }
            let strict = inCategory.reduce(0) { partial, result in
                guard result.error == nil, result.validatorRule == nil else { return partial }
                return partial + result.ruleOutcomes.filter(\.passed).count
            }
            let delivered = inCategory.reduce(0) { $0 + $1.ruleOutcomes.filter(\.passed).count }
            out += "| \(category) | \(inCategory.filter(\.passed).count)/\(inCategory.count) "
            out += "| \(strict)/\(rules) | \(delivered)/\(rules) |\n"
        }
        return out
    }

    private static func failureSection(_ result: CaseResult) -> String {
        var out = "### \(result.caseID) — \(result.category)\n\n"
        out += "- Input: `\(result.input)`\n"
        out += "- Reference: `\(result.reference)`\n"
        out += "- Output: `\(result.output ?? "(none)")`\n"
        if result.deliveredText != result.output {
            out += "- Delivered: `\(result.deliveredText)` — what the app would type\n"
        }
        if let error = result.error {
            out += "- **Provider error:** \(error)\n"
        }
        if let rule = result.validatorRule {
            out += "- **Validator rejected:** `\(rule)` — the app would deliver the "
            out += "stage-2 text unchanged\n"
        }
        for outcome in result.ruleOutcomes where !outcome.passed {
            out += "- **Failed:** \(outcome.label)"
            out += outcome.detail.isEmpty ? "\n" : " — \(outcome.detail)\n"
        }
        return out + "\n"
    }

    /// One-line-per-case console form, printed while the run is in flight so a
    /// slow model does not look like a hang.
    public static func consoleLine(_ result: CaseResult) -> String {
        let mark = result.passed ? "✔" : "✘"
        var line = "\(mark) \(result.caseID.padding(toLength: 28, withPad: " ", startingAt: 0))"
        if let error = result.error {
            return line + " provider error: \(error)"
        }
        if let rule = result.validatorRule {
            line += " validator:\(rule)"
        }
        let failed = result.ruleOutcomes.filter { !$0.passed }
        if !failed.isEmpty {
            line += " " + failed.map(\.label).joined(separator: " ")
        }
        return line
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func twoPlaces(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
