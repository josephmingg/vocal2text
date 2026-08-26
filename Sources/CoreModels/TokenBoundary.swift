import Foundation

/// How much of an edge a match needs before it counts as its own token.
///
/// Plain substring matching is wrong in both directions, and the right answer
/// depends on the script. `mustNotContain: ["um"]` fires on "album"; the
/// correction cue "correction" hides inside "corrections"; and 「不对」 sits
/// inside 「这个数字不对，改一下」 where it is ordinary content rather than a
/// correction. Latin has two edges to test. Han and Myanmar have none, so the
/// closest available signal is whether the match starts a new breath group —
/// a spoken correction is set off by a pause, which a transcript renders as
/// punctuation.
public enum TokenBoundary: Sendable, Hashable {
    /// Neither edge may continue a Latin word. Meaningful only where the needle
    /// itself has Latin edges — see `String.hasLatinWordEdges`.
    case latinWord
    /// The character before the match must not be a letter or digit in any
    /// script, so the match begins a token rather than continuing one.
    case leadingBreak
    /// Plain substring containment.
    case none
}

extension Character {
    /// Whether this character continues a *Latin* word.
    ///
    /// Han and Myanmar characters are letters as far as Swift is concerned, but
    /// they do not extend a Latin token: in 「我们先review一下」 the word `review`
    /// is bounded by 先 and 一. Counting those as word characters makes every
    /// code-switched term unmatchable — the term is right there and the test
    /// reports it missing.
    public var continuesLatinWord: Bool {
        guard isLetter || isNumber || self == "'" || self == "’" else { return false }
        return !unicodeScalars.contains {
            Unicode.isHanScalar($0) || Unicode.isMyanmarScalar($0)
        }
    }
}

extension String {
    /// Whether the string begins and ends with a Latin word character, and so
    /// has edges a word-boundary test can anchor to. "sorry" and "scratch that"
    /// do; 「不对」 does not.
    public var hasLatinWordEdges: Bool {
        guard let first, let last else { return false }
        return first.continuesLatinWord && last.continuesLatinWord
    }

    /// The range of `needle`, skipping any match that fails `boundary`.
    ///
    /// Honors `.backwards`: a rejected candidate keeps the search walking
    /// toward the start rather than giving up, so "the last cue that is really
    /// a cue" is answerable rather than "the last cue, if it happens to be
    /// real". Returned indices are valid in the receiver — the whole reason
    /// this exists rather than each caller searching a lowercased copy and
    /// subscripting the original, which is undefined and can trap.
    public func range(
        ofToken needle: String,
        boundary: TokenBoundary,
        options: String.CompareOptions = []
    ) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        guard boundary != .none else { return range(of: needle, options: options) }

        let backwards = options.contains(.backwards)
        var searchRange = startIndex..<endIndex
        while let found = range(of: needle, options: options, range: searchRange) {
            if satisfies(boundary, at: found) { return found }
            // Narrow past this candidate without stepping over one that
            // overlaps it: forwards moves the start on by one character,
            // backwards pulls the end back by one. Either way the range
            // strictly shrinks, so the walk terminates.
            if backwards {
                guard found.upperBound > startIndex else { return nil }
                searchRange = startIndex..<index(before: found.upperBound)
            } else {
                guard found.lowerBound < endIndex else { return nil }
                searchRange = index(after: found.lowerBound)..<endIndex
            }
        }
        return nil
    }

    private func satisfies(_ boundary: TokenBoundary, at match: Range<String.Index>) -> Bool {
        let leading = match.lowerBound == startIndex
            ? nil
            : self[index(before: match.lowerBound)]
        switch boundary {
        case .none:
            return true
        case .leadingBreak:
            guard let leading else { return true }
            return !(leading.isLetter || leading.isNumber)
        case .latinWord:
            let leadingOK = leading.map { !$0.continuesLatinWord } ?? true
            let trailingOK = match.upperBound == endIndex
                || !self[match.upperBound].continuesLatinWord
            return leadingOK && trailingOK
        }
    }
}
