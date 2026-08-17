import CoreModels
import Foundation
import Testing
@testable import TextPipeline

/// The Burmese text layer (docs/04 Appendix A).
struct MyTextTests {

    // MARK: - Digits

    @Test func myanmarDigitsConvertBothWays() {
        #expect(MyText.applyingDigitPreference("၁၂၃", .western) == "123")
        #expect(MyText.applyingDigitPreference("2024", .myanmar) == "၂၀၂၄")
        #expect(MyText.applyingDigitPreference("၁၂၃", .myanmar) == "၁၂၃")
        #expect(MyText.applyingDigitPreference("123", .western) == "123")
    }

    @Test func asRecognizedLeavesDigitsUntouched() {
        #expect(MyText.applyingDigitPreference("၁၂၃ and 456", .asRecognized) == "၁၂၃ and 456")
    }

    @Test func digitConversionLeavesLettersAlone() {
        let text = "ဒီနေ့ ၁၀ နာရီ"
        let western = MyText.applyingDigitPreference(text, .western)
        #expect(western.contains("10"))
        #expect(western.contains("ဒီနေ့"))
        #expect(western.contains("နာရီ"))
    }

    // MARK: - Spoken punctuation

    /// The Myanmar-script command words that shipped briefly in this branch
    /// were byte-identical to ordinary vocabulary — ပုဒ်မ is the everyday word
    /// for "section/article" — and a substring match destroyed it. These
    /// fixtures are the destruction cases; they must pass through untouched
    /// forever.
    @Test(arguments: [
        "ပုဒ်မ ၅",  // "Section 5"
        "ပုဒ်မခွဲ",  // "sub-section"
        "စာပုဒ်မရှိပါ",  // paragraph + negated verb
        "ပုဒ်ဖြတ်သင်္ကေတ",  // "punctuation symbol"
    ])
    func burmeseVocabularyIsNeverRewritten(text: String) {
        #expect(MyText.spokenPunctuationApplied(text) == text)
    }

    @Test func englishCommandWordsWorkForCodeSwitchingSpeakers() {
        #expect(MyText.spokenPunctuationApplied("ဒီနေ့ full stop") == "ဒီနေ့။")
        #expect(MyText.spokenPunctuationApplied("ဒီနေ့ comma မနက်ဖြန်") == "ဒီနေ့၊မနက်ဖြန်")
    }

    /// A Latin command must be a standalone word, or ordinary English embedded
    /// in a Burmese sentence starts sprouting punctuation.
    @Test func aLatinCommandInsideAWordIsNotACommand() {
        #expect(MyText.spokenPunctuationApplied("ဒီ periodic review") == "ဒီ periodic review")
        #expect(MyText.spokenPunctuationApplied("ဒီ commander") == "ဒီ commander")
    }

    @Test func adjacentMarksCollapse() {
        #expect(MyText.spokenPunctuationApplied("စာ comma full stop") == "စာ။")
    }

    @Test func textWithNoCommandsIsUnchanged() {
        let text = "ဒီနေ့ ရာသီဥတု ကောင်းတယ်"
        #expect(MyText.spokenPunctuationApplied(text) == text)
    }

    // MARK: - Spacing

    @Test func spaceBeforeAMarkIsRemoved() {
        #expect(MyText.tidiedSpacing("မင်္ဂလာပါ ။") == "မင်္ဂလာပါ။")
        #expect(MyText.tidiedSpacing("စာ   ၊ ရေး") == "စာ၊ ရေး")
    }

    /// Myanmar is unspaced, but the spaces a writer does use separate phrases.
    /// Only doubled spaces and pre-mark spaces are unambiguously wrong.
    @Test func meaningfulSpacesSurvive() {
        #expect(MyText.tidiedSpacing("ဒီနေ့ ရာသီဥတု") == "ဒီနေ့ ရာသီဥတု")
        #expect(MyText.tidiedSpacing("ဒီနေ့  ရာသီဥတု") == "ဒီနေ့ ရာသီဥတု")
    }

    // MARK: - Terminal mark

    @Test func aSentenceLikeUtteranceGetsASectionMark() {
        let text = "ဒီနေ့ရာသီဥတုကောင်းတယ်"
        #expect(MyText.appendingSectionIfSentenceLike(text) == text + "။")
    }

    @Test func anExistingTerminalMarkIsNotDoubled() {
        let text = "ဒီနေ့ရာသီဥတုကောင်းတယ်။"
        #expect(MyText.appendingSectionIfSentenceLike(text) == text)
    }

    @Test func shortInterjectionsAreLeftAlone() {
        #expect(MyText.appendingSectionIfSentenceLike("ဟုတ်") == "ဟုတ်")
        #expect(MyText.appendingSectionIfSentenceLike("") == "")
    }

    /// A dictated phone number is not a sentence, however many characters.
    @Test func digitOnlyTextGetsNoSectionMark() {
        #expect(MyText.appendingSectionIfSentenceLike("၀၉၇၉၁၂၃၄၅၆") == "၀၉၇၉၁၂၃၄၅၆")
        #expect(MyText.appendingSectionIfSentenceLike("123 456") == "123 456")
    }

    /// ~Two syllables: မလုပ်ဘူး ("won't do it") is a complete sentence and
    /// deserves its mark — the floor must not treat it as an interjection.
    @Test func shortCompleteSentencesGetTheMark() {
        #expect(MyText.appendingSectionIfSentenceLike("မလုပ်ဘူး") == "မလုပ်ဘူး။")
    }

    // MARK: - Normalization

    @Test func nfcNormalizationIsIdempotent() {
        let text = "မင်္ဂလာပါ"
        let once = MyText.normalizedToNFC(text)
        #expect(MyText.normalizedToNFC(once) == once)
    }
}

/// Zawgyi and Unicode occupy the same Myanmar code points, so telling them
/// apart is structural: each produces sequences the other never does.
struct ZawgyiDetectorTests {

    @Test func nonMyanmarTextIsNeverZawgyi() {
        #expect(!ZawgyiDetector.isZawgyi(""))
        #expect(!ZawgyiDetector.isZawgyi("hello there"))
        #expect(!ZawgyiDetector.isZawgyi("今天天气很好"))
    }

    /// Unicode stores the ေ vowel after its consonant.
    @Test func unicodeVowelOrderIsRecognizedAsUnicode() {
        #expect(!ZawgyiDetector.isZawgyi("\u{1000}\u{1031}"))
        #expect(!ZawgyiDetector.isZawgyi("မင်္ဂလာပါ"))
        #expect(!ZawgyiDetector.isZawgyi("ဒီနေ့ ရာသီဥတု ကောင်းတယ်"))
    }

    /// Zawgyi stores it before — the visual order, not the logical one.
    @Test func zawgyiVowelOrderIsRecognizedAsZawgyi() {
        #expect(ZawgyiDetector.isZawgyi("\u{1031}\u{1000}"))
    }

    /// U+1060–U+109D are Shan/Mon letters in Unicode that Burmese text never
    /// uses, but Zawgyi reuses them for common Burmese glyph variants.
    @Test func zawgyiOnlyCodePointsAreDecisive() {
        #expect(ZawgyiDetector.isZawgyi("\u{1000}\u{1064}\u{1001}"))
        #expect(ZawgyiDetector.isZawgyi("\u{1000}\u{107E}\u{1001}"))
    }

    /// Conservative by design: converting real Unicode is lossy and far more
    /// damaging than leaving rare Zawgyi alone, so ambiguity means Unicode.
    @Test func ambiguousMyanmarTextIsTreatedAsUnicode() {
        #expect(!ZawgyiDetector.isZawgyi("\u{1000}"))
        #expect(!ZawgyiDetector.isZawgyi("\u{1000}\u{1001}\u{1002}"))
    }
}
