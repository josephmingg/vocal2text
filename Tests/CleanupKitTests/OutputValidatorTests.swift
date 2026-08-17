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

    /// Review round 2: the input opening with a marker word licenses that one
    /// word — not every preamble the model might then attach behind it.
    @Test func aMarkerInputDoesNotLicenseAModelPreamble() {
        let result = OutputValidator.validate(
            output: "Sure! Here is the cleaned text: let's meet on Saturday at three.",
            input: "sure let's meet on saturday at three",
            language: .english
        )
        #expect(result == .rejected(rule: "meta-text"))
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

// MARK: - Burmese (v1.1)

/// Burmese is the language most at risk from a small local model: answering
/// in English or transliterating instead of cleaning would replace the user's
/// dictation with something they never said.
struct BurmeseOutputValidatorTests {

    private let burmeseInput = "ဒီနေ့ ရာသီဥတု ကောင်းတယ်"

    @Test func burmeseInputMustProduceBurmeseOutput() {
        let result = OutputValidator.validate(
            output: "The weather is good today.",
            input: burmeseInput,
            language: .burmese
        )
        #expect(result == .rejected(rule: "language-mismatch"))
    }

    @Test func transliteratedBurmeseIsRejected() {
        let result = OutputValidator.validate(
            output: "di ne yathi utu kaung deh",
            input: burmeseInput,
            language: .burmese
        )
        #expect(result == .rejected(rule: "language-mismatch"))
    }

    @Test func anEnglishDictationMustNotComeBackInBurmese() {
        let result = OutputValidator.validate(
            output: "ဒီနေ့ ရာသီဥတု ကောင်းတယ်",
            input: "the weather is good today",
            language: .english
        )
        #expect(result == .rejected(rule: "language-mismatch"))
    }

    @Test func cleanedBurmeseIsAccepted() {
        let cleaned = "ဒီနေ့ ရာသီဥတု ကောင်းတယ်။"
        let result = OutputValidator.validate(
            output: cleaned, input: burmeseInput, language: .burmese
        )
        #expect(result == .accepted(cleaned: cleaned))
    }

    /// Burmese sentences routinely embed English product and technical terms;
    /// a little Latin in the output is not a translation.
    @Test func codeSwitchedEnglishInsideBurmeseSurvives() {
        let cleaned = "Vocal က အရမ်းကောင်းတယ်။"
        let result = OutputValidator.validate(
            output: cleaned, input: "Vocal က အရမ်းကောင်းတယ်", language: .burmese
        )
        #expect(result == .accepted(cleaned: cleaned))
    }

    /// Unspaced scripts pack more meaning per character, so the ratio bounds
    /// start applying at a lower character count than for English.
    /// Bare consonants, deliberately: a Myanmar syllable's `String.count` is
    /// not what it looks like. U+102C and U+1038 are excluded from
    /// `SpacingMark` by UAX #29, so they break the cluster instead of joining
    /// it and "ကောင်း" is four Characters, not one. Unmarked letters make the
    /// length of this fixture self-evident.
    @Test func burmeseUsesTheUnspacedRatioThreshold() {
        let longInput = String(repeating: "ကခဂဃင", count: 8)
        // Past the 20-character unspaced threshold, so the [0.4, 2.5] bounds
        // apply — the same input under English's 60-character threshold would
        // still be in "short input, may legitimately collapse" territory.
        #expect(longInput.count == 40)
        let result = OutputValidator.validate(
            output: "က", input: longInput, language: .burmese
        )
        #expect(result == .rejected(rule: "ratio"))
    }
}

// MARK: - Self-correction collapses (found by the 2026-08-17 cleanup eval)

@Test func aLongSelfCorrectionMayCollapsePastTheNormalFloor() {
    // The eval's en-corr-007: 61 chars in, 17 out — 0.28 of the input, so the
    // flat 0.4 floor rejected every correct answer and the app silently
    // delivered the uncleaned text instead (FR-7.3).
    let input = "call her on Tuesday scratch that she's away call her Thursday"
    #expect(
        OutputValidator.validate(output: "call her Thursday", input: input, language: .english)
            == .accepted(cleaned: "call her Thursday")
    )
}

@Test func truncationIsStillRejectedWhenACueIsPresent() {
    // The floor moves to the content after the cue, it does not disappear:
    // "she's away call her Thursday" is 28 chars, so a two-character answer is
    // still well under 0.4 of it.
    let input = "call her on Tuesday scratch that she's away call her Thursday"
    #expect(
        OutputValidator.validate(output: "ok", input: input, language: .english)
            == .rejected(rule: "ratio")
    )
}

@Test func aCueDoesNotLicenseExpansion() {
    // The ceiling stays measured against the whole input.
    let input = "call her on Tuesday scratch that she's away call her Thursday"
    let padded = String(repeating: "call her on Thursday please. ", count: 8)
    #expect(
        OutputValidator.validate(output: padded, input: input, language: .english)
            == .rejected(rule: "ratio")
    )
}

@Test func inputsWithoutACueKeepTheFlatFloor() {
    let input = String(repeating: "the quarterly numbers came in higher than we planned ", count: 2)
    #expect(
        OutputValidator.validate(output: "numbers up", input: input, language: .english)
            == .rejected(rule: "ratio")
    )
}

@Test func everyValidatorCueAppearsInTheShippedPrompt() {
    // Two lists, one meaning: the prompt tells the model what a cue is, the
    // validator uses the same set to know a collapse was expected. Drift here
    // would silently re-break the case above.
    let prompt = PromptAssembler().systemPrompt(
        for: CleanupRequest(text: "x", language: .english)
    ).lowercased()
    for cue in SelfCorrectionCues.all {
        #expect(prompt.contains(cue.lowercased()), "prompt is missing cue: \(cue)")
    }
}

/// Listing "sorry" as a cue with no condition attached made both evaluated
/// models delete the apology from "sorry I'm late, the traffic was bad"
/// (eval cases `en-corr-010` and `zh-corr-005`). A cue is only a cue when
/// something before it is being replaced; the prompt has to say so, and has
/// to carry a worked counter-example — a bare rule was not enough for a 3B
/// model to resist a word sitting right there in the cue list.
@Test func theCueRuleRequiresSomethingToCorrect() {
    let prompt = PromptAssembler().systemPrompt(
        for: CleanupRequest(text: "x", language: .english)
    )
    #expect(prompt.contains("A cue only counts when"))
    // A negative example in each script, and each one uses a word from the cue
    // list as ordinary content — the discrimination is the whole point, so a
    // rule without a worked negative is not enough for a 3B model.
    #expect(prompt.contains("Not a correction:"))
    #expect(prompt.contains("sorry to bother you"))
    #expect(prompt.contains("不是改正"))
    #expect(prompt.contains("保留「不对」"))
}

/// The style slot reached the model but carried no authority: the core prompt
/// said "Do not rephrase" and the English rules said to keep the speaker's
/// spelling "unless the task instructions say otherwise" — and a style prompt
/// is not the task instructions. A literal-minded model was therefore correct
/// to ignore "Use British spelling", which is what the whole style category
/// did in the first live runs. AC-11 needs the override stated, not implied.
@Test func theStyleSectionCanOverrideTheKeepWordingRules() {
    let prompt = PromptAssembler().systemPrompt(
        for: CleanupRequest(text: "x", language: .english, stylePrompt: "Use British spelling.")
    )
    let lowered = prompt.lowercased()
    #expect(lowered.contains("use british spelling."))
    #expect(lowered.contains("that is the only thing it may override"))
    #expect(lowered.contains("unless an instruction below says otherwise"))
    // A banned word that carries meaning must be substituted, not deleted —
    // otherwise "the amazing thing is it just works" loses its subject.
    #expect(lowered.contains("substitute a word that keeps the meaning"))
    // The escape hatch stays shut: style is not a licence to translate or answer.
    #expect(lowered.contains("never licenses translating"))
    #expect(lowered.contains("hard rules still win"))
}

/// The regression that made shipping the licence unconditionally a mistake.
///
/// With no style prompt the section used to render its override paragraph
/// above a literal "(none)". qwen2.5:3b-instruct took the standing permission
/// and, with nothing concrete to bind it to, generalised into translation:
/// `mix-002` and `mix-007` came back with the embedded English rendered as
/// Chinese, and `en-corr-010` — a plain English sentence — came back in
/// Chinese outright, which the validator caught as `language-mismatch`. The
/// section must not exist at all when there is nothing for it to license.
@Test func noStylePromptMeansNoStyleSectionAtAll() {
    let prompt = PromptAssembler().systemPrompt(
        for: CleanupRequest(text: "x", language: .english)
    )
    let lowered = prompt.lowercased()
    #expect(!lowered.contains("style"))
    #expect(!lowered.contains("may override"))
    #expect(!lowered.contains("substitute a word"))
    // The blanket prohibition stands unqualified when nothing qualifies it.
    #expect(lowered.contains("do not rephrase."))
    // TASK still renders its placeholder — only STYLE disappears.
    #expect(prompt.contains("(none)"))
}
