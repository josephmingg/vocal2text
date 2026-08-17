import CleanupKit
import Testing

struct ProtectedTermsVerifierTests {

    // Deletion is tolerated (docs/05 §3.4): a self-correction may drop a term.
    @Test func deletionOfProtectedTermIsTolerated() {
        #expect(
            ProtectedTermsVerifier.verify(
                output: "send it to Bob",
                input: "send it to Alice — no wait, to Bob",
                protectedTerms: ["Alice"]
            )
        )
    }

    @Test func editDistanceOneMutationIsRejected() {
        #expect(
            !ProtectedTermsVerifier.verify(
                output: "ask Cluade to review it",
                input: "ask Claude to review it",
                protectedTerms: ["Claude"]
            )
        )
    }

    @Test func caseMutationIsRejected() {
        #expect(
            !ProtectedTermsVerifier.verify(
                output: "claude wrote the draft",
                input: "Claude wrote the draft",
                protectedTerms: ["Claude"]
            )
        )
    }

    @Test func exactTermPassesVerification() {
        #expect(
            ProtectedTermsVerifier.verify(
                output: "ask Claude to review it",
                input: "ask Claude to review it, um, today",
                protectedTerms: ["Claude"]
            )
        )
    }

    @Test func termAbsentFromInputIsNotChecked() {
        #expect(
            ProtectedTermsVerifier.verify(
                output: "we shipped claude yesterday",
                input: "we shipped it yesterday",
                protectedTerms: ["Claude"]
            )
        )
    }

    @Test func singleCharacterDeletionInsideTermIsRejected() {
        #expect(
            !ProtectedTermsVerifier.verify(
                output: "Claud pushed the fix",
                input: "Claude pushed the fix",
                protectedTerms: ["Claude"]
            )
        )
    }

    @Test func chineseTermMutationIsRejected() {
        #expect(
            !ProtectedTermsVerifier.verify(
                output: "我在威信上给你发消息",
                input: "我在微信上给你发消息",
                protectedTerms: ["微信"]
            )
        )
    }

    @Test func chineseExactTermPasses() {
        #expect(
            ProtectedTermsVerifier.verify(
                output: "我在微信上给你发消息",
                input: "我在微信上给你发消息",
                protectedTerms: ["微信"]
            )
        )
    }

    @Test func multiWordTermMutationIsRejected() {
        #expect(
            !ProtectedTermsVerifier.verify(
                output: "open Cluade Code now",
                input: "open Claude Code now",
                protectedTerms: ["Claude Code"]
            )
        )
    }

    @Test func emptyTermListAlwaysPasses() {
        #expect(
            ProtectedTermsVerifier.verify(
                output: "anything at all",
                input: "anything at all",
                protectedTerms: []
            )
        )
    }
}
