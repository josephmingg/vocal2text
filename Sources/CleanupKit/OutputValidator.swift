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
        // anyone who opens a sentence that way. But the license is one word,
        // not the whole output: skip the marker the input itself opens with on
        // BOTH sides and re-apply the rule to what follows, so
        // "Sure! Here is the cleaned text: …" is still caught when the
        // dictation merely began with "sure".
        let lowered = cleaned.lowercased()
        let loweredInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var candidate = Substring(lowered)
        if let shared = metaMarkers.first(where: {
            loweredInput.hasPrefix($0) && lowered.hasPrefix($0)
        }) {
            candidate = lowered.dropFirst(shared.count)
            while let first = candidate.first, first.isWhitespace || first.isPunctuation {
                candidate = candidate.dropFirst()
            }
        }
        if metaMarkers.contains(where: { candidate.hasPrefix($0) }) {
            return .rejected(rule: "meta-text")
        }

        let inputCount = input.count
        let ratio =
            inputCount > 0 ? Double(cleaned.count) / Double(inputCount) : Double.infinity
        // Unspaced scripts pack far more meaning per character, so the
        // "long enough for ratio bounds to be meaningful" line sits lower.
        // Burmese reaches it sooner still, since a Myanmar syllable spans two
        // to four Swift Characters — which errs toward applying the tighter
        // [0.4, 2.5] bounds, and that is the safe direction for the language
        // most at risk of a model mangling it.
        let longInputThreshold = language.isUnspacedScript ? 20 : 60
        if inputCount > longInputThreshold {
            // The lower bound catches truncation, but a self-correction
            // legitimately discards everything before the cue — "call her on
            // Tuesday scratch that she's away call her Thursday" → "call her
            // Thursday" is 0.30 of the input, and no correct answer to that
            // dictation could clear 0.4. Measure the floor against the content
            // *after* the last cue instead, which keeps the truncation guard
            // (a two-word answer still fails) while letting the abandoned half
            // go. The ceiling stays against the whole input: nothing about a
            // correction licenses expansion.
            let floorBasis = SelfCorrectionCues.contentAfterLastCue(in: input).map(\.count)
                ?? inputCount
            let floorRatio =
                floorBasis > 0 ? Double(cleaned.count) / Double(floorBasis) : Double.infinity
            if floorRatio < 0.4 || ratio > 2.5 {
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
            // Scalars on BOTH sides of the ratio. Myanmar syllables span 2–4
            // scalars per Character, so a scalar count over a grapheme count
            // silently tightened "a third of its length" to roughly a ninth.
            // (The Han rule above is safe with graphemes — Han is 1:1.)
            let scalars = cleaned.unicodeScalars
            let myanmarCount = scalars.filter(Unicode.isMyanmarScalar).count
            if myanmarCount * 3 > scalars.count {
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
