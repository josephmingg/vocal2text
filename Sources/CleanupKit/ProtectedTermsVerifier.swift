import Foundation

/// Post-cleanup guard for protected terms (docs/05 §3.4). A protected term may
/// vanish entirely — a legitimate self-correction can delete it — but it must
/// never survive in a mutated spelling. The verifier therefore catches
/// case mutations and single-edit (including adjacent-transposition) variants,
/// not absence.
public enum ProtectedTermsVerifier {
    /// Returns false when any protected term present in `input` appears in
    /// `output` as a case-mutated or edit-distance-1 variant of itself.
    public static func verify(output: String, input: String, protectedTerms: [String]) -> Bool {
        guard !protectedTerms.isEmpty else { return true }
        let outputCharacters = Array(output)
        // Lowercased once here rather than per candidate window: the scan is
        // O(terms × output × window) and this used to allocate a String for
        // every single window, on the delivery path, with the user waiting.
        let loweredOutput = lowercasedCharacters(outputCharacters[...])
        // Case folding can change length (ß → ss, İ → i̇). When it does, the
        // index-aligned fast path is invalid, so fold per window instead.
        let isIndexAligned = loweredOutput.count == outputCharacters.count
        for term in protectedTerms {
            guard !term.isEmpty, input.contains(term) else { continue }
            let found = containsMutatedVariant(
                of: Array(term),
                in: outputCharacters,
                loweredOutput: isIndexAligned ? loweredOutput : nil
            )
            if found { return false }
        }
        return true
    }

    /// Scans every character window of length n−1…n+1 (n = term length — CJK
    /// terms have no word boundaries, so windows replace tokenization). Windows
    /// overlapping an exact occurrence of the term are the term used correctly
    /// and are skipped; any remaining window within edit distance 1 of the
    /// term (case-insensitively, so distance 0 = pure case mutation) is a
    /// mutation.
    ///
    /// `loweredOutput` is `output` case-folded once by the caller, passed in
    /// only when folding preserved the character count so windows can be
    /// sliced straight out of it; nil falls back to folding each window.
    static func containsMutatedVariant(
        of term: [Character],
        in output: [Character],
        loweredOutput: [Character]? = nil
    ) -> Bool {
        guard !term.isEmpty, !output.isEmpty else { return false }
        let exactRanges = exactOccurrenceRanges(of: term, in: output)
        let loweredTerm = lowercasedCharacters(term[...])
        // Single-character terms: only a pure case mutation can be "altered
        // spelling"; any other character is unrelated content, not a mutation
        // (a substitution rule here would flag essentially every output).
        if term.count == 1 {
            let exact = term[0]
            for character in output where character != exact {
                if lowercasedCharacters([character][...]) == loweredTerm {
                    return true
                }
            }
            return false
        }
        for length in max(2, term.count - 1)...(term.count + 1) where length <= output.count {
            for start in 0...(output.count - length) {
                let windowRange = start..<(start + length)
                if exactRanges.contains(where: { $0.overlaps(windowRange) }) { continue }
                let window =
                    loweredOutput.map { Array($0[windowRange]) }
                    ?? lowercasedCharacters(output[windowRange])
                // A proper substring of the term itself (e.g. 微 from 微信, "ob"
                // from "Bob") is ordinary language reuse, not the term in
                // altered spelling — deletion-variant windows that the term
                // fully contains are skipped (docs/05 §3.4 catches mutation,
                // and this was the CJK false-positive path).
                if window.count < loweredTerm.count, isSubsequenceRun(window, of: loweredTerm) {
                    continue
                }
                if isWithinDistanceOne(window, loweredTerm) {
                    return true
                }
            }
        }
        return false
    }

    /// True when `candidate` appears as a contiguous run inside `whole`.
    private static func isSubsequenceRun(_ candidate: [Character], of whole: [Character]) -> Bool {
        guard candidate.count <= whole.count else { return false }
        for start in 0...(whole.count - candidate.count)
        where whole[start..<(start + candidate.count)].elementsEqual(candidate) {
            return true
        }
        return false
    }

    /// Damerau-Levenshtein distance ≤ 1 (one substitution, insertion, deletion,
    /// or adjacent transposition — so "Cluade" counts as one edit from
    /// "Claude"). Single pass, early exit, O(n). Distance 0 also returns true;
    /// callers use that to flag case-only mutations.
    static func isWithinDistanceOne(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        switch a.count - b.count {
        case 0:
            var i = 0
            while i < a.count, a[i] == b[i] { i += 1 }
            // a != b guarantees a mismatch exists, so i < a.count here.
            guard i < a.count else { return true }
            if a[(i + 1)...].elementsEqual(b[(i + 1)...]) {
                return true
            }
            if i + 1 < a.count,
                a[i] == b[i + 1], a[i + 1] == b[i],
                a[(i + 2)...].elementsEqual(b[(i + 2)...]) {
                return true
            }
            return false
        case 1, -1:
            let longer = a.count > b.count ? a : b
            let shorter = a.count > b.count ? b : a
            var i = 0
            while i < shorter.count, longer[i] == shorter[i] { i += 1 }
            return longer[(i + 1)...].elementsEqual(shorter[i...])
        default:
            return false
        }
    }

    private static func exactOccurrenceRanges(
        of term: [Character], in output: [Character]
    ) -> [Range<Int>] {
        guard term.count <= output.count else { return [] }
        var ranges: [Range<Int>] = []
        for start in 0...(output.count - term.count) {
            let candidate = start..<(start + term.count)
            if output[candidate].elementsEqual(term) {
                ranges.append(candidate)
            }
        }
        return ranges
    }

    // Lowercases via String so one-character casings that expand (e.g. İ → i̇)
    // stay grapheme-correct instead of trapping a Character conversion.
    private static func lowercasedCharacters(_ characters: ArraySlice<Character>) -> [Character] {
        Array(String(characters).lowercased())
    }
}
