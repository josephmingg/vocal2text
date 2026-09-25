import Foundation

/// Deterministic English cleanup that runs inside stage 1 whenever the profile
/// allows formatting (docs/05 §1). It gives every dictation the "auto clean"
/// basics — filler removal and stutter repair — without needing the optional
/// stage-3 LLM, and hands the LLM (and the skip heuristic) a cleaner
/// transcript when it does run.
///
/// Every rule is deliberately conservative: it only fires on patterns that
/// are almost never intended content (a bare "um", "the the"). Ambiguous
/// cases — "like", "you know", self-corrections, spoken commands — stay with
/// the LLM and `SpokenLayoutCommands`.
public enum EnglishCleanup: Sendable {

    /// Fillers first, so "the, um, the table" still collapses to one "the".
    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = removeFillers(result)
        result = collapseStutters(result)
        return result
    }

    // MARK: - Fillers

    /// Hesitation sounds only — never words that can carry meaning ("like",
    /// "so", "well", "you know" are left to the LLM). "uh-huh" and "mhm" are
    /// answers, not fillers, and the hyphen/letter guards keep them intact.
    private static let filler = "(?:u+m+|u+h+m*|erm|er|h+m+|a+h+)"
    private static let before = "(?<![\\p{L}\\p{N}'’\\-])"
    private static let after = "(?![\\p{L}\\p{N}'’\\-])"
    /// Optional punctuation Whisper hangs off a filler: "Um," "Uh..." "Um."
    private static let fillerTail = "(?:,|…|\\.{1,3})?"

    static func removeFillers(_ text: String) -> String {
        var result = text
        let word = before + filler + after

        // "I, uh, think" → "I think"
        result = replace("\\s*,\\s*" + word + "\\s*,(?=\\s)", in: result, with: "")

        // Sentence-initial: "Um, I think" → "I think"; "Done. Uh so we" →
        // "Done. So we". The first letter of the next word is re-capitalized
        // because the filler was carrying the sentence start.
        result = replace(
            "(^|[.!?\\n][\"”’)]?\\s+|\\n)" + word + fillerTail
                + "(?:\\s+" + word + fillerTail + ")*\\s+(\\p{L})",
            in: result
        ) { groups in
            groups[1] + groups[2].uppercased()
        }

        // Sentence-final: "I think, um." → "I think."; "yes uh" → "yes"
        result = replace(
            "\\s*,?\\s*" + word + fillerTail + "(?=\\s*[.!?]|\\s*$)", in: result, with: ""
        )

        // Mid-sentence: "so uh we" / "so uh, we" → "so we"
        result = replace("\\s+" + word + "(?:,|…|\\.{3})?(?=\\s)", in: result, with: "")

        // A transcript that was nothing but a filler ("Um.") leaves only
        // punctuation behind.
        let stripped = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.allSatisfy({ $0.isPunctuation }) { return "" }
        return result
    }

    // MARK: - Stutters

    /// Function words people stutter on. Words where a doubled form is
    /// grammatical ("that that", "had had", "is is", "do do") or expressive
    /// ("very very", "no no", "bye bye") are deliberately absent.
    private static let stutterWords = [
        "i", "i'm", "i’m", "i'll", "i’ll", "i've", "i’ve", "i'd", "i’d",
        "a", "an", "the", "to", "and", "but", "or", "so", "we", "you", "he", "she",
        "it", "it's", "it’s", "they", "my", "our", "your", "their", "in", "on", "at",
        "of", "for", "with", "this", "what", "if", "can", "just", "are", "was",
    ]

    /// "I I think" / "I, I think" / "the the the" → one occurrence. Runs of
    /// four or more are already collapsed by the loop guard in stage 1.
    static func collapseStutters(_ text: String) -> String {
        let alternatives = stutterWords
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = before + "(" + alternatives + ")(?:,?\\s+\\1)+" + after
        return replace(pattern, in: text) { groups in groups[1] }
    }

    // MARK: - Regex helpers

    private static func replace(_ pattern: String, in text: String, with template: String)
        -> String
    {
        PipelineRegex.replacing(pattern: pattern, in: text, with: template)
    }

    /// Replaces every match of `pattern` (case-insensitive) using `transform`,
    /// which receives the full match at index 0 followed by each capture
    /// group (empty string for a group that did not participate).
    private static func replace(
        _ pattern: String, in text: String, transform: ([String]) -> String
    ) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]
            )
        else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }
}
