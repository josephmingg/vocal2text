import CoreModels
import Foundation
import Testing

@testable import CleanupEval

/// The eval harness produces numbers that get believed and checked into
/// `docs/benchmarks/`. Its scoring is the one part that can be verified without
/// a live model, so it is.

// MARK: - mustContain / mustNotContain

@Test func mustContainIsCaseInsensitive() {
    let rule = EvalRule(kind: .mustContain, values: ["Saturday"])
    #expect(RuleChecker.check(rule, output: "See you saturday.", input: "", protectedTerms: [])
        .passed)
}

@Test func mustContainReportsWhatWasMissing() {
    let rule = EvalRule(kind: .mustContain, values: ["Friday", "Saturday"])
    let outcome = RuleChecker.check(
        rule, output: "See you Saturday.", input: "", protectedTerms: []
    )
    #expect(!outcome.passed)
    #expect(outcome.detail.contains("Friday"))
    #expect(!outcome.detail.contains("Saturday"))
}

@Test func mustNotContainCatchesASurvivingFiller() {
    let rule = EvalRule(kind: .mustNotContain, values: ["um", "uh"])
    #expect(
        !RuleChecker.check(
            rule, output: "So um we should ship.", input: "", protectedTerms: []
        ).passed
    )
    #expect(
        RuleChecker.check(rule, output: "So we should ship.", input: "", protectedTerms: [])
            .passed
    )
}

@Test func latinMatchingRespectsWordBoundaries() {
    // Substring matching would fail this case even though the model was right:
    // "album" and "number" both contain "um".
    let rule = EvalRule(kind: .mustNotContain, values: ["um"])
    #expect(
        RuleChecker.check(
            rule, output: "Track the album number.", input: "", protectedTerms: []
        ).passed
    )
    // Punctuation still bounds a word.
    #expect(!RuleChecker.check(rule, output: "Um, right.", input: "", protectedTerms: []).passed)
    #expect(!RuleChecker.check(rule, output: "Right (um).", input: "", protectedTerms: []).passed)
}

@Test func wordBoundaryScanSurvivesRepeatedNearMisses() {
    // Several embedded hits before a real one must not end the scan early.
    let rule = EvalRule(kind: .mustContain, values: ["um"])
    #expect(
        RuleChecker.check(
            rule, output: "album number drum, um yes", input: "", protectedTerms: []
        ).passed
    )
    #expect(
        !RuleChecker.check(
            rule, output: "album number drum", input: "", protectedTerms: []
        ).passed
    )
}

@Test func mustNotContainWorksOnHanWithoutWordBoundaries() {
    // 「不对」 must not survive into the output of a self-correction.
    let rule = EvalRule(kind: .mustNotContain, values: ["不对"])
    #expect(
        !RuleChecker.check(rule, output: "周五，啊不对，周六。", input: "", protectedTerms: [])
            .passed
    )
    #expect(RuleChecker.check(rule, output: "周六。", input: "", protectedTerms: []).passed)
}

// MARK: - Regressions from the first live run (2026-08-17, qwen2.5:3b-instruct)

@Test func latinTermsEmbeddedInHanAreFound() {
    // The first eval run scored 5 code-switching cases as failures whose terms
    // were plainly present: Han is `isLetter`, so 先/一 read as word characters
    // and `review` looked mid-word.
    let rule = EvalRule(kind: .mustContain, values: ["review", "PR", "merge"])
    #expect(
        RuleChecker.check(
            rule, output: "我们先review一下这个PR再merge。", input: "", protectedTerms: []
        ).passed
    )
    #expect(
        RuleChecker.check(
            EvalRule(kind: .mustContain, values: ["issue"]),
            output: "打开GitHub看一下那个issue", input: "", protectedTerms: []
        ).passed
    )
    #expect(
        RuleChecker.check(
            EvalRule(kind: .mustContain, values: ["test", "deploy"]),
            output: "先跑一下test，pass了再deploy", input: "", protectedTerms: []
        ).passed
    )
    // The boundary rule must still hold inside Latin text.
    #expect(
        !RuleChecker.check(
            EvalRule(kind: .mustContain, values: ["um"]),
            output: "album number", input: "", protectedTerms: []
        ).passed
    )
}

@Test func fullWidthPunctuationIsNotTheSameAsAscii() {
    // Width-insensitive matching made the correct output 「，」 match the ASCII
    // "," the case forbids — the eval failed the one thing it was measuring.
    let rule = EvalRule(kind: .mustNotContain, values: [","])
    #expect(
        RuleChecker.check(
            rule, output: "今天的会议取消了，下周再说。", input: "", protectedTerms: []
        ).passed
    )
    #expect(
        !RuleChecker.check(
            rule, output: "今天的会议取消了,下周再说", input: "", protectedTerms: []
        ).passed
    )
}

@Test func caseSensitiveRulesCanTestCapitalisation() {
    // Correct output is lowercase `vocal2text`; a case-insensitive rule found
    // the forbidden `Vocal2Text` inside it and failed a good answer.
    let cased = EvalRule(
        kind: .mustNotContain, values: ["Vocal2Text"], caseSensitive: true
    )
    #expect(
        RuleChecker.check(
            cased, output: "the error is in vocal2text not in the SDK", input: "",
            protectedTerms: []
        ).passed
    )
    #expect(
        !RuleChecker.check(
            cased, output: "the error is in Vocal2Text", input: "", protectedTerms: []
        ).passed
    )
    // Default stays case-insensitive.
    #expect(
        !RuleChecker.check(
            EvalRule(kind: .mustNotContain, values: ["Vocal2Text"]),
            output: "the error is in vocal2text", input: "", protectedTerms: []
        ).passed
    )
}

@Test func emptyRuleValuesPassRatherThanCrash() {
    #expect(
        RuleChecker.check(
            EvalRule(kind: .mustContain, values: []), output: "anything", input: "",
            protectedTerms: []
        ).passed
    )
}

// MARK: - preservesTerms

@Test func preservesTermsDelegatesToTheShippingVerifier() {
    let rule = EvalRule(kind: .preservesTerms, values: ["kubectl"])
    let input = "run kubectl apply"
    #expect(
        RuleChecker.check(
            rule, output: "Run kubectl apply.", input: input, protectedTerms: []
        ).passed
    )
    // A mangled term is exactly what the shipping verifier exists to catch.
    #expect(
        !RuleChecker.check(
            rule, output: "Run kubectl apply, i.e. kubect1 apply.", input: input,
            protectedTerms: []
        ).passed
    )
}

@Test func preservesTermsFallsBackToTheCaseTerms() {
    let rule = EvalRule(kind: .preservesTerms)
    #expect(
        RuleChecker.check(
            rule, output: "Ship SwiftPM today.", input: "ship SwiftPM today",
            protectedTerms: ["SwiftPM"]
        ).passed
    )
}

// MARK: - maxWords

@Test func maxWordsCountsLatinWords() {
    let rule = EvalRule(kind: .maxWords, limit: 5)
    #expect(RuleChecker.check(rule, output: "one two three", input: "", protectedTerms: []).passed)
    #expect(
        !RuleChecker.check(
            rule, output: "one two three four five six", input: "", protectedTerms: []
        ).passed
    )
}

@Test func maxWordsCountsHanCharactersIndividually() {
    // Counting whitespace-delimited tokens would score any Chinese answer as
    // one word, making the "model answered the question" guard useless.
    #expect(RuleChecker.wordCount("周六。") == 2)
    #expect(RuleChecker.wordCount("今天天气很好") == 6)
    let rule = EvalRule(kind: .maxWords, limit: 3)
    #expect(!RuleChecker.check(rule, output: "今天天气很好", input: "", protectedTerms: []).passed)
}

@Test func wordCountIgnoresPunctuationAndSpacing() {
    #expect(RuleChecker.wordCount("Hello,   world!") == 2)
    #expect(RuleChecker.wordCount("  ") == 0)
    #expect(RuleChecker.wordCount("") == 0)
}

@Test func wordCountTreatsMixedScriptsAdditively() {
    // Code-switching cases lean on this. Han counts per character and Latin per
    // run, so 打(1) 开(2) GitHub(3) 的(4) repo(5).
    #expect(RuleChecker.wordCount("打开 GitHub 的 repo") == 5)
    // Han runs are not collapsed the way a Latin run is.
    #expect(RuleChecker.wordCount("打开") == 2)
    #expect(RuleChecker.wordCount("GitHub") == 1)
}

// MARK: - Edit distance

@Test func editDistanceIsZeroForIdenticalStrings() {
    #expect(RuleChecker.normalizedEditDistance("same", "same") == 0)
    #expect(RuleChecker.normalizedEditDistance("", "") == 0)
}

@Test func editDistanceIsOneWhenOneSideIsEmpty() {
    #expect(RuleChecker.normalizedEditDistance("", "text") == 1)
    #expect(RuleChecker.normalizedEditDistance("text", "") == 1)
}

@Test func editDistanceIsNormalizedAgainstTheLongerString() {
    // One substitution in four characters.
    #expect(abs(RuleChecker.normalizedEditDistance("abcd", "abce") - 0.25) < 0.0001)
    // One insertion into three characters.
    #expect(abs(RuleChecker.normalizedEditDistance("abc", "abcd") - 0.25) < 0.0001)
}

@Test func editDistanceIsSymmetric() {
    let forward = RuleChecker.normalizedEditDistance("kitten", "sitting")
    let backward = RuleChecker.normalizedEditDistance("sitting", "kitten")
    #expect(forward == backward)
}

// MARK: - Summary arithmetic

private func result(
    id: String, rules: [Bool], validatorRule: String? = nil, error: String? = nil
) -> CaseResult {
    CaseResult(
        caseID: id,
        category: "test",
        language: .english,
        input: "in",
        reference: "ref",
        output: "out",
        validatorRule: validatorRule,
        ruleOutcomes: rules.map { RuleOutcome(label: "r", passed: $0) },
        editDistance: 0.1,
        latency: .milliseconds(100),
        error: error
    )
}

@Test func aCaseFailsWhenTheShippingValidatorRejectsItEvenIfEveryRulePassed() {
    // The user sees no error in this case — the app quietly delivers the
    // stage-2 text — so the eval has to be the thing that notices.
    let rejected = result(id: "a", rules: [true, true], validatorRule: "meta-text")
    #expect(!rejected.passed)
    #expect(result(id: "b", rules: [true, true]).passed)
}

@Test func aCaseFailsWhenTheProviderErrored() {
    #expect(!result(id: "c", rules: [], error: "timedOut").passed)
}

@Test func hardRulePassRateCountsRulesNotCases() {
    // AC-4 is written against rule checks, so a case with many rules weighs
    // more than one with a single rule.
    let summary = EvalSummary(results: [
        result(id: "a", rules: [true, true, true, true]),
        result(id: "b", rules: [false]),
    ])
    #expect(summary.rulesChecked == 5)
    #expect(summary.rulesPassed == 4)
    #expect(abs(summary.hardRulePassRate - 0.8) < 0.0001)
    #expect(summary.casePassRate == 0.5)
    #expect(!summary.meetsAcceptanceCriterion)
}

@Test func acceptanceCriterionIsNinetyPercentOfRules() {
    let nine = (0..<9).map { result(id: "p\($0)", rules: [true]) }
    let one = [result(id: "f", rules: [false])]
    #expect(EvalSummary(results: nine + one).meetsAcceptanceCriterion)
    let eight = (0..<8).map { result(id: "p\($0)", rules: [true]) }
    #expect(!EvalSummary(results: eight + [result(id: "f1", rules: [false, false])])
        .meetsAcceptanceCriterion)
}

@Test func summaryOfNoResultsDoesNotDivideByZero() {
    let summary = EvalSummary(results: [])
    #expect(summary.hardRulePassRate == 0)
    #expect(summary.casePassRate == 0)
    #expect(summary.medianLatencyMilliseconds == 0)
}

@Test func percentileUsesNearestRank() {
    #expect(EvalSummary.percentile([1, 2, 3, 4], 0.5) == 2)
    #expect(EvalSummary.percentile([1, 2, 3, 4], 0.95) == 4)
    #expect(EvalSummary.percentile([], 0.5) == nil)
}

@Test func durationConvertsToMilliseconds() {
    #expect(abs(EvalSummary.milliseconds(.milliseconds(250)) - 250) < 0.001)
    #expect(abs(EvalSummary.milliseconds(.seconds(2)) - 2000) < 0.001)
}

// MARK: - Case loading

@Test func caseDecodingFillsOptionalFields() throws {
    let json = """
        [{"id":"en-001","category":"fillers","language":"en",
          "input":"um hello","reference":"Hello.",
          "rules":[{"kind":"mustNotContain","values":["um "]}]}]
        """
    let cases = try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
    #expect(cases.count == 1)
    #expect(cases[0].profilePrompt.isEmpty)
    #expect(cases[0].protectedTerms.isEmpty)
    #expect(cases[0].language == .english)
    // The request handed to the provider is the app's own type.
    #expect(cases[0].request.text == "um hello")
}
