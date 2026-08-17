import CoreModels
import Testing
import TextPipeline

struct Stage1NormalizerTests {
    private let defaults = FormattingOptions()

    // MARK: - English, default formatting

    @Test func trimsCollapsesCapitalizesAndTerminates() {
        let out = Stage1Normalizer.normalize("  hello   world here  ", language: .english, formatting: defaults)
        #expect(out == "Hello world here.")
    }

    @Test func shortUtteranceGetsNoTerminalPeriod() {
        let out = Stage1Normalizer.normalize("hi there", language: .english, formatting: defaults)
        #expect(out == "Hi there")
    }

    @Test func existingTerminalPunctuationIsKept() {
        let out = Stage1Normalizer.normalize("how are you?", language: .english, formatting: defaults)
        #expect(out == "How are you?")
    }

    @Test func trailingCommaBlocksPeriodAppend() {
        let out = Stage1Normalizer.normalize("well you know,", language: .english, formatting: defaults)
        #expect(out == "Well you know,")
    }

    @Test func alreadyCapitalizedTextIsUntouched() {
        let out = Stage1Normalizer.normalize("Hello world here.", language: .english, formatting: defaults)
        #expect(out == "Hello world here.")
    }

    @Test func emojiIsPreservedAndPeriodAppendedAfterIt() {
        let out = Stage1Normalizer.normalize("i love this 🎉", language: .english, formatting: defaults)
        #expect(out == "I love this 🎉.")
    }

    @Test func decimalNumbersAreNotTouched() {
        let out = Stage1Normalizer.normalize("the value is 3.14 exactly", language: .english, formatting: defaults)
        #expect(out == "The value is 3.14 exactly.")
    }

    @Test func emptyInputStaysEmpty() {
        #expect(Stage1Normalizer.normalize("", language: .english, formatting: defaults) == "")
        #expect(Stage1Normalizer.normalize("", language: .chinese, formatting: defaults) == "")
    }

    @Test func whitespaceOnlyInputBecomesEmpty() {
        let out = Stage1Normalizer.normalize("   \n  ", language: .english, formatting: defaults)
        #expect(out == "")
    }

    // MARK: - Artifact stripping (always on)

    @Test func blankAudioTagAloneBecomesEmpty() {
        let out = Stage1Normalizer.normalize("[BLANK_AUDIO]", language: .english, formatting: defaults)
        #expect(out == "")
    }

    @Test func silenceAndMusicTagsAreStripped() {
        let out = Stage1Normalizer.normalize(" [SILENCE] okay [MUSIC] ", language: .english, formatting: defaults)
        #expect(out == "Okay")
    }

    @Test func laughsParenTagIsStripped() {
        let out = Stage1Normalizer.normalize("so funny (laughs) right now", language: .english, formatting: defaults)
        #expect(out == "So funny right now.")
    }

    @Test func whisperSpecialTokensAreStripped() {
        let out = Stage1Normalizer.normalize(
            "<|startoftranscript|><|en|>hello world friends<|endoftext|>",
            language: .english,
            formatting: defaults
        )
        #expect(out == "Hello world friends.")
    }

    @Test func nospeechTokenAloneBecomesEmpty() {
        let out = Stage1Normalizer.normalize("<|nospeech|>", language: .english, formatting: defaults)
        #expect(out == "")
    }

    @Test func repeatedTokenLoopCollapsesToOneOccurrence() {
        let out = Stage1Normalizer.normalize("the the the the the cat sat", language: .english, formatting: defaults)
        #expect(out == "The cat sat.")
    }

    @Test func tripleRepetitionIsLegitimateSpeechAndKept() {
        let out = Stage1Normalizer.normalize("very very very good day", language: .english, formatting: defaults)
        #expect(out == "Very very very good day.")
    }

    @Test func leadingOrphanPunctuationIsStripped() {
        let out = Stage1Normalizer.normalize(". hello world friends", language: .english, formatting: defaults)
        #expect(out == "Hello world friends.")
    }

    @Test func zhLeadingOrphanPunctuationIsStripped() {
        let out = Stage1Normalizer.normalize("。你好", language: .chinese, formatting: defaults)
        #expect(out == "你好")
    }

    @Test func zhParenMusicTagIsStripped() {
        let out = Stage1Normalizer.normalize("（音乐）你好呀", language: .chinese, formatting: defaults)
        #expect(out == "你好呀")
    }

    @Test func zhRepeatedTokenLoopCollapses() {
        let out = Stage1Normalizer.normalize("谢谢 谢谢 谢谢 谢谢", language: .chinese, formatting: defaults)
        #expect(out == "谢谢")
    }

    // MARK: - Verbatim gating

    @Test func verbatimSkipsCapitalizationAndPeriod() {
        let out = Stage1Normalizer.normalize("hello   world", language: .english, formatting: .verbatim)
        #expect(out == "hello world")
    }

    @Test func verbatimStillStripsArtifacts() {
        let out = Stage1Normalizer.normalize("[BLANK_AUDIO] git status now", language: .english, formatting: .verbatim)
        #expect(out == "git status now")
    }

    @Test func verbatimStillCollapsesTokenLoops() {
        let out = Stage1Normalizer.normalize("go go go go go now", language: .english, formatting: .verbatim)
        #expect(out == "go now")
    }

    @Test func verbatimLeavesZhPunctuationAndSpacingAlone() {
        let out = Stage1Normalizer.normalize("你好,世 界", language: .chinese, formatting: .verbatim)
        #expect(out == "你好,世 界")
    }

    // MARK: - Chinese, default formatting

    @Test func halfWidthCommaBetweenHanBecomesFullWidth() {
        let out = Stage1Normalizer.normalize("你好,世界", language: .chinese, formatting: defaults)
        #expect(out == "你好，世界")
    }

    @Test func halfWidthPeriodBetweenHanBecomesFullWidth() {
        let out = Stage1Normalizer.normalize("今天天气很好.明天见", language: .chinese, formatting: defaults)
        #expect(out == "今天天气很好。明天见")
    }

    @Test func halfWidthColonBetweenHanBecomesFullWidth() {
        let out = Stage1Normalizer.normalize("他说:你来", language: .chinese, formatting: defaults)
        #expect(out == "他说：你来")
    }

    @Test func halfWidthPunctuationNextToSpaceIsNotConverted() {
        let out = Stage1Normalizer.normalize("你好, 世界", language: .chinese, formatting: defaults)
        #expect(out == "你好, 世界")
    }

    @Test func singleSpacesBetweenHanAreRemoved() {
        let out = Stage1Normalizer.normalize("我 很 好", language: .chinese, formatting: defaults)
        #expect(out == "我很好")
    }

    @Test func doubleSpacesBetweenHanAreKept() {
        let out = Stage1Normalizer.normalize("我  好", language: .chinese, formatting: defaults)
        #expect(out == "我  好")
    }

    @Test func decimalInsideHanTextIsNotConverted() {
        let out = Stage1Normalizer.normalize("圆周率是3.14左右", language: .chinese, formatting: defaults)
        #expect(out == "圆周率是3.14左右")
    }

    @Test func combinedZhSpacingAndPunctuationRepair() {
        let out = Stage1Normalizer.normalize("你 好,世 界", language: .chinese, formatting: defaults)
        #expect(out == "你好，世界")
    }

    // MARK: - Code-switching

    @Test func codeSwitchedSentenceIsUntouched() {
        let out = Stage1Normalizer.normalize("我觉得这个 implementation 很好", language: .chinese, formatting: defaults)
        #expect(out == "我觉得这个 implementation 很好")
    }

    @Test func halfWidthCommaTouchingLatinIsNotConverted() {
        let out = Stage1Normalizer.normalize("我在用Swift,感觉不错", language: .chinese, formatting: defaults)
        #expect(out == "我在用Swift,感觉不错")
    }
}
