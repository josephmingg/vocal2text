import Foundation

/// Which dictionary terms Parakeet's vocabulary boost listens for (docs/17
/// F9, G2.2).
///
/// The boost runs a small CTC keyword spotter over the take and replaces a
/// misheard word only when the audio supports one of these terms. The input
/// is already ranked most-used first (`vocabularyTerms`), so the cap keeps
/// the words you say most.
public enum VocabularyBoost {
    /// Upper bound on boosted terms. The spotter's cost grows with the list.
    public static let maxTerms = 256
    /// FluidAudio's spotter ignores shorter terms ("or" → "VR" false hits).
    public static let minLength = 3
    /// Longer entries are phrases or templates, not words to listen for.
    public static let maxLength = 40

    private static let allowed: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -'.&+"
    )

    /// The terms worth boosting, in input order: single-line, 3–40
    /// characters, written in English letters (the model is English-only),
    /// with at least one letter, each once regardless of case.
    public static func eligibleTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespaces)
            guard (minLength...maxLength).contains(term.count),
                term.allSatisfy(allowed.contains),
                term.contains(where: \.isLetter),
                seen.insert(term.lowercased()).inserted
            else { continue }
            result.append(term)
            if result.count == maxTerms { break }
        }
        return result
    }
}
