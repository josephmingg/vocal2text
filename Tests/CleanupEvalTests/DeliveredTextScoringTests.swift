import CleanupEval
import CleanupKit
import CoreModels
import Foundation
import Testing

/// Scoring is measured against the text the app would actually type.
///
/// A validator rejection is the pipeline working as designed: cleanup produced
/// something unusable, the guard caught it, and FR-7.3 delivers the stage-2
/// transcript instead. Scoring that case against the string the pipeline threw
/// away describes an outcome nobody ever saw, so there are two rates — one for
/// whether cleanup did its job, one for what the user ended up with.
struct DeliveredTextScoringTests {

    /// Returns a fixed string, or throws, without touching a network.
    private struct StubProvider: CleanupProvider {
        var id: CleanupProviderID = .ollama(model: "stub")
        var leavesDevice = false
        var reply: String?

        func isAvailable() async -> Bool { true }
        func prewarm() async {}

        func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse
        {
            guard let reply = reply else { throw CleanupError.timedOut }
            return CleanupResponse(text: reply, modelName: "stub")
        }
    }

    /// The failure the short-input floor was added to catch, end to end.
    private var answeredQuestion: EvalCase {
        EvalCase(
            id: "q", category: "questions-not-answered", language: .english,
            input: "what's the capital of France",
            reference: "What's the capital of France?",
            rules: [
                EvalRule(kind: .mustNotContain, values: ["Paris"]),
                EvalRule(kind: .mustContain, values: ["France"]),
            ]
        )
    }

    @Test func aRejectedCaseIsScoredAgainstTheTranscriptTheAppDelivers() async {
        let runner = EvalRunner(provider: StubProvider(reply: "Paris"))
        let result = await runner.run(answeredQuestion)

        // The validator caught it, so the user keeps their own question.
        #expect(result.validatorRule == "ratio")
        #expect(result.output == "Paris")
        #expect(result.deliveredText == answeredQuestion.input)

        // Every rule holds against what was delivered — but cleanup did not do
        // its job, and only the delivered rate is allowed to say otherwise.
        #expect(result.deliveredPassed)
        #expect(!result.passed)

        let summary = EvalSummary(results: [result])
        #expect(summary.rulesPassed == 0)
        #expect(summary.deliveredRulesPassed == 2)
        #expect(summary.rulesChecked == 2)
        #expect(summary.validatorRejections == 1)
    }

    /// The guard the old vacuous-pass rule was really protecting against. An
    /// empty reply used to satisfy every `mustNotContain` by having no text at
    /// all; measured against the transcript the user receives, the filler is
    /// still sitting there and the case fails honestly on both rates.
    @Test func anEmptyReplyFailsOnTheFillerItLeftInTheTranscript() async {
        let fillerCase = EvalCase(
            id: "f", category: "fillers", language: .english,
            input: "um so I think we should ship it",
            reference: "So I think we should ship it.",
            rules: [EvalRule(kind: .mustNotContain, values: ["um"])]
        )
        let runner = EvalRunner(provider: StubProvider(reply: ""))
        let result = await runner.run(fillerCase)

        #expect(result.validatorRule == "empty")
        #expect(result.deliveredText == fillerCase.input)
        #expect(!result.deliveredPassed)
        #expect(!result.passed)

        let summary = EvalSummary(results: [result])
        #expect(summary.rulesPassed == 0)
        #expect(summary.deliveredRulesPassed == 0)
    }

    /// A provider error used to return early, leaving the case contributing
    /// zero checks to both sides of the rate — so a run with errors scored
    /// itself over a smaller denominator than the one it set out to answer.
    @Test func aProviderErrorStillCountsItsRules() async {
        let runner = EvalRunner(provider: StubProvider(reply: nil), timeout: .milliseconds(1))
        let result = await runner.run(answeredQuestion)

        #expect(result.error != nil)
        #expect(result.deliveredText == answeredQuestion.input)
        #expect(!result.passed)

        let summary = EvalSummary(results: [result])
        #expect(summary.rulesChecked == 2)
        #expect(summary.rulesPassed == 0)
        #expect(summary.errors == 1)
    }

    /// When cleanup works, the two rates agree — the delivered text *is* the
    /// cleaned text, so nothing about this change moves an accepted case.
    @Test func anAcceptedCaseScoresIdenticallyOnBothRates() async {
        let fillerCase = EvalCase(
            id: "f", category: "fillers", language: .english,
            input: "um so I think we should ship it",
            reference: "So I think we should ship it.",
            rules: [EvalRule(kind: .mustNotContain, values: ["um"])]
        )
        let runner = EvalRunner(provider: StubProvider(reply: "So I think we should ship it."))
        let result = await runner.run(fillerCase)

        #expect(result.validatorRule == nil)
        #expect(result.deliveredText == "So I think we should ship it.")
        #expect(result.passed)
        #expect(result.deliveredPassed)

        let summary = EvalSummary(results: [result])
        #expect(summary.rulesPassed == summary.deliveredRulesPassed)
        #expect(summary.hardRulePassRate == summary.deliveredRulePassRate)
    }
}
