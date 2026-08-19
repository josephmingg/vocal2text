import CleanupKit
import CoreModels
import Foundation
import Testing

/// `contentAfterLastCue` is the basis the validator's ratio floor is measured
/// against, so every wrong answer here loosens or tightens the guard that
/// stands between a model's answer and the user's document.
struct SelfCorrectionCuesTests {

    // MARK: - Index safety

    /// The cue used to be located in `input.lowercased()` and the resulting
    /// index applied to `input`. That is only safe while lowercasing preserves
    /// length, and it does not: `İ` (U+0130) lowercases to two scalars, so the
    /// index ran past the end of the original and subscripting it trapped.
    @Test func aLengthChangingLowercaseDoesNotDisturbTheTail() {
        #expect(
            SelfCorrectionCues.contentAfterLastCue(in: "meet in İstanbul, sorry, Ankara")
                == ", Ankara"
        )
    }

    /// The shape that trapped outright: the growth happens before a cue that
    /// ends the string, so the computed index exceeded `input.endIndex`.
    @Test func aCueEndingTheInputIsNotACorrection() {
        #expect(SelfCorrectionCues.contentAfterLastCue(in: "meet in İstanbul, sorry") == nil)
    }

    @Test func cuesMatchRegardlessOfCase() {
        #expect(
            SelfCorrectionCues.contentAfterLastCue(in: "call Friday, SORRY, Saturday")
                == ", Saturday"
        )
    }

    // MARK: - Latin word boundaries

    /// Without boundaries "correction" matches inside "corrections" and leaves
    /// a one-character tail, which makes the floor ratio enormous and disables
    /// the guard entirely for that dictation.
    @Test(arguments: [
        "let's review the corrections before we ship",
        "unfortunately that is factually correct",
        "the AI meant well",
    ])
    func aCueEmbeddedInALongerWordIsNotACue(input: String) {
        #expect(SelfCorrectionCues.contentAfterLastCue(in: input) == nil)
    }

    @Test func aStandaloneEnglishCueIsFound() {
        #expect(
            SelfCorrectionCues.contentAfterLastCue(in: "ship it on the tenth, I mean the twelfth")
                == "the twelfth"
        )
    }

    /// docs/05: a cue with nothing before it to replace is ordinary content.
    /// The tail is still measured — the point is only that it is not treated as
    /// a licence to collapse the whole dictation.
    @Test func theLastCueWinsWhenSeveralAppear() {
        #expect(
            SelfCorrectionCues.contentAfterLastCue(
                in: "actually let's meet Friday, sorry, Saturday"
            ) == ", Saturday"
        )
    }

    // MARK: - Han cues

    /// 「不对」 is an ordinary thing to say. Han has no word edges, so the test
    /// is whether the cue begins a new breath group — which a transcript marks
    /// with punctuation.
    @Test func aHanCueContinuingAPhraseIsContent() {
        #expect(SelfCorrectionCues.contentAfterLastCue(in: "这个数字不对，改一下") == nil)
    }

    @Test(arguments: [
        ("发给张伟，不对，发给李明", "，发给李明"),
        ("周五，啊不对，周六", "，周六"),
        ("先部署到测试环境，我是说生产环境", "生产环境"),
    ])
    func aHanCueAfterAPauseIsACorrection(input: String, tail: String) {
        #expect(SelfCorrectionCues.contentAfterLastCue(in: input) == tail)
    }

    @Test func noCueMeansNoTail() {
        #expect(SelfCorrectionCues.contentAfterLastCue(in: "just a plain sentence") == nil)
        #expect(SelfCorrectionCues.contentAfterLastCue(in: "") == nil)
    }
}
