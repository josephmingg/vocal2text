import CoreModels
import Foundation

/// Stage 2 of the text pipeline: applies the user dictionary to a transcript
/// (docs/05 §2). Pure and deterministic — all matches are computed against the
/// original string and applied together, so no entry ever sees another entry's
/// output (no cascading), and written forms are terminal, which makes applying
/// the engine to its own output a no-op.
public enum DictionaryEngine {

    /// Applies `entries` to `text` for the given detected `language`.
    ///
    /// Semantics (docs/05 §2):
    /// - Only enabled entries whose `languages` set is nil or contains
    ///   `language` participate.
    /// - The spoken form matches case-insensitively; the written form is
    ///   inserted verbatim (its casing is authoritative, even at sentence
    ///   start).
    /// - `.word` entries match on Unicode-aware word boundaries; internal
    ///   whitespace in a multi-word spoken form matches any single whitespace
    ///   run. `.phrase` entries match as literal substrings (CJK).
    /// - Longest spoken form first; each character span is consumed by at most
    ///   one entry.
    /// - Written forms are terminal: a candidate lying entirely inside an
    ///   occurrence of any participating entry's written form is skipped, so
    ///   re-application changes nothing.
    ///
    /// - Returns: the rewritten text, plus one entry ID per replacement
    ///   performed, ordered by match position in the original text (an entry
    ///   that applied more than once appears more than once — callers use this
    ///   for `applyCount` stats).
    public static func apply(
        _ text: String,
        entries: [DictionaryEntry],
        language: Language
    ) -> (text: String, appliedEntryIDs: [UUID]) {
        guard !text.isEmpty else { return (text, []) }

        let eligible = entries.filter { entry in
            entry.isEnabled
                && !entry.spoken.isEmpty
                && (entry.languages?.contains(language) ?? true)
        }
        guard !eligible.isEmpty else { return (text, []) }

        let terminalSpans = writtenFormSpans(of: eligible, in: text)

        // Longest spoken form first; ties keep the caller's order.
        let ordered = eligible.enumerated()
            .sorted { a, b in
                if a.element.spoken.count != b.element.spoken.count {
                    return a.element.spoken.count > b.element.spoken.count
                }
                return a.offset < b.offset
            }
            .map { $0.element }

        var accepted: [Replacement] = []
        for entry in ordered {
            for candidate in candidateRanges(of: entry, in: text) {
                let isTerminal = terminalSpans.contains { span in
                    span.lowerBound <= candidate.lowerBound
                        && candidate.upperBound <= span.upperBound
                }
                if isTerminal { continue }
                if accepted.contains(where: { $0.range.overlaps(candidate) }) { continue }
                accepted.append(
                    Replacement(entryID: entry.id, range: candidate, written: entry.written)
                )
            }
        }
        guard !accepted.isEmpty else { return (text, []) }

        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Assemble from slices of the untouched original so String.Index
        // validity is never in question.
        var result = ""
        var cursor = text.startIndex
        for replacement in accepted {
            result += text[cursor..<replacement.range.lowerBound]
            result += replacement.written
            cursor = replacement.range.upperBound
        }
        result += text[cursor...]

        return (result, accepted.map { $0.entryID })
    }

    // MARK: - Internals

    private struct Replacement {
        let entryID: UUID
        let range: Range<String.Index>
        let written: String
    }

    /// All occurrences — overlapping included — of every participating entry's
    /// written form, matched case-sensitively. Candidates inside these spans
    /// are skipped: written forms are terminal.
    private static func writtenFormSpans(
        of entries: [DictionaryEntry],
        in text: String
    ) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        for entry in entries where !entry.written.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                let found = text.range(of: entry.written, range: searchStart..<text.endIndex),
                !found.isEmpty
            {
                spans.append(found)
                // Step one character past the match start, not to its end, so
                // overlapping occurrences also block candidates.
                searchStart = text.index(after: found.lowerBound)
            }
        }
        return spans
    }

    private static func candidateRanges(
        of entry: DictionaryEntry,
        in text: String
    ) -> [Range<String.Index>] {
        switch entry.matchMode {
        case .word:
            return wordModeRanges(spoken: entry.spoken, in: text)
        case .phrase:
            return phraseModeRanges(spoken: entry.spoken, in: text)
        }
    }

    // `\b` is unreliable around CJK (documented SpeakType bug), so boundaries
    // are expressed as "no letter or number on either side".
    private static let boundaryBefore = "(?<![\\p{L}\\p{N}])"
    private static let boundaryAfter = "(?![\\p{L}\\p{N}])"

    private static func wordModeRanges(spoken: String, in text: String) -> [Range<String.Index>] {
        // Each whitespace-free token is escaped before joining, so only the
        // whitespace between tokens becomes a pattern: any single run of
        // whitespace matches a multi-word spoken form's internal gap.
        let tokens = spoken
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return [] }

        let pattern = boundaryBefore + tokens.joined(separator: "\\s+") + boundaryAfter
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: fullRange)
            .compactMap { Range($0.range, in: text) }
    }

    private static func phraseModeRanges(spoken: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
            let found = text.range(
                of: spoken,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
            ),
            !found.isEmpty
        {
            ranges.append(found)
            // Step one character so a candidate overlapping a skipped earlier
            // match is still considered during selection.
            searchStart = text.index(after: found.lowerBound)
        }
        return ranges
    }
}
