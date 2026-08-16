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

        let lowered = cleaned.lowercased()
        if metaMarkers.contains(where: { lowered.hasPrefix($0) }) {
            return .rejected(rule: "meta-text")
        }

        let inputCount = input.count
        let ratio =
            inputCount > 0 ? Double(cleaned.count) / Double(inputCount) : Double.infinity
        let longInputThreshold = language == .chinese ? 20 : 60
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
        // Mirror direction: an English dictation must not come back translated
        // into Chinese (answer/translation failure class). Code-switched Han in
        // a mostly-Latin output is tolerated up to a third of its length.
        if !input.containsHanCharacters, cleaned.containsHanCharacters {
            let hanCount = cleaned.unicodeScalars.filter {
                (0x4E00...0x9FFF).contains($0.value)
            }.count
            if hanCount * 3 > cleaned.count {
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
