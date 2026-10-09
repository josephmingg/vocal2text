import CoreModels
import Testing
import TextPipeline

/// docs/17 §5: the deterministic one-click styles.
struct StyleFormatterTests {

    private func styled(_ text: String, _ style: DictationStyle, terms: [String] = []) -> String {
        StyleFormatter.apply(text, style: style, language: .english, protectedTerms: terms)
    }

    @Test func standardAndRawPassThrough() {
        #expect(styled("Sounds good.", .standard) == "Sounds good.")
        #expect(styled("Sounds good.", .raw) == "Sounds good.")
    }

    @Test(arguments: [
        ("Sounds good.", "Sounds good"),
        ("See you at 3 pm.", "See you at 3 pm"),
    ])
    func casualDropsAOneLinerFullStop(input: String, expected: String) {
        #expect(styled(input, .casual) == expected)
    }

    @Test(arguments: [
        "We shipped it. Next is the docs.",
        "Are you coming?",
        "That's great!",
        "Wait...",
        "Meet me in the U.S.",
        "This sentence has far too many words to count as a quick chat one liner today.",
        "Line one.\nLine two.",
    ])
    func casualLeavesEverythingElse(input: String) {
        #expect(styled(input, .casual) == input)
    }

    @Test func lowercaseKeepsAcronymsInnerCapitalsAndDictionaryWords() {
        let out = styled(
            "Joseph said the API on my iPhone works with Claude Code.",
            .lowercase,
            terms: ["Claude Code"]
        )
        #expect(out == "joseph said the API on my iPhone works with Claude Code")
    }

    /// docs/17 §11: a dictionary "Al" must not keep the capital on "Also".
    @Test func lowercaseProtectsDictionaryTermsAsWholeWordsOnly() {
        let out = styled("Also Edit The Annual report for Al.", .lowercase, terms: ["Al", "Ed", "Ann"])
        #expect(out == "also edit the annual report for Al")
    }

    @Test func lowercaseLowercasesI() {
        #expect(styled("I think so. Do you?", .lowercase) == "i think so. do you?")
    }

    @Test func chineseIsNeverRestyled() {
        let out = StyleFormatter.apply("你好。", style: .lowercase, language: .chinese, protectedTerms: [])
        #expect(out == "你好。")
    }
}
