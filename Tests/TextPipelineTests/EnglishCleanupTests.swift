import CoreModels
import Testing
@testable import TextPipeline

struct EnglishCleanupTests {
    private func normalize(_ text: String, _ formatting: FormattingOptions = .init()) -> String {
        Stage1Normalizer.normalize(text, language: .english, formatting: formatting)
    }

    // MARK: - Fillers

    @Test(arguments: [
        ("Um, I think we should go.", "I think we should go."),
        ("Uh... so what's the plan?", "So what's the plan?"),
        ("I, uh, think we should go.", "I think we should go."),
        ("So uh we should go now.", "So we should go now."),
        ("So uh, we should go now.", "So we should go now."),
        ("I think that's right, um.", "I think that's right."),
        ("We shipped it. Um, next is the docs.", "We shipped it. Next is the docs."),
        ("Hmm, let me check the numbers.", "Let me check the numbers."),
        ("Erm, the build is green.", "The build is green."),
        ("Umm uhh the build is green.", "The build is green."),
    ])
    func fillersAreRemoved(input: String, expected: String) {
        #expect(normalize(input) == expected)
    }

    @Test func fillerOnlyTranscriptBecomesEmpty() {
        #expect(normalize("Um.") == "")
        #expect(normalize("Uh...") == "")
    }

    @Test(arguments: [
        "Uh-huh, that works for me.",
        "Mhm, that works for me.",
        "The ummah gathered today.",
        "Their hummus was great today.",
        "To err is human, they say.",
    ])
    func contentWordsThatLookLikeFillersSurvive(input: String) {
        #expect(normalize(input) == input)
    }

    // MARK: - Stutters

    @Test(arguments: [
        ("I I think we should go.", "I think we should go."),
        ("I, I think we should go.", "I think we should go."),
        ("Put it on the the table.", "Put it on the table."),
        ("Put it on the the the table.", "Put it on the table."),
        ("We we need to to ship it.", "We need to ship it."),
        ("Put it on the, um, the table.", "Put it on the table."),
    ])
    func stuttersCollapse(input: String, expected: String) {
        #expect(normalize(input) == expected)
    }

    @Test(arguments: [
        "I know that that is true.",
        "She had had enough of it.",
        "What it is is a bug.",
        "It was very very good.",
        "No no, that's fine.",
    ])
    func grammaticalDoublesSurvive(input: String) {
        #expect(normalize(input) == input)
    }

    // MARK: - Gating

    @Test func verbatimProfileGetsNoCleanup() {
        #expect(normalize("um the the ls", .verbatim) == "um the the ls")
    }

    @Test func chineseIsUntouched() {
        let out = Stage1Normalizer.normalize("um 你好", language: .chinese, formatting: .init())
        #expect(out == "um 你好")
    }
}
