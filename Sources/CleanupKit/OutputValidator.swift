import CoreModels
import Foundation

/// Verdict of the stage-3 output validator (docs/05 §3.3).
public enum ValidationResult: Sendable, Hashable {
    case accepted(cleaned: String)
    case rejected(rule: String)
}

/// Length-aware validation of LLM cleanup output before delivery (docs/05 §3.3).
/// Any rejection makes the pipeline fall back to the stage-2 text; the validator
/// never edits beyond stripping reasoning blocks and surrounding whitespace.
public enum OutputValidator {
    /// Rules, in order: strip reasoning blocks; reject empty output; reject
    /// meta-text prefixes; length-aware ratio bounds ([0.4, 2.5] only for long
    /// inputs — short inputs may legitimately collapse, e.g.
    /// 「周五，啊不对，周六」→「周六」, and are rejected only past 4× expansion);
    /// Han input must yield Han output.
    public static func validate(
        output: String, input: String, language: Language
    ) -> ValidationResult {
        let cleaned = strippingThinkBlocks(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return .rejected(rule: "empty")
        }

        // An unterminated reasoning block (max_tokens/timeout truncation)
        // survives the paired-block strip; never deliver chain-of-thought.
        let loweredForTags = cleaned.lowercased()
        if loweredForTags.contains("<think") || loweredForTags.contains("<reasoning") {
            return .rejected(rule: "meta-text")
        }

        // A marker is only evidence of a preamble when the model *introduced*
        // it. "Sure, sounds good." and 「好的，我明天过去。」 are ordinary things
        // to dictate, and rejecting them made cleanup permanently useless for
        // anyone who opens a sentence that way — so a marker the input already
        // starts with is the speaker's own word, not the model talking.
        let lowered = cleaned.lowercased()
        let loweredInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let marker = metaMarkers.first(where: { lowered.hasPrefix($0) }),
            !loweredInput.hasPrefix(marker) {
            return .rejected(rule: "meta-text")
        }

        let inputCount = input.count
        let ratio =
            inputCount > 0 ? Double(cleaned.count) / Double(inputCount) : Double.infinity
        // Unspaced scripts pack far more meaning per character, so the
        // "long enough for ratio bounds to be meaningful" line sits lower.
        let longInputThreshold = language.isUnspacedScript ? 20 : 60
        if inputCount > longInputThreshold {
            if ratio < 0.4 || ratio > 2.5 {
                return .rejected(rule: "ratio")
            }
        } else if ratio > 4.0 {
            return .rejected(rule: "ratio")
        }

        if input.containsHanCharacters, !cleaned.containsHanCharacters {
            return .rejected(rule: "language-mismatch")
        }
        // Burmese is the language most at risk here: small local models are
        // prone to answering it in English or transliterating it rather than
        // cleaning it (docs/04 Appendix A), and either would replace the
        // user's dictation with something they never said.
        if input.containsMyanmarCharacters, !cleaned.containsMyanmarCharacters {
            return .rejected(rule: "language-mismatch")
        }
        // Mirror direction: an English dictation must not come back translated
        // into Chinese (answer/translation failure class). Code-switched Han in
        // a mostly-Latin output is tolerated up to a third of its length.
        if !input.containsHanCharacters, cleaned.containsHanCharacters {
            let hanCount = cleaned.unicodeScalars.filter(Unicode.isHanScalar).count
            if hanCount * 3 > cleaned.count {
                return .rejected(rule: "language-mismatch")
            }
        }
        if !input.containsMyanmarCharacters, cleaned.containsMyanmarCharacters {
            let myanmarCount = cleaned.unicodeScalars.filter(Unicode.isMyanmarScalar).count
            if myanmarCount * 3 > cleaned.count {
                return .rejected(rule: "language-mismatch")
            }
        }

        return .accepted(cleaned: cleaned)
    }

    /// Removes `<think>`, `<thinking>`, and `<reasoning>` blocks emitted by
    /// reasoning-tuned local models. Safe to apply repeatedly.
    public static func strippingThinkBlocks(_ text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: "<(think|thinking|reasoning)>.*?</\\1>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
    }

    /// Compared case-insensitively against the start of the (stripped) output.
    private static let metaMarkers: [String] = [
        "here is", "here's", "here’s", "以下是", "好的", "sure", "```",
    ]
}
