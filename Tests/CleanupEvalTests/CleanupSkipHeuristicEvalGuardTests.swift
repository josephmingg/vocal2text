import CleanupEval
import CleanupKit
import CoreModels
import Foundation
import Testing

/// Guards the step-20 skip heuristic with the shipped eval set (docs/15):
/// the heuristic and the eval cases must not drift apart. A case whose rules
/// require the model to *remove* something present in the input is exactly a
/// take the heuristic must never skip — skipping it delivers the filler or
/// the false start verbatim.
struct CleanupSkipHeuristicEvalGuardTests {

    /// The repository's own `evals/cleanup`, located from this file so the
    /// test does not depend on the runner's working directory.
    private static var caseDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CleanupEvalTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("evals")
            .appendingPathComponent("cleanup")
            .path
    }

    @Test func evalCasesTheModelMustEditAreNeverSkippable() throws {
        let cases = try EvalCaseLoader.load(directory: Self.caseDirectory)
        #expect(!cases.isEmpty)

        var checked = 0
        for evalCase in cases {
            // The session's gate consults the text heuristic only when no
            // profile or style instructions are in effect — instructed cases
            // always run the model, so they cannot constrain the heuristic.
            guard evalCase.profilePrompt.isEmpty, evalCase.stylePrompt.isEmpty else {
                continue
            }
            let protectedTerms = Set(evalCase.protectedTerms.map { $0.lowercased() })
            let mustRemove = evalCase.rules
                .filter { $0.kind == .mustNotContain }
                .flatMap { $0.values ?? [] }
                .filter { value in
                    // Punctuation-only values (half-width commas in Chinese
                    // output, say) are stage 1's job; protected-term casing
                    // is stage 2's. Neither needs the model.
                    value.rangeOfCharacter(from: .alphanumerics) != nil
                        && !protectedTerms.contains(value.lowercased())
                        && evalCase.input.range(of: value, options: [.caseInsensitive]) != nil
                }
            guard !mustRemove.isEmpty else { continue }
            checked += 1
            #expect(
                !CleanupSkipHeuristic.canSkip(evalCase.input, language: evalCase.language),
                "\(evalCase.id): the model must remove \(mustRemove) but the heuristic would skip the call"
            )
        }
        // The guard is only worth having while the eval set actually
        // exercises it.
        #expect(checked >= 10)
    }
}
