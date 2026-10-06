import CoreModels
import Foundation

/// Applies a `DictationStyle` to finished English text, after stage 4
/// (docs/17 §5). `.standard` and `.raw` pass through — raw is realised
/// earlier, by running the pipeline verbatim and skipping cleanup.
public enum StyleFormatter {

    /// A take this short (in words) that is one sentence counts as a chat
    /// one-liner for `.casual` / `.lowercase`.
    static let oneLinerMaxWords = 12

    public static func apply(
        _ text: String,
        style: DictationStyle,
        language: Language,
        protectedTerms: [String]
    ) -> String {
        guard language == .english, !text.isEmpty else { return text }
        switch style {
        case .standard, .raw:
            return text
        case .casual:
            return droppingOneLinerPeriod(text)
        case .lowercase:
            return lowercased(droppingOneLinerPeriod(text), keeping: protectedTerms)
        }
    }

    /// "Sounds good." → "Sounds good"; leaves multi-sentence text, questions,
    /// exclamations and ellipses alone, and never touches a decimal or an
    /// abbreviation ending the text ("see the U.S.").
    static func droppingOneLinerPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."), !trimmed.contains("\n")
        else { return text }
        let body = trimmed.dropLast()
        // Any other sentence end means this is prose, not a one-liner.
        if body.range(of: "[.!?]\\s", options: .regularExpression) != nil { return text }
        let words = body.split(whereSeparator: \.isWhitespace)
        guard let last = words.last, words.count <= oneLinerMaxWords else { return text }
        // "U.S." / "e.g." keep their final dot — it belongs to the word.
        if last.contains(".") { return text }
        guard let range = text.range(of: trimmed) else { return text }
        return text.replacingCharacters(in: range, with: String(body))
    }

    /// Lowercases every word except protected terms (dictionary written
    /// forms, matched case-sensitively), all-caps acronyms of two or more
    /// letters, and tokens with inner capitals ("iPhone", "GitHub").
    static func lowercased(_ text: String, keeping protectedTerms: [String]) -> String {
        // Protected spans first, so a multi-word term ("Claude Code") keeps
        // its casing as a unit.
        var protectedRanges: [Range<String.Index>] = []
        for term in protectedTerms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                let found = text.range(of: term, range: searchStart..<text.endIndex) {
                protectedRanges.append(found)
                searchStart = found.upperBound
            }
        }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if let span = protectedRanges.first(where: { $0.lowerBound == index }) {
                result += text[span]
                index = span.upperBound
                continue
            }
            guard text[index].isLetter else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter || text[end].isNumber,
                !protectedRanges.contains(where: { $0.lowerBound == end && end != index }) {
                end = text.index(after: end)
            }
            let word = text[index..<end]
            result += keepsCasing(word) ? String(word) : word.lowercased()
            index = end
        }
        return result
    }

    private static func keepsCasing(_ word: Substring) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if letters.allSatisfy(\.isUppercase) { return true }
        // An inner capital ("iPhone", "GitHub", "McDonald") is a name.
        return letters.dropFirst().contains(where: \.isUppercase)
    }
}
