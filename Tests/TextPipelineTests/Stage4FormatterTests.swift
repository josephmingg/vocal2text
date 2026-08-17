import CoreModels
import Testing
import TextPipeline

struct Stage4FormatterTests {
    private let defaults = FormattingOptions()

    // MARK: - English duplicate terminal punctuation

    @Test func duplicateExclamationsCollapse() {
        let out = Stage4Formatter.format("Really!!", language: .english, formatting: defaults, precedingContext: nil)
        #expect(out == "Really!")
    }

    @Test func mixedRunKeepsFirstMark() {
        let out = Stage4Formatter.format("What?.", language: .english, formatting: defaults, precedingContext: nil)
        #expect(out == "What?")
    }

    @Test func interrobangCollapsesToQuestionMark() {
        let out = Stage4Formatter.format("Seriously?!", language: .english, formatting: defaults, precedingContext: nil)
        #expect(out == "Seriously?")
    }

    @Test func asciiEllipsisCollapsesToPeriod() {
        let out = Stage4Formatter.format("Wait...", language: .english, formatting: defaults, precedingContext: nil)
        #expect(out == "Wait.")
    }

    @Test func abbreviationsAndDecimalsAreUntouched() {
        let out = Stage4Formatter.format(
            "See the U.S. report on 3.14 today.",
            language: .english,
            formatting: defaults,
            precedingContext: nil
        )
        #expect(out == "See the U.S. report on 3.14 today.")
    }

    @Test func autoPunctuationOffKeepsDuplicates() {
        let options = FormattingOptions(autoPunctuation: false)
        let out = Stage4Formatter.format("Really!!", language: .english, formatting: options, precedingContext: nil)
        #expect(out == "Really!!")
    }

    @Test func zhTextNeverGetsDuplicateCollapse() {
        let out = Stage4Formatter.format("哇!!", language: .chinese, formatting: defaults, precedingContext: nil)
        #expect(out == "哇!!")
    }

    // MARK: - Smart spacing against preceding context

    @Test func prependsSpaceAfterNonWhitespaceContext() {
        let out = Stage4Formatter.format(
            "and another thing",
            language: .english,
            formatting: defaults,
            precedingContext: "previous text"
        )
        #expect(out == " and another thing")
    }

    @Test func capitalizesAfterSentenceTerminator() {
        let out = Stage4Formatter.format("it works", language: .english, formatting: defaults, precedingContext: "Done.")
        #expect(out == " It works")
    }

    @Test func capitalizesAfterTerminatorWithTrailingSpace() {
        let out = Stage4Formatter.format("it works", language: .english, formatting: defaults, precedingContext: "Done. ")
        #expect(out == "It works")
    }

    @Test func capitalizesAfterFullWidthTerminator() {
        let out = Stage4Formatter.format("it works", language: .english, formatting: defaults, precedingContext: "好的。")
        #expect(out == " It works")
    }

    @Test func nilContextMeansFreshInsertionPoint() {
        let out = Stage4Formatter.format("it works", language: .english, formatting: defaults, precedingContext: nil)
        #expect(out == "it works")
    }

    @Test func emptyContextAddsNothing() {
        let out = Stage4Formatter.format("it works", language: .english, formatting: defaults, precedingContext: "")
        #expect(out == "it works")
    }

    @Test func smartSpacingOffLeavesTextAlone() {
        let options = FormattingOptions(smartSpacing: false)
        let out = Stage4Formatter.format("it works", language: .english, formatting: options, precedingContext: "Done.")
        #expect(out == "it works")
    }

    @Test func zhGetsNoPrefixSpaceOrCapitalization() {
        let out = Stage4Formatter.format("你好", language: .chinese, formatting: defaults, precedingContext: "前面的话。")
        #expect(out == "你好")
    }

    @Test func emojiTextWithSmartSpacing() {
        let out = Stage4Formatter.format("nice 🎉", language: .english, formatting: defaults, precedingContext: "Done.")
        #expect(out == " Nice 🎉")
    }

    @Test func combinedEnglishFlow() {
        let out = Stage4Formatter.format("what?!", language: .english, formatting: defaults, precedingContext: "Hi there.")
        #expect(out == " What?")
    }

    // MARK: - Chinese full-width enforcement

    @Test func fullWidthEnforcedBetweenHan() {
        let out = Stage4Formatter.format("你好,世界", language: .chinese, formatting: defaults, precedingContext: nil)
        #expect(out == "你好，世界")
    }

    @Test func fullWidthGateOffLeavesHalfWidth() {
        let options = FormattingOptions(enforceFullWidthZhPunctuation: false)
        let out = Stage4Formatter.format("你好,世界", language: .chinese, formatting: options, precedingContext: nil)
        #expect(out == "你好,世界")
    }

    @Test func verbatimPassesEverythingThrough() {
        let out = Stage4Formatter.format(
            "really!! 你好,世界",
            language: .english,
            formatting: .verbatim,
            precedingContext: "Done."
        )
        #expect(out == "really!! 你好,世界")
    }

    // MARK: - Pangu spacing

    @Test func panguInsertsThinSpacesAroundLatinRun() {
        let options = FormattingOptions(panguSpacing: true)
        let out = Stage4Formatter.format("我用Swift写代码", language: .chinese, formatting: options, precedingContext: nil)
        #expect(out == "我用\u{2009}Swift\u{2009}写代码")
    }

    @Test func panguInsertsThinSpacesAroundDigits() {
        let options = FormattingOptions(panguSpacing: true)
        let out = Stage4Formatter.format("共有3个人", language: .chinese, formatting: options, precedingContext: nil)
        #expect(out == "共有\u{2009}3\u{2009}个人")
    }

    @Test func panguRespectsExistingSpaces() {
        let options = FormattingOptions(panguSpacing: true)
        let out = Stage4Formatter.format(
            "我觉得这个 implementation 很好",
            language: .chinese,
            formatting: options,
            precedingContext: nil
        )
        #expect(out == "我觉得这个 implementation 很好")
    }

    @Test func panguIsIdempotent() {
        let options = FormattingOptions(panguSpacing: true)
        let once = Stage4Formatter.format("我用Swift写代码", language: .chinese, formatting: options, precedingContext: nil)
        let twice = Stage4Formatter.format(once, language: .chinese, formatting: options, precedingContext: nil)
        #expect(once == twice)
    }

    @Test func panguOffByDefault() {
        let out = Stage4Formatter.format("我用Swift写代码", language: .chinese, formatting: defaults, precedingContext: nil)
        #expect(out == "我用Swift写代码")
    }

    // MARK: - Edge cases

    @Test func emptyTextStaysEmpty() {
        let out = Stage4Formatter.format("", language: .english, formatting: defaults, precedingContext: "Done.")
        #expect(out == "")
    }
}

// MARK: - Burmese (v1.1)

@Test func burmeseDigitPreferenceIsApplied() {
    let result = Stage4Formatter.format(
        "ဒီနေ့ ၁၀ နာရီ",
        language: .burmese,
        formatting: FormattingOptions(myanmarDigits: .western),
        precedingContext: nil
    )
    #expect(result == "ဒီနေ့ 10 နာရီ")
}

@Test func burmeseDigitPreferenceDefaultsToLeavingThemAlone() {
    let text = "ဒီနေ့ ၁၀ နာရီ"
    let result = Stage4Formatter.format(
        text, language: .burmese, formatting: FormattingOptions(), precedingContext: nil
    )
    #expect(result == text)
}

/// The digit set is a display preference rather than punctuation, so a
/// verbatim profile still honors it — a Burmese user who asked for Myanmar
/// numerals wants them in the terminal too.
@Test func verbatimBurmeseStillHonorsTheDigitPreference() {
    var formatting = FormattingOptions.verbatim
    formatting.myanmarDigits = .myanmar
    let result = Stage4Formatter.format(
        "10 နာရီ", language: .burmese, formatting: formatting, precedingContext: nil
    )
    #expect(result == "၁၀ နာရီ")
}

@Test func burmeseNeverGetsChineseOrEnglishRules() {
    // Full-width conversion and pangu spacing are Chinese-only; smart spacing
    // and duplicate-terminal collapsing are English-only.
    let result = Stage4Formatter.format(
        "ဒီနေ့,ကောင်းတယ်",
        language: .burmese,
        formatting: FormattingOptions(panguSpacing: true),
        precedingContext: "Done."
    )
    #expect(result == "ဒီနေ့,ကောင်းတယ်")
}
