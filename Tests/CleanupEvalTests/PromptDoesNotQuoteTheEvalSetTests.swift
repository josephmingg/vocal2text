import CleanupEval
import CleanupKit
import CoreModels
import Foundation
import Testing

/// The eval only measures something if the answers are not in the prompt.
///
/// This started as a real contamination: a self-correction counter-example was
/// written using `en-corr-010` and `zh-corr-005` verbatim, and the pre-existing
/// worked example quoted `zh-corr-001`. Three of sixty-two cases were being
/// scored against a model that could read them in its own instructions —
/// `zh-corr-005` "passing" said nothing about whether the rule had been learnt.
///
/// It was not only a scoring problem. The counter-example placed an English
/// sentence beside its exact Chinese translation, and qwen2.5:3b-instruct
/// copied the Chinese when it saw the English input: `en-corr-010` came back
/// in the wrong language and the shipping validator rejected it as
/// `language-mismatch`, deterministically at temperature 0.
///
/// Prompt examples must therefore be *about* the same rules while sharing no
/// text with the case set, so this walks the real files rather than a fixture.
struct PromptDoesNotQuoteTheEvalSetTests {

    /// The repository's own `evals/cleanup`, located from this file so the test
    /// does not depend on the working directory a runner happens to use.
    private static var caseDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CleanupEvalTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("evals")
            .appendingPathComponent("cleanup")
            .path
    }

    /// Case-folded, punctuation- and space-stripped, so a match is not dodged
    /// by re-typing 「，」 as "," or dropping an apostrophe. Han and Myanmar
    /// scalars are letters, so `alphanumerics` keeps them.
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(
            folded.unicodeScalars
                .filter(CharacterSet.alphanumerics.contains)
                .map(Character.init)
        )
    }

    @Test func noEvalCaseTextAppearsInTheShippedPrompt() throws {
        let cases = try EvalCaseLoader.load(directory: Self.caseDirectory)
        #expect(!cases.isEmpty)

        // Every language's rule block, since a case is scored against whichever
        // one its language selects — and both style states, because the STYLE
        // section is rendered only when the user set a style prompt. A prompt
        // built without one never contains `style_section.txt` at all, so an
        // example added there would have been invisible to this guard. The
        // sentinel is deliberately not English prose: its own text must not be
        // what a needle collides with.
        let prompts = [Language.english, .chinese, .burmese].flatMap { language in
            ["", "STYLEPROBE"].map { style in
                Self.normalized(
                    PromptAssembler().systemPrompt(
                        for: CleanupRequest(text: "x", language: language, stylePrompt: style)
                    )
                )
            }
        }

        for evalCase in cases {
            for (field, text) in [("input", evalCase.input), ("reference", evalCase.reference)] {
                let needle = Self.normalized(text)
                // Very short strings collide by accident and prove nothing.
                guard needle.count >= 8 else { continue }
                for prompt in prompts {
                    #expect(
                        !prompt.contains(needle),
                        "\(evalCase.id) \(field) is quoted in the prompt: \(text)"
                    )
                }
            }
        }
    }

    /// The mechanism behind the `language-mismatch` failure: an English example
    /// and its Chinese translation side by side read as a translation demo, and
    /// a small model obliges. Examples in the two scripts must describe
    /// unrelated situations.
    @Test func noPromptExampleIsATranslationOfAnother() {
        let prompt = PromptAssembler().systemPrompt(
            for: CleanupRequest(text: "x", language: .english)
        )
        // The self-correction examples are the ones that sit adjacent.
        #expect(prompt.contains("ship it on the tenth"))
        #expect(prompt.contains("会议室"))
        // Nothing about meeting rooms in the English pair, nothing about
        // shipping dates in the Chinese pair.
        #expect(!prompt.contains("meeting room"))
        #expect(!prompt.contains("十二号"))
    }
}
