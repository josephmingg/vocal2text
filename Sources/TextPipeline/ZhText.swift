import Foundation

/// Chinese-text helpers shared by stage 1 (normalizer) and stage 4 (post-formatter).
enum ZhText {
    /// True when the character contains a Han (CJK ideograph) scalar — the
    /// character-level counterpart of `String.containsHanCharacters` (CoreModels).
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)        // CJK Unified
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
                || (0xF900...0xFAFF).contains(scalar.value) // Compatibility
        }
    }

    /// Half-width ASCII punctuation → full-width equivalents（，。！？；：）.
    static let halfToFullWidthMap: [Character: Character] = [
        ",": "，",
        ".": "。",
        "!": "！",
        "?": "？",
        ";": "；",
        ":": "：",
    ]

    /// Converts half-width punctuation to full-width only when the characters on
    /// both sides are Han, so "3.14", "U.S.", and code-switched Latin spans are
    /// never touched (docs/05 §1, §6).
    static func convertHalfWidthPunctuationBetweenHan(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count >= 3 else { return text }
        var result = characters
        for index in 1..<(characters.count - 1) {
            guard let fullWidth = halfToFullWidthMap[characters[index]] else { continue }
            if isHan(characters[index - 1]), isHan(characters[index + 1]) {
                result[index] = fullWidth
            }
        }
        return String(result)
    }

    /// Stage 4's stricter enforcement (docs/05 §6): converts a half-width mark
    /// whose *preceding* character is Han when the following character is Han,
    /// whitespace, or absent — so sentence-final "今天天气很好." becomes 。 while
    /// "3.14" and "U.S." stay safe (Han-left-neighbor guard).
    static func enforceFullWidthPunctuationAfterHan(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count >= 2 else { return text }
        var result = characters
        for index in 1..<characters.count {
            guard let fullWidth = halfToFullWidthMap[characters[index]] else { continue }
            guard isHan(characters[index - 1]) else { continue }
            let isLast = index == characters.count - 1
            if isLast || characters[index + 1].isWhitespace || isHan(characters[index + 1]) {
                result[index] = fullWidth
            }
        }
        return String(result)
    }

    /// Removes a single ASCII space wedged between two Han characters (a Whisper
    /// artifact, docs/05 §1). A run of two or more spaces is left alone: only a
    /// space whose immediate neighbors are both Han is spurious with confidence.
    static func removeSingleSpacesBetweenHan(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count >= 3 else { return text }
        var result: [Character] = []
        result.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if character == " ",
               index > 0,
               index < characters.count - 1,
               isHan(characters[index - 1]),
               isHan(characters[index + 1]) {
                continue
            }
            result.append(character)
        }
        return String(result)
    }

    /// Inserts a thin space (U+2009) between directly adjacent Han and
    /// Latin-letter/digit characters ("pangu" spacing, docs/05 §6). Pairs already
    /// separated by any whitespace are untouched, so the pass is idempotent.
    static func applyPanguSpacing(_ text: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(text.count)
        var previous: Character?
        for character in text {
            if let previous, needsThinSpace(between: previous, and: character) {
                result.append("\u{2009}")
            }
            result.append(character)
            previous = character
        }
        return String(result)
    }

    private static func needsThinSpace(between left: Character, and right: Character) -> Bool {
        (isHan(left) && isLatinOrDigit(right)) || (isLatinOrDigit(left) && isHan(right))
    }

    private static func isLatinOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

/// Small shared regex convenience for the pipeline stages. Patterns are static,
/// known-good strings; the (never-expected) compile failure degrades to returning
/// the input unchanged rather than crashing a dictation mid-flight.
enum PipelineRegex {
    static func replacing(pattern: String, in text: String, with template: String = "") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
