import CoreModels
import Foundation

/// Burmese (Myanmar-script) text helpers shared by stage 1 (normalizer) and
/// stage 4 (post-formatter) — the counterpart of `ZhText` (docs/04 Appendix A).
///
/// Two things make Burmese unlike the other two languages here:
///
/// 1. **The script is unspaced**, so nothing here may collapse, insert, or
///    reason about spaces the way the English rules do. Spaces that do appear
///    are phrase separators, not word boundaries.
/// 2. **Sentence punctuation is often absent** from recognizer output, so the
///    pipeline supplies it: `appendingSectionIfSentenceLike`, plus opt-in
///    spoken commands via `spokenPunctuationApplied`.
///
/// Zawgyi — the pre-2019 encoding hack that reuses Unicode's Myanmar code
/// points — is deliberately NOT handled: a rule-based detector prototype
/// misclassified legitimate Unicode Burmese and was removed in review.
/// docs/11 G14 tracks porting google/myanmar-tools if it proves needed.
enum MyText {

    /// Myanmar phrase separator, "little section" ၊ (U+104A).
    static let littleSection: Character = "\u{104A}"
    /// Myanmar sentence terminator, "section" ။ (U+104B).
    static let section: Character = "\u{104B}"

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
    /// Burmese recognizers punctuate erratically (Whisper) or not at all
    /// (CTC engines), so saying the mark is the only reliable way to get
    /// one. v1.1 recognizes only English command words — Burmese speakers
    /// code-switch them constantly — because the Myanmar-script commands
    /// this branch briefly carried were byte-identical to ordinary
    /// vocabulary (ပုဒ်မ is the everyday word for "section/article") and a
    /// substring match destroyed legitimate prose. Reintroducing them needs
    /// a native-speaker-validated vocabulary: docs/11 G18.
    ///
    /// Gated behind `FormattingOptions.myanmarSpokenPunctuation`, which
    /// ships OFF.
    static func spokenPunctuationApplied(_ text: String) -> String {
        var result = text
        for command in punctuationCommands {
            result = replacingCommand(command.spoken, with: command.mark, in: result)
        }
        return collapsingDuplicateMarks(result)
    }

    /// Longest command first, recomputed rather than hand-maintained, so a
    /// multi-word command ("full stop") is always consumed before a shorter
    /// one could partially match inside it.
    private static let punctuationCommands: [(spoken: String, mark: Character)] =
        rawPunctuationCommands.sorted { $0.spoken.count > $1.spoken.count }

    private static let rawPunctuationCommands: [(spoken: String, mark: Character)] = [
        // ။ — end of sentence.
        ("full stop", section),
        ("full-stop", section),
        ("period", section),
        // ၊ — phrase break.
        ("comma", littleSection),
    ]

    /// Replaces a spoken command with its mark. Every command is a Latin word
    /// or phrase and must stand alone — the lookarounds keep "periodic" and
    /// "commander" intact — and the outer `\s*` folds surrounding spaces into
    /// the mark, since a mark never takes a leading space.
    private static func replacingCommand(
        _ spoken: String, with mark: Character, in text: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: spoken)
        let pattern = "\\s*(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])\\s*"
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
    /// Mirrors the English terminal-period rule with two Burmese-shaped
    /// guards. The floor is a character count (the script has no word
    /// boundaries): a syllable is typically two to four Swift Characters —
    /// U+102C and U+1038 are excluded from `SpacingMark` by UAX #29, so they
    /// break the grapheme cluster rather than joining it — which puts five
    /// at roughly two syllables: enough for a minimal complete sentence
    /// (မလုပ်ဘူး), while interjections (ဟုတ်ကဲ့) stay bare. And the text must
    /// actually contain a Myanmar letter: a dictated phone number is not a
    /// sentence, however long.
    static func appendingSectionIfSentenceLike(_ text: String) -> String {
        guard let last = text.last else { return text }
        guard !isMark(last), !last.isPunctuation else { return text }
        guard text.unicodeScalars.contains(where: isMyanmarLetter) else { return text }
        guard text.count >= 5 else { return text }
        return text + String(section)
    }

    /// Myanmar consonants and independent vowels — the scalars that can
    /// carry a sentence, as opposed to digits, signs, and punctuation.
    private static func isMyanmarLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x1000...0x102A).contains(scalar.value)
    }
}
