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
            | Cases fully passing | \(summary.passedCases)/\(summary.total) \
            (\(percent(summary.casePassRate))) |
            | Rules passing | \(summary.rulesPassed)/\(summary.rulesChecked) |
            | Validator rejections (would deliver stage-2 text) | \(summary.validatorRejections) |
            | Provider errors | \(summary.errors) |
            | Median edit distance to reference | \(twoPlaces(summary.medianEditDistance)) |
            | Latency p50 / p95 | \(summary.medianLatencyMilliseconds) ms / \
            \(summary.p95LatencyMilliseconds) ms |

            A case passes only when the provider answered, the shipping \
            `OutputValidator` accepted the output, and every hard rule held. Edit \
            distance is reported, never scored — several wordings can be equally right.


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

    private static func byCategory(_ results: [CaseResult]) -> String {
        var out = "## By category\n\n| Category | Passed | Rules |\n|---|---|---|\n"
        let categories = Set(results.map(\.category)).sorted()
        for category in categories {
            let inCategory = results.filter { $0.category == category }
            let rules = inCategory.reduce(0) { $0 + $1.ruleOutcomes.count }
            let rulesOK = inCategory.reduce(0) { $0 + $1.ruleOutcomes.filter(\.passed).count }
            out += "| \(category) | \(inCategory.filter(\.passed).count)/\(inCategory.count) "
            out += "| \(rulesOK)/\(rules) |\n"
        }
        return out
    }

    private static func failureSection(_ result: CaseResult) -> String {
        var out = "### \(result.caseID) — \(result.category)\n\n"
        out += "- Input: `\(result.input)`\n"
        out += "- Reference: `\(result.reference)`\n"
        out += "- Output: `\(result.output ?? "(none)")`\n"
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
