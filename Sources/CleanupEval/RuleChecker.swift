import CleanupKit
import CoreModels
import Foundation

/// Verdict for one hard rule.
public struct RuleOutcome: Sendable, Hashable {
    public var label: String
    public var passed: Bool
    /// What went wrong, for the report. Empty when passed.
    public var detail: String

    public init(label: String, passed: Bool, detail: String = "") {
        self.label = label
        self.passed = passed
        self.detail = detail
    }
}

/// Scores one cleaned output against a case's rules.
///
/// Pure and unit-tested on Linux, which matters more than it looks: the harness
/// is a measuring instrument, and an unverified instrument produces numbers that
/// get believed. The provider call cannot be tested without a live model; the
/// scoring can, and is.
public enum RuleChecker {

    /// The `preservesTerms` rule delegates here rather than re-implementing
    /// term matching, so the eval and the shipping pipeline agree on what
    /// "mangled a protected term" means.
    public static func check(
        _ rule: EvalRule, output: String, input: String, protectedTerms: [String]
    ) -> RuleOutcome {
        let cased = rule.caseSensitive ?? false
        switch rule.kind {
        case .mustContain:
            let missing = (rule.values ?? []).filter { !contains(output, $0, caseSensitive: cased) }
            return RuleOutcome(
                label: rule.label,
                passed: missing.isEmpty,
                detail: missing.isEmpty ? "" : "missing: \(missing.joined(separator: ", "))"
            )

        case .mustNotContain:
            let present = (rule.values ?? []).filter { contains(output, $0, caseSensitive: cased) }
            return RuleOutcome(
                label: rule.label,
                passed: present.isEmpty,
                detail: present.isEmpty ? "" : "present: \(present.joined(separator: ", "))"
            )

        case .preservesTerms:
            // Rule-supplied terms win, so a case can assert a term the request
            // did not mark protected; otherwise fall back to the case's own.
            let terms = rule.values ?? protectedTerms
            let ok = ProtectedTermsVerifier.verify(
                output: output, input: input, protectedTerms: terms
            )
            return RuleOutcome(
                label: rule.label,
                passed: ok,
                detail: ok ? "" : "mangled one of: \(terms.joined(separator: ", "))"
            )

        case .maxWords:
            let limit = rule.limit ?? Int.max
            let count = wordCount(output)
            return RuleOutcome(
                label: rule.label,
                passed: count <= limit,
                detail: count <= limit ? "" : "\(count) words"
            )
        }
    }

    /// Containment, with word boundaries where the script has them.
    ///
    /// A plain substring test would make `mustNotContain: ["um"]` fire on
    /// "album" and "number", quietly failing cases the model got right. Han and
    /// Myanmar have no word boundaries, so those needles fall back to substring
    /// — which is what 「不对」 needs anyway.
    ///
    /// Width-insensitive matching is deliberately *not* used: it makes ASCII
    /// "," match full-width "，", which is precisely the distinction the
    /// ZH punctuation cases exist to measure.
    static func contains(_ haystack: String, _ needle: String, caseSensitive: Bool = false) -> Bool
    {
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        let isWordLike = needle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard isWordLike else {
            return haystack.range(of: needle, options: options) != nil
        }

        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: options, range: searchRange) {
            let leadingOK = found.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
            let trailingOK = found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound])
            if leadingOK && trailingOK {
                return true
            }
            guard found.lowerBound < haystack.endIndex else { break }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    /// Whether this character continues a *Latin* word.
    ///
    /// Han and Myanmar characters are letters as far as Swift is concerned, but
    /// they do not extend a Latin token: in 「我们先review一下」 the word `review`
    /// is bounded by 先 and 一. Counting those as word characters made every
    /// code-switching case unmatchable — the terms were right there in the
    /// output and the eval reported them missing.
    static func isWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber || character == "'" || character == "’"
        else {
            return false
        }
        return !character.unicodeScalars.contains {
            Unicode.isHanScalar($0) || Unicode.isMyanmarScalar($0)
        }
    }

    /// Han text has no spaces, so counting space-separated tokens would score
    /// every Chinese output as one word. Count Han characters individually and
    /// whitespace-delimited runs elsewhere.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inRun = false
        for character in text {
            if character.unicodeScalars.contains(where: { Unicode.isHanScalar($0) }) {
                count += 1
                inRun = false
            } else if character.isWhitespace {
                inRun = false
            } else if character.isLetter || character.isNumber {
                if !inRun {
                    count += 1
                    inRun = true
                }
            } else {
                inRun = false
            }
        }
        return count
    }

    /// Levenshtein distance, normalized to [0, 1] against the longer string.
    /// Reported, never scored — several wordings can be equally right, and a
    /// threshold here would make the harness argue with itself.
    public static func normalizedEditDistance(_ a: String, _ b: String) -> Double {
        let left = Array(a), right = Array(b)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 0 }
        guard !left.isEmpty, !right.isEmpty else { return 1 }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[right.count]) / Double(longest)
    }
}
