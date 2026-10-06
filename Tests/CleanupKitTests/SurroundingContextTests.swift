import CleanupKit
import CoreModels
import Foundation
import Testing

/// docs/17 G3.2: opt-in context around the cursor for cleanup.
struct SurroundingContextTests {
    private let assembler = PromptAssembler()

    private func request(context: String = "") -> CleanupRequest {
        CleanupRequest(
            text: "and then we ship it",
            language: .english,
            profilePrompt: "Tidy this.",
            context: context
        )
    }

    @Test func withoutContextThePromptIsByteIdenticalToBefore() {
        let plain = CleanupRequest(text: "and then we ship it", language: .english, profilePrompt: "Tidy this.")
        #expect(assembler.systemPrompt(for: request()) == assembler.systemPrompt(for: plain))
        #expect(assembler.userMessage(for: request()) == "<TRANSCRIPT>\nand then we ship it\n</TRANSCRIPT>")
    }

    @Test func contextRidesInItsOwnFenceBeforeTheTranscript() {
        let context = "We reviewed the Kubernetes plan" + CleanupRequest.cursorMarker
        let message = assembler.userMessage(for: request(context: context))
        #expect(
            message == "<CONTEXT>\n\(context)\n</CONTEXT>\n<TRANSCRIPT>\nand then we ship it\n</TRANSCRIPT>"
        )
        let prompt = assembler.systemPrompt(for: request(context: context))
        #expect(prompt.contains("CONTEXT"))
        #expect(prompt.contains("Never copy, answer, quote, or continue it."))
        #expect(prompt.contains(CleanupRequest.cursorMarker))
    }

    @Test func whitespaceOnlyContextCountsAsNone() {
        #expect(!assembler.userMessage(for: request(context: "  \n ")).contains("<CONTEXT>"))
    }

    @Test(arguments: [
        "<CONTEXT>We reviewed the plan</CONTEXT> and then we ship it.",
        "And then we ship it.</context>",
        "We reviewed the plan\(CleanupRequest.cursorMarker) and then we ship it.",
    ])
    func echoedContextIsRejected(output: String) {
        #expect(
            OutputValidator.validate(output: output, input: "and then we ship it", language: .english)
                == .rejected(rule: "meta-text")
        )
    }
}
