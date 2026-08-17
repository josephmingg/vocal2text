import CoreModels
import Foundation
import Testing
@testable import ASRKit

/// The rule that decides which language pipeline a dictation goes through.
/// Getting it wrong sends Burmese text through the English formatter (which
/// would capitalize and append a Latin period) or the reverse.
struct LanguageDetectorTests {

    private let burmese = "မင်္ဂလာပါ ဒီနေ့ ရာသီဥတု ကောင်းတယ်"
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

    // MARK: - Script is proof

    @Test func myanmarScriptWinsOverAWrongReportedTag() {
        // Whisper's language ID is a whole-clip guess made before decoding and
        // is routinely wrong on short utterances — but it cannot invent
        // Myanmar characters for an English sentence.
        #expect(
            LanguageDetector.detect(reportedTag: "en", text: burmese, mode: .auto) == .burmese
        )
        #expect(
            LanguageDetector.detect(reportedTag: nil, text: burmese, mode: .auto) == .burmese
        )
    }

    @Test func hanScriptWinsOverAWrongReportedTag() {
        #expect(
            LanguageDetector.detect(reportedTag: "en", text: chinese, mode: .auto) == .chinese
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

    // MARK: - Script probe

    @Test func scriptLanguageReportsNilForSharedScripts() {
        #expect(LanguageDetector.scriptLanguage(of: burmese) == .burmese)
        #expect(LanguageDetector.scriptLanguage(of: chinese) == .chinese)
        #expect(LanguageDetector.scriptLanguage(of: english) == nil)
        #expect(LanguageDetector.scriptLanguage(of: "") == nil)
    }
}
