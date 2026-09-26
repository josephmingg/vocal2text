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

    /// Review finding: short terms used to flag ordinary words near them.
    @Test(arguments: [
        ("The AI model is a good one.", "the AI model is a good one", "AI"),
        ("Wait, the AI is ready.", "wait, the AI is ready", "AI"),
        ("我相信微信会更新。", "我相信微信会更新", "微信"),
    ])
    func wordsTheSpeakerSaidAreNotMutationsOfAShortTerm(
        output: String, input: String, term: String
    ) {
        #expect(ProtectedTermsVerifier.verify(output: output, input: input, protectedTerms: [term]))
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

    // MARK: - Repair (docs/15 step 25)

    @Test func aTransposedTermIsRepairedToTheExactSpelling() {
        let repaired = ProtectedTermsVerifier.repaired(
            output: "ask Cluade to review it",
            input: "ask Claude to review it",
            protectedTerms: ["Claude"]
        )
        #expect(repaired == "ask Claude to review it")
    }

    @Test func aCaseMutationIsRepaired() {
        let repaired = ProtectedTermsVerifier.repaired(
            output: "the vocal2text repo",
            input: "the Vocal2Text repo",
            protectedTerms: ["Vocal2Text"]
        )
        #expect(repaired == "the Vocal2Text repo")
    }

    @Test func multipleMutationsOfOneTermAreAllRepaired() {
        let repaired = ProtectedTermsVerifier.repaired(
            output: "Cluade helped, then cluade helped again",
            input: "Claude helped, then Claude helped again",
            protectedTerms: ["Claude"]
        )
        #expect(repaired == "Claude helped, then Claude helped again")
    }

    @Test func cleanOutputIsUntouchedByRepair() {
        let output = "ask Claude to review it"
        let repaired = ProtectedTermsVerifier.repaired(
            output: output,
            input: output,
            protectedTerms: ["Claude"]
        )
        #expect(repaired == output)
    }

    @Test func aTermAbsentFromTheInputIsNotRepairedIn() {
        // Absence is legitimate (a self-correction can delete a term); repair
        // only fixes spellings of terms the *input* actually contained.
        let output = "we shipped the fix"
        let repaired = ProtectedTermsVerifier.repaired(
            output: output,
            input: "we shipped the fix",
            protectedTerms: ["Claude"]
        )
        #expect(repaired == output)
    }

    @Test func aTermEmbeddedInAnotherWordIsNeverRepairedIntoIt() {
        // "ai" occurs inside "Wait" at distance 0 — repair must not produce
        // "WAIt"; the window is glued to letters, so it is left for verify()
        // to reject (fallback), never rewritten.
        let output = "Wait, the AI is ready"
        let repaired = ProtectedTermsVerifier.repaired(
            output: output,
            input: "Wait, the AI is ready",
            protectedTerms: ["AI"]
        )
        #expect(repaired == output)
    }

    @Test func repairNeverGluesTheTermToTheNextWord() {
        // The flagged window for "Claud " includes the separating space; a
        // naive repair yields "Claudepushed". The neighbor guard leaves it
        // to the fallback instead.
        let output = "Claud pushed the fix"
        let repaired = ProtectedTermsVerifier.repaired(
            output: output,
            input: "Claude pushed the fix",
            protectedTerms: ["Claude"]
        )
        #expect(repaired == output)
    }

    @Test func repairedOutputPassesVerification() {
        let repaired = ProtectedTermsVerifier.repaired(
            output: "open Cluade Code now",
            input: "open Claude Code now",
            protectedTerms: ["Claude Code"]
        )
        #expect(repaired == "open Claude Code now")
        #expect(
            ProtectedTermsVerifier.verify(
                output: repaired,
                input: "open Claude Code now",
                protectedTerms: ["Claude Code"]
            )
        )
    }
}
