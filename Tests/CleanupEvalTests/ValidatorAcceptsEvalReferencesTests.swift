import CleanupEval
import CleanupKit
import CoreModels
import Foundation
import Testing

/// Every curated reference in `evals/cleanup` is, by definition, a correct
/// cleanup of its input. The validator's job is to reject *wrong* answers, so
/// it must accept every one of these — a rejection here means a validator rule
/// (ratio, answered-question, rewrite, language-mismatch, …) would throw away
/// a good cleanup and deliver the raw transcript instead.
struct ValidatorAcceptsEvalReferencesTests {

    private static var caseDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CleanupEvalTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("evals")
            .appendingPathComponent("cleanup")
            .path
    }

    @Test func everyReferenceAnswerPassesTheValidator() throws {
        let cases = try EvalCaseLoader.load(directory: Self.caseDirectory)
        #expect(!cases.isEmpty)
        for evalCase in cases {
            let verdict = OutputValidator.validate(
                output: evalCase.reference, input: evalCase.input, language: evalCase.language
            )
            #expect(
                verdict == .accepted(cleaned: evalCase.reference),
                "\(evalCase.id): \(verdict)"
            )
        }
    }
}
