import CleanupKit
import CoreModels
import Foundation
import Testing

struct OutputValidatorTests {

    // Showcase fixture (docs/05 §3.3): ratio ≈ 0.22 on a short ZH input MUST pass.
    @Test func showcaseChineseSelfCorrectionIsAccepted() {
        let result = OutputValidator.validate(
            output: "周六",
            input: "周五，啊不对，周六",
            language: .chinese
        )
        #expect(result == .accepted(cleaned: "周六"))
    }

    // Showcase fixture (docs/05 §3.3): filler collapse on a short EN input MUST pass.
    @Test func showcaseEnglishFillerRemovalIsAccepted() {
        let result = OutputValidator.validate(
            output: "Saturday works.",
            input: "um, uh, so… Saturday works",
            language: .english
        )
        #expect(result == .accepted(cleaned: "Saturday works."))
    }

    @Test func longInputCollapsedBelowLowerBoundIsRejected() {
        let input = String(repeating: "the meeting is on saturday ", count: 4)
        #expect(input.count > 60)
        let result = OutputValidator.validate(
            output: "The meeting is on Saturday.",
            input: input,
            language: .english
        )
        #expect(result == .rejected(rule: "ratio"))
    }

    @Test func longInputOverExpandedIsRejected() {
        let input = String(repeating: "the meeting is on saturday ", count: 4)
        let output = String(repeating: "the meeting is on saturday ", count: 11)
        let result = OutputValidator.validate(output: output, input: input, language: .english)
        #expect(result == .rejected(rule: "ratio"))
    }

    @Test func shortInputOverExpandedIsRejected() {
        let result = OutputValidator.validate(
            output: "Hello there, it is truly wonderful to see you today.",
            input: "hi there",
            language: .english
        )
        #expect(result == .rejected(rule: "ratio"))
    }

    @Test func longChineseInputWithReasonableRatioIsAccepted() {
        let result = OutputValidator.validate(
            output: "今天下午开会讨论季度计划，然后再做决定。",
            input: "今天下午我们要开会讨论一下这个季度的计划安排然后再做决定",
            language: .chinese
        )
        #expect(result == .accepted(cleaned: "今天下午开会讨论季度计划，然后再做决定。"))
    }

    @Test func metaTextPrefixIsRejected() {
        let result = OutputValidator.validate(
            output: "Here is your cleaned text: meet on Saturday.",
            input: "meet on saturday",
            language: .english
        )
        #expect(result == .rejected(rule: "meta-text"))
    }

    @Test(arguments: [
        "以下是清理后的文本：周六",
        "好的，周六",
    ])
    func chineseMetaTextPrefixesAreRejected(output: String) {
        let result = OutputValidator.validate(
            output: output,
            input: "周五，啊不对，周六",
            language: .chinese
        )
        #expect(result == .rejected(rule: "meta-text"))
    }

    /// The meta-text rule looks for a preamble the *model* added. When the
    /// speaker themselves opened with one of those words, rejecting the output
    /// would make cleanup permanently useless for that phrasing.
    @Test(arguments: [
        ("Sure, sounds good.", "sure sounds good"),
        ("Here's the summary.", "here's the summary"),
        ("好的，我明天过去。", "好的我明天过去"),
    ])
    func markerAlreadyPresentInTheInputIsTheSpeakersOwnWord(output: String, input: String) {
        let language: Language = input.containsHanCharacters ? .chinese : .english
        let result = OutputValidator.validate(output: output, input: input, language: language)
        #expect(result == .accepted(cleaned: output))
    }

    @Test func markdownFenceAtStartIsRejected() {
        let result = OutputValidator.validate(
            output: "```\nmeet on Saturday\n```",
            input: "meet on saturday",
            language: .english
        )
        #expect(result == .rejected(rule: "meta-text"))
    }

    @Test func thinkBlocksAreStrippedBeforeValidation() {
        let output = "<think>\nFriday was corrected to Saturday.\n</think>\nmeet on Saturday"
        let result = OutputValidator.validate(
            output: output,
            input: "meet on friday sorry saturday",
            language: .english
        )
        #expect(result == .accepted(cleaned: "meet on Saturday"))
    }

    @Test func reasoningBlockIsStrippedBeforeValidation() {
        let result = OutputValidator.validate(
            output: "<reasoning>drop the false start</reasoning>周六",
            input: "周五，啊不对，周六",
            language: .chinese
        )
        #expect(result == .accepted(cleaned: "周六"))
    }

    @Test func outputThatIsOnlyAThinkBlockIsRejectedAsEmpty() {
        let result = OutputValidator.validate(
            output: "<thinking>nothing but thoughts</thinking>",
            input: "meet on saturday",
            language: .english
        )
        #expect(result == .rejected(rule: "empty"))
    }

    @Test(arguments: ["", "   \n\t  "])
    func emptyAndWhitespaceOutputsAreRejected(output: String) {
        let result = OutputValidator.validate(
            output: output,
            input: "meet on saturday",
            language: .english
        )
        #expect(result == .rejected(rule: "empty"))
    }

    @Test func hanInputRequiresHanOutput() {
        let result = OutputValidator.validate(
            output: "Saturday",
            input: "周五，啊不对，周六",
            language: .chinese
        )
        #expect(result == .rejected(rule: "language-mismatch"))
    }

    @Test func codeSwitchedChineseOutputKeepsHanAndIsAccepted() {
        let result = OutputValidator.validate(
            output: "用 Xcode 打开这个项目。",
            input: "嗯，用 Xcode 打开这个项目",
            language: .chinese
        )
        #expect(result == .accepted(cleaned: "用 Xcode 打开这个项目。"))
    }
}
