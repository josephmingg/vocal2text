import CoreModels
import Foundation
import Testing
@testable import ASRKit

/// The rule that decides which language pipeline a dictation goes through.
/// Getting it wrong sends text through the wrong formatter, the wrong
/// dictionary semantics, the wrong cleanup prompt, and the wrong validator
/// thresholds — so both failure directions are pinned here: a wrong tag must
/// not beat an overwhelmingly contradicting script, and a couple of stray
/// characters must not beat a correct tag.
struct LanguageDetectorTests {

    private let burmese = "ဒီနေ့ ရာသီဥတု ကောင်းတယ်"
    private let chinese = "今天天气很好"
    private let english = "the weather is good today"

    // MARK: - A pin always wins

    @Test(arguments: Language.allCases)
    func pinBeatsEveryOtherSignal(language: Language) {
        // Text and tag both say Chinese; the pin says otherwise and wins.
        let detected = LanguageDetector.detect(
            reportedTag: "zh", text: chinese, mode: .pinned(language)
        )
        #expect(detected == language)
    }

    // MARK: - The tag is trusted; a dominant script overrides it

    @Test func dominantMyanmarScriptOverridesAWrongTag() {
        #expect(
            LanguageDetector.detect(reportedTag: "en", text: burmese, mode: .auto) == .burmese
        )
        #expect(
            LanguageDetector.detect(reportedTag: nil, text: burmese, mode: .auto) == .burmese
        )
    }

    @Test func dominantHanScriptOverridesAWrongTag() {
        #expect(
            LanguageDetector.detect(reportedTag: "en", text: chinese, mode: .auto) == .chinese
        )
        #expect(
            LanguageDetector.detect(reportedTag: nil, text: chinese, mode: .auto) == .chinese
        )
    }

    /// Regression pin (review round 2): script used to be a contains-any test
    /// that outranked the tag, so one 中 in an English sentence rerouted the
    /// whole take through the Chinese formatter, and one hallucinated Myanmar
    /// scalar — Whisper produces those on Burmese audio — silently rerouted an
    /// English take to Burmese, where cleanup is skipped entirely.
    @Test func strayCharactersDoNotOverrideTheTag() {
        #expect(
            LanguageDetector.detect(
                reportedTag: "en", text: "the character 中 means middle", mode: .auto
            ) == .english
        )
        #expect(
            LanguageDetector.detect(
                reportedTag: "en", text: "we visited the မ region", mode: .auto
            ) == .english
        )
    }

    /// Even with no tag at all, a stray character is not evidence.
    @Test func strayCharactersDoNotDecideWithoutATagEither() {
        #expect(
            LanguageDetector.detect(
                reportedTag: nil, text: "I met 王 at the office yesterday", mode: .auto
            ) == .english
        )
    }

    @Test func codeSwitchedBurmeseIsStillBurmese() {
        let mixed = "ဒီ feature က အရမ်းကောင်းတယ်"
        #expect(LanguageDetector.detect(reportedTag: "en", text: mixed, mode: .auto) == .burmese)
    }

    // MARK: - The reported tag settles Latin-script languages

    @Test func reportedTagIsUsedWhenTheScriptProvesNothing() {
        #expect(
            LanguageDetector.detect(reportedTag: "my", text: "mingalaba", mode: .auto) == .burmese
        )
        #expect(
            LanguageDetector.detect(reportedTag: "zh", text: "ni hao", mode: .auto) == .chinese
        )
    }

    @Test(arguments: ["my", "MY", "my-MM", "my_MM"])
    func tagSpellingsEnginesActuallyEmitAreAccepted(tag: String) {
        #expect(LanguageDetector.detect(reportedTag: tag, text: "romanized", mode: .auto) == .burmese)
    }

    @Test func unknownTagsFallBackToEnglishRatherThanTheNearestCase() {
        #expect(LanguageDetector.detect(reportedTag: "ja", text: english, mode: .auto) == .english)
        #expect(LanguageDetector.detect(reportedTag: "", text: english, mode: .auto) == .english)
        #expect(LanguageDetector.detect(reportedTag: nil, text: "", mode: .auto) == .english)
    }

    // MARK: - Dominance predicate

    @Test func dominanceRequiresAMajorityOfLetters() {
        #expect(LanguageDetector.dominantScriptLanguage(of: chinese) == .chinese)
        #expect(LanguageDetector.dominantScriptLanguage(of: burmese) == .burmese)
        #expect(LanguageDetector.dominantScriptLanguage(of: english) == nil)
        #expect(LanguageDetector.dominantScriptLanguage(of: "I met 王 yesterday") == nil)
        #expect(LanguageDetector.dominantScriptLanguage(of: "") == nil)
        // Digits and punctuation are not letters and prove nothing.
        #expect(LanguageDetector.dominantScriptLanguage(of: "၀၉၇၉၁၂၃၄၅၆") == nil)
    }
}
