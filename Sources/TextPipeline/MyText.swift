import CoreModels
import Foundation

/// Burmese (Myanmar-script) text helpers shared by stage 1 (normalizer) and
/// stage 4 (post-formatter) — the counterpart of `ZhText` (docs/04 Appendix A).
///
/// Three things make Burmese unlike the other two languages:
///
/// 1. **Two incompatible encodings share the same code points.** Zawgyi, the
///    pre-2019 de-facto font hack, stores different characters at Unicode's
///    Myanmar addresses. Zawgyi text renders as gibberish in a Unicode context
///    and vice versa, and nothing in the byte stream announces which one you
///    have — it must be inferred. See `ZawgyiDetector`.
/// 2. **The script is unspaced**, so nothing here may collapse, insert, or
///    reason about spaces the way the English rules do. Spaces that do appear
///    are phrase separators, not word boundaries.
/// 3. **Sentence punctuation is often absent.** CTC-family recognizers emit no
///    ၊ or ။ at all, so the user speaks them; `spokenPunctuationApplied`
///    turns those spoken commands into marks.
enum MyText {

    /// Myanmar phrase separator, "little section" ၊ (U+104A).
    static let littleSection: Character = "\u{104A}"
    /// Myanmar sentence terminator, "section" ။ (U+104B).
    static let section: Character = "\u{104B}"

    static func isMyanmar(_ character: Character) -> Bool {
        character.unicodeScalars.contains { Unicode.isMyanmarScalar($0) }
    }

    // MARK: - Normalization

    /// Canonical composition (NFC).
    ///
    /// Myanmar text arrives from recognizers, clipboards, and imported
    /// dictionaries in inconsistent normalization, and two visually identical
    /// strings that differ by composition will not compare equal — which
    /// silently breaks dictionary matching and history search. Everything
    /// downstream assumes NFC, so this runs first for Burmese.
    static func normalizedToNFC(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    // MARK: - Digits

    private static let myanmarZero: UInt32 = 0x1040  // ၀
    private static let westernZero: UInt32 = 0x30

    /// Rewrites digits to the user's preferred set (docs/04 Appendix A).
    /// `.asRecognized` is the identity.
    static func applyingDigitPreference(_ text: String, _ preference: MyanmarDigits) -> String {
        switch preference {
        case .asRecognized:
            return text
        case .myanmar:
            return mappingDigits(text, from: westernZero, to: myanmarZero)
        case .western:
            return mappingDigits(text, from: myanmarZero, to: westernZero)
        }
    }

    private static func mappingDigits(_ text: String, from: UInt32, to: UInt32) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            guard (from..<(from + 10)).contains(scalar.value),
                let mapped = Unicode.Scalar(scalar.value - from + to)
            else { return scalar }
            return mapped
        }))
    }

    // MARK: - Spoken punctuation

    /// Spoken punctuation commands → marks.
    ///
    /// Whisper emits Burmese punctuation erratically and CTC engines emit none
    /// at all, so saying the mark is the only reliable way to get one. Each
    /// command is recognized in Burmese and in English (people code-switch the
    /// command words constantly), and a mark already present is left alone.
    ///
    /// Only applied when the profile allows auto-punctuation, so verbatim
    /// profiles still get literal transcription.
    static func spokenPunctuationApplied(_ text: String) -> String {
        var result = text
        for command in punctuationCommands {
            result = replacingCommand(command.spoken, with: command.mark, in: result)
        }
        return collapsingDuplicateMarks(result)
    }

    /// Applied longest command first.
    ///
    /// Several commands are prefixes of others — ပုဒ်မ starts both ပုဒ်မကြီး
    /// and ပုဒ်မငယ် — so a shorter rule running first would eat the head of a
    /// longer one and strand its tail as literal text. Sorting here rather
    /// than trusting the table's hand-written order keeps that safe when
    /// someone adds a command later.
    private static let punctuationCommands: [(spoken: String, mark: Character)] =
        rawPunctuationCommands.sorted { $0.spoken.count > $1.spoken.count }

    private static let rawPunctuationCommands: [(spoken: String, mark: Character)] = [
        // ။ — end of sentence.
        ("ပုဒ်မ", section),
        ("ပုဒ်မကြီး", section),
        ("full stop", section),
        ("full-stop", section),
        ("period", section),
        // ၊ — phrase break.
        ("ပုဒ်ဖြတ်", littleSection),
        ("ပုဒ်မငယ်", littleSection),
        ("comma", littleSection),
    ]

    /// Replaces a spoken command with its mark.
    ///
    /// Burmese has no word boundaries, so the Myanmar-script commands match as
    /// plain substrings; the Latin ones require non-letter neighbors so
    /// "period" inside "periodic" survives. Any run of spaces around the
    /// command collapses into the mark, since a mark never takes a leading
    /// space.
    private static func replacingCommand(
        _ spoken: String, with mark: Character, in text: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: spoken)
        let isLatin = spoken.unicodeScalars.allSatisfy { $0.isASCII }
        let pattern =
            isLatin
            ? "\\s*(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])\\s*"
            : "\\s*" + escaped + "\\s*"
        return PipelineRegex.replacing(pattern: pattern, in: text, with: String(mark))
    }

    /// "။။" or "၊။" — a run of Myanmar marks keeps the last one, which is the
    /// stronger of the pair when a phrase break runs into a sentence end.
    private static func collapsingDuplicateMarks(_ text: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(text.count)
        for character in text {
            if isMark(character), let last = result.last, isMark(last) {
                result.removeLast()
            }
            result.append(character)
        }
        return String(result)
    }

    static func isMark(_ character: Character) -> Bool {
        character == section || character == littleSection
    }

    // MARK: - Spacing and terminal punctuation

    /// Removes spaces that sit immediately before a Myanmar mark and collapses
    /// runs of spaces to one.
    ///
    /// Myanmar is unspaced, but recognizers sprinkle spaces in as syllable
    /// separators. Deleting them all would destroy the phrase separation
    /// Burmese writers do use, so this only fixes what is unambiguously wrong:
    /// a space before a mark, and doubled spaces.
    static func tidiedSpacing(_ text: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(text.count)
        for character in text {
            if character == " " {
                if result.last == " " { continue }
                result.append(character)
                continue
            }
            if isMark(character) {
                while result.last == " " { result.removeLast() }
            }
            result.append(character)
        }
        return String(result)
    }

    /// Appends ။ when a Burmese utterance ends without any terminal mark.
    ///
    /// Mirrors the English terminal-period rule, but the floor is a character
    /// count rather than a word count because the script has no word
    /// boundaries. Six is deliberately low: a Myanmar syllable is typically
    /// two to four Swift Characters — U+102C and U+1038 are excluded from
    /// `SpacingMark` by UAX #29, so they break the grapheme cluster rather
    /// than joining it — which puts the floor at roughly two syllables.
    static func appendingSectionIfSentenceLike(_ text: String) -> String {
        guard let last = text.last else { return text }
        guard !isMark(last), !last.isPunctuation else { return text }
        // Short interjections ("ဟုတ်ကဲ့" — "yes") do not want a full stop.
        guard text.count >= 6 else { return text }
        return text + String(section)
    }
}

/// Detects Zawgyi-encoded Myanmar text so it can be converted to Unicode
/// before anything else looks at it (docs/04 Appendix A).
///
/// Zawgyi and Unicode occupy the same code points, so detection is structural:
/// each encoding produces sequences the other never legally produces. This is
/// a compact rule-based detector in the spirit of google/myanmar-tools, chosen
/// over that library's ~250 KB Markov model because it needs no resource
/// bundle and the app only has to make a binary choice on short dictation-
/// length strings, not score a corpus.
///
/// Detection is deliberately conservative: when nothing decisive appears, the
/// text is treated as Unicode. Mis-converting real Unicode is far more
/// damaging than leaving rare Zawgyi alone, because conversion is lossy in
/// that direction.
public enum ZawgyiDetector: Sendable {

    /// True when `text` looks like Zawgyi rather than Unicode Myanmar.
    public static func isZawgyi(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: { Unicode.isMyanmarScalar($0) }) else {
            return false
        }
        return zawgyiEvidence(in: text) > unicodeEvidence(in: text)
    }

    /// Code points that exist only in Zawgyi's layout — Unicode assigns these
    /// to Shan/Mon/Karen letters that essentially never appear in Burmese
    /// text, whereas Zawgyi reuses them for common Burmese glyph variants.
    private static let zawgyiOnlyScalars: Set<UInt32> = [
        0x1060, 0x1061, 0x1062, 0x1063, 0x1064, 0x1065, 0x1066, 0x1067,
        0x1068, 0x1069, 0x106A, 0x106B, 0x106C, 0x106D, 0x106E, 0x106F,
        0x1070, 0x1071, 0x1072, 0x1073, 0x1074, 0x1075, 0x1076, 0x1077,
        0x1078, 0x1079, 0x107A, 0x107B, 0x107C, 0x107D, 0x107E, 0x107F,
        0x1080, 0x1081, 0x1082, 0x1083, 0x1084, 0x1085, 0x1086, 0x1087,
        0x1088, 0x1089, 0x108A, 0x108B, 0x108C, 0x108D, 0x108E, 0x108F,
        0x1090, 0x1091, 0x1092, 0x1093, 0x1094, 0x1095, 0x1096, 0x1097,
        0x1098, 0x1099, 0x109A, 0x109B, 0x109C, 0x109D,
    ]

    private static func zawgyiEvidence(in text: String) -> Int {
        var score = 0
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if zawgyiOnlyScalars.contains(scalar.value) {
                score += 2
                continue
            }
            // Zawgyi stores the ေ vowel *before* its consonant; Unicode stores
            // it after. A ေ followed directly by a consonant is Zawgyi order.
            if scalar.value == 0x1031, index + 1 < scalars.count,
                isConsonant(scalars[index + 1])
            {
                score += 1
            }
            // Likewise ျ (medial ya) preceding its consonant.
            if scalar.value == 0x103B, index + 1 < scalars.count,
                isConsonant(scalars[index + 1])
            {
                score += 1
            }
        }
        return score
    }

    private static func unicodeEvidence(in text: String) -> Int {
        var score = 0
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            guard index > 0 else { continue }
            // Unicode order: consonant then ေ, consonant then ျ.
            if scalar.value == 0x1031 || scalar.value == 0x103B {
                if isConsonant(scalars[index - 1]) { score += 1 }
            }
            // ်  (asat) always follows a consonant in Unicode; Zawgyi's
            // equivalent stacking differs.
            if scalar.value == 0x103A, isConsonant(scalars[index - 1]) {
                score += 1
            }
        }
        return score
    }

    private static func isConsonant(_ scalar: Unicode.Scalar) -> Bool {
        (0x1000...0x102A).contains(scalar.value)
    }
}
