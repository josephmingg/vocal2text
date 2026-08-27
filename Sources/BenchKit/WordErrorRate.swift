import CoreModels
import Foundation

/// WER for space-delimited scripts, CER for Han text (the standard metric per
/// script family — docs/04 evaluates ZH by character). Tokenization lowercases
/// and strips punctuation so the metric scores recognition, not formatting.
public enum WordErrorRate {

    public struct Score: Equatable {
        /// Substitutions + insertions + deletions.
        public var editDistance: Int
        public var referenceCount: Int
        /// Character-based (Han reference) or word-based.
        public var isCharacterBased: Bool

        public var rate: Double {
            referenceCount > 0 ? Double(editDistance) / Double(referenceCount) : 0
        }

        public init(editDistance: Int, referenceCount: Int, isCharacterBased: Bool) {
            self.editDistance = editDistance
            self.referenceCount = referenceCount
            self.isCharacterBased = isCharacterBased
        }
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let characterBased = reference.containsHanCharacters
        let ref = tokens(reference, characterBased: characterBased)
        let hyp = tokens(hypothesis, characterBased: characterBased)
        return Score(
            editDistance: editDistance(ref, hyp),
            referenceCount: ref.count,
            isCharacterBased: characterBased
        )
    }

    /// Lowercased, punctuation-free tokens: words for alphabetic scripts, one
    /// token per non-space character for Han references (mixed EN inside a ZH
    /// reference also scores per character — consistent, if strict).
    static func tokens(_ text: String, characterBased: Bool) -> [String] {
        let lowered = text.lowercased()
        let stripped = String(
            lowered.map { scalarIsKept($0) ? $0 : " " }
        )
        if characterBased {
            return stripped.filter { !$0.isWhitespace }.map(String.init)
        }
        return stripped.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func scalarIsKept(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.isWhitespace
            || character == "'"
    }

    /// Classic Levenshtein with two rolling rows — fixture transcripts are a
    /// few hundred tokens, so O(n·m) is plenty.
    static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

/// Percentiles over small benchmark sample sets (nearest-rank).
public enum Percentile {
    public static func value(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((percentile / 100.0 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
