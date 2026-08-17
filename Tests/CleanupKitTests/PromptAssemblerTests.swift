import CleanupKit
import CoreModels
import Foundation
import Testing

struct PromptAssemblerTests {
    private let assembler = PromptAssembler()

    private func request(
        language: Language = .english,
        profile: String = "",
        style: String = "",
        protected: [String] = []
    ) -> CleanupRequest {
        CleanupRequest(
            text: "meet on friday sorry saturday",
            language: language,
            profilePrompt: profile,
            stylePrompt: style,
            protectedTerms: protected
        )
    }

    @Test func allPlaceholdersAreFilled() {
        let prompt = assembler.systemPrompt(
            for: request(profile: "Casual tone.", style: "British spelling.", protected: ["Claude"])
        )
        for placeholder in [
            "{LANGUAGE_RULES}", "{PROTECTED_TERMS}", "{PROFILE_PROMPT}", "{STYLE_PROMPT}",
        ] {
            #expect(!prompt.contains(placeholder))
        }
        #expect(prompt.contains("You transform raw dictated speech"))
        #expect(prompt.contains("Casual tone."))
        #expect(prompt.contains("British spelling."))
    }

    @Test func languageRulesFollowRequestLanguage() {
        let english = assembler.systemPrompt(for: request(language: .english))
        #expect(english.contains("half-width punctuation"))
        #expect(!english.contains("全角标点"))

        let chinese = assembler.systemPrompt(for: request(language: .chinese))
        #expect(chinese.contains("全角标点"))
        #expect(!chinese.contains("half-width punctuation"))
    }

    @Test func selfCorrectionCuesAreListed() {
        let prompt = assembler.systemPrompt(for: request())
        for cue in ["sorry", "I mean", "actually", "no wait", "scratch that", "make that",
                    "correction", "不对", "啊不对", "我是说"] {
            #expect(prompt.contains(cue))
        }
    }

    @Test func stylePromptAppearsAfterProfilePrompt() throws {
        let prompt = assembler.systemPrompt(
            for: request(profile: "PROFILE-MARKER-XYZ", style: "STYLE-MARKER-XYZ")
        )
        let profileRange = try #require(prompt.range(of: "PROFILE-MARKER-XYZ"))
        let styleRange = try #require(prompt.range(of: "STYLE-MARKER-XYZ"))
        #expect(profileRange.lowerBound < styleRange.lowerBound)
    }

    @Test func protectedTermsAreListedOnePerLine() {
        let prompt = assembler.systemPrompt(for: request(protected: ["Claude Code", "微信"]))
        #expect(prompt.contains("- Claude Code"))
        #expect(prompt.contains("- 微信"))
    }

    @Test func emptySlotsRenderAsNone() {
        let prompt = assembler.systemPrompt(for: request())
        #expect(prompt.contains("(none)"))
    }

    @Test func transcriptIsWrappedInTags() {
        let message = assembler.userMessage(for: request())
        #expect(message == "<TRANSCRIPT>\nmeet on friday sorry saturday\n</TRANSCRIPT>")
    }

    @Test func injectedTemplateSeamIsUsedVerbatim() {
        let custom = PromptAssembler(
            coreTemplate: "A {LANGUAGE_RULES} B {PROTECTED_TERMS} C {PROFILE_PROMPT} D {STYLE_PROMPT}",
            englishRules: "EN-RULES",
            chineseRules: "ZH-RULES"
        )
        let prompt = custom.systemPrompt(for: request(profile: "P", style: "S", protected: ["T"]))
        #expect(prompt == "A EN-RULES B - T C P D S")
    }
}

// MARK: - Burmese (v1.1)

struct BurmesePromptAssemblerTests {

    @Test func burmeseRequestGetsTheBurmeseRuleBlock() {
        let assembler = PromptAssembler(
            coreTemplate: "RULES: {LANGUAGE_RULES} TERMS: {PROTECTED_TERMS} "
                + "TASK: {PROFILE_PROMPT} STYLE: {STYLE_PROMPT}",
            languageRules: [
                .english: "english rules",
                .chinese: "chinese rules",
                .burmese: "burmese rules",
            ]
        )
        let prompt = assembler.systemPrompt(
            for: CleanupRequest(text: "ဒီနေ့", language: .burmese)
        )
        #expect(prompt.contains("burmese rules"))
        #expect(!prompt.contains("english rules"))
        #expect(!prompt.contains("chinese rules"))
    }

    /// A language with no bundled rule file must still produce a usable
    /// prompt rather than an empty LANGUAGE block.
    @Test func aMissingRuleBlockFallsBackToEnglish() {
        let assembler = PromptAssembler(
            coreTemplate: "RULES: {LANGUAGE_RULES}",
            languageRules: [.english: "english rules"]
        )
        let prompt = assembler.systemPrompt(
            for: CleanupRequest(text: "ဒီနေ့", language: .burmese)
        )
        #expect(prompt.contains("english rules"))
    }

    /// The real bundled resource, not an injected stub.
    @Test func bundledBurmeseRulesLoadAndForbidTranslation() {
        let prompt = PromptAssembler().systemPrompt(
            for: CleanupRequest(text: "ဒီနေ့", language: .burmese)
        )
        #expect(prompt.contains("Burmese"))
        #expect(prompt.lowercased().contains("never translate"))
        #expect(prompt.contains("။"))
    }
}
