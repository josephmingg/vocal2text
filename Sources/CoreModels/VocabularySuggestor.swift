import Foundation

/// Detects the "dictate → immediately re-dictate a fix" pattern (docs/15
/// step 27, Part 2b mechanism) and proposes a dictionary entry from the
/// diff. Always propose, never auto-apply — the UI offers the entry, the
/// user decides. Wispr Flow learns invisibly; doing it visibly and locally
/// is the on-brand version.
public enum VocabularySuggestor {

    public struct Suggestion: Sendable, Equatable {
        /// What ASR produced the first time (the mis-hearing).
        public var spoken: String
        /// What the user re-dictated it into (casing authoritative).
        public var written: String

        public init(spoken: String, written: String) {
            self.spoken = spoken
            self.written = written
        }
    }

    /// A re-dictation this long after delivery is a new thought, not a fix.
    public static let maximumGapSeconds: TimeInterval = 30

    /// Words whose replacement is content editing, never vocabulary.
    static let stopWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "in", "on", "at", "is",
        "it", "for", "with", "that", "this", "not", "no", "yes",
    ]

    /// Compares two consecutive takes and proposes an entry when the second
    /// reads as a correction of the first: same shape, one contiguous span of
    /// at most two words changed, and the change looks like a respelling
    /// (small edit distance) or a proper-noun casing rather than new content.
    public static func suggestion(
        previousText: String,
        currentText: String,
        gapSeconds: TimeInterval
    ) -> Suggestion? {
        guard gapSeconds >= 0, gapSeconds <= maximumGapSeconds else { return nil }
        let previous = words(of: previousText)
        let current = words(of: currentText)
        guard previous.count == current.count, previous.count >= 2 else { return nil }

        // Case-sensitive diff: a case-only re-dictation ("anthropic" →
        // "Anthropic") is a legitimate correction, since dictionary casing is
        // authoritative.
        var differing: [Int] = []
        for index in previous.indices where previous[index] != current[index] {
            differing.append(index)
        }
        // Exactly one contiguous span of 1–2 words; everything else identical.
        guard !differing.isEmpty, differing.count <= 2 else { return nil }
        // A first-word case flip is stage-1 sentence capitalization at work,
        // not vocabulary.
        if differing == [0], previous[0].lowercased() == current[0].lowercased() {
            return nil
        }
        if differing.count == 2, differing[1] != differing[0] + 1 { return nil }
        // A take that is *only* the changed words has no agreeing context —
        // nothing marks it as a correction rather than a new utterance.
        guard differing.count < previous.count else { return nil }

        let spoken = differing.map { previous[$0] }.joined(separator: " ")
        let written = differing.map { current[$0] }.joined(separator: " ")
        guard spoken.count >= 3, !spoken.isEmpty, !written.isEmpty else { return nil }
        guard !differing.allSatisfy({ stopWords.contains(current[$0].lowercased()) }) else {
            return nil
        }

        // Case-only differences are valid entries (casing is authoritative in
        // the dictionary). Otherwise the spans must sound alike: a large edit
        // distance on an all-lowercase replacement is a content change
        // ("tuesday" → "wednesday"), not a respelling.
        let looksLikeRespelling =
            editDistance(spoken.lowercased(), written.lowercased())
            <= max(2, spoken.count / 2)
        let introducesProperNoun = written.contains(where: \.isUppercase)
        guard looksLikeRespelling || introducesProperNoun else { return nil }

        return Suggestion(spoken: spoken, written: written)
    }

    /// Words with surrounding punctuation stripped, so "Claude." and "Claude"
    /// compare equal and the proposed entry carries no trailing period.
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Plain Levenshtein — spans here are a few words at most.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let substitution = previous[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
