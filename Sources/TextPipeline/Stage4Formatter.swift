import CoreModels
import Foundation

/// Stage 4 of the text pipeline (docs/05 §6): the deterministic post-formatter.
/// Runs even when AI cleanup is off; every rule is gated by the active profile's
/// `FormattingOptions`, so `FormattingOptions.verbatim` passes text through.
public enum Stage4Formatter: Sendable {
    /// Formats pipeline output for delivery.
    ///
    /// `precedingContext` is the text immediately before the insertion point
    /// (session-tracked last insert, AX read, or `documentContextBeforeInput`).
    /// `nil` means a fresh insertion point: no prefix and no capitalization
    /// beyond stage 1's.
    public static func format(
        _ text: String,
        language: Language,
        formatting: FormattingOptions,
        precedingContext: String?
    ) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        switch language {
        case .chinese:
            if formatting.enforceFullWidthZhPunctuation {
                result = ZhText.enforceFullWidthPunctuationAfterHan(result)
            }
            if formatting.panguSpacing {
                result = ZhText.applyPanguSpacing(result)
            }
        case .burmese:
            // The digit preference is a display choice, not punctuation, so it
            // applies even to verbatim profiles — a Burmese user who asked for
            // Myanmar numerals wants them in the terminal too.
            result = MyText.applyingDigitPreference(result, formatting.myanmarDigits)
            if formatting.autoPunctuation {
                result = MyText.tidiedSpacing(result)
            }
        case .english:
            if formatting.autoPunctuation {
                // docs/15 step 51: unambiguous spoken numbers become digits
                // deterministically — no model involved, so it works with
                // cleanup off and never hallucinates arithmetic.
                result = SpokenNumberFormatter.apply(result)
                result = collapseDuplicateTerminalPunctuation(result)
            }
            if formatting.structureAllowed {
                // docs/15 step 30 (layout slice): spoken breaks become real.
                result = SpokenLayoutCommands.apply(result)
            }
            if formatting.codeMode {
                // docs/15 step 31: spoken symbols and casing become code.
                result = CodeModeFormatter.apply(result)
            }
            if formatting.smartSpacing, let context = precedingContext {
                // Code-mode output is identifiers — never sentence-capitalize
                // it, or "user_name = five" becomes "User_name = five".
                result = smartSpaced(
                    result, against: context, capitalize: !formatting.codeMode
                )
            }
        }
        return result
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// "!!" → "!", "?." → "?": a run of terminal marks keeps its first mark.
    /// Single marks ("U.S.", "3.14") are runs of one and never touched.
    ///
    /// A collapsed run now ends a sentence, so the word after it takes a
    /// capital: "Wait... are you serious?" → "Wait. Are you serious?", never
    /// a full stop followed by a lowercase word (owner decision, docs/17 F3).
    /// Only words after a *collapsed* run are capitalized — "e.g. this" and
    /// other single marks keep the speaker's casing — and a word spelled
    /// with an inner capital ("iPhone") keeps it. A run of dots between two
    /// digits is a range ("pages 1..5"), not punctuation, and is kept.
    private static func collapseDuplicateTerminalPunctuation(_ text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: "(\\d)(\\.{2,})(?=\\d)|([.!?])[.!?]+(?:(\\s+)(\\p{Ll}[\\p{L}\\p{N}]*))?"
            )
        else { return text }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            // Leftmost match wins, so a digit range is claimed at its first
            // digit before the dots could be read as punctuation.
            guard match.range(at: 3).location != NSNotFound else {
                result += nsText.substring(with: match.range)
                continue
            }
            result += nsText.substring(with: match.range(at: 3))
            if match.range(at: 5).location != NSNotFound {
                result += nsText.substring(with: match.range(at: 4))
                result += Stage1Normalizer.capitalizedFirstLetter(nsText.substring(with: match.range(at: 5)))
            }
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// Spacing only, never casing: a snippet's written form is authoritative
    /// ("joseph@example.com" must not become "Joseph@example.com" after a
    /// full stop), but it still needs a separating space after a word.
    public static func spacedOnly(_ text: String, precedingContext: String?) -> String {
        guard !text.isEmpty, let context = precedingContext else { return text }
        return smartSpaced(text, against: context, capitalize: false)
    }

    // Capitalization keys off the last non-whitespace character so "Done. "
    // (space already present) still starts a new sentence; the space prefix keys
    // off the literal last character so an existing space is never doubled.
    private static func smartSpaced(
        _ text: String, against context: String, capitalize: Bool
    ) -> String {
        var result = text
        if capitalize,
           let lastVisible = context.reversed().first(where: { !$0.isWhitespace }),
           sentenceTerminators.contains(lastVisible) {
            result = Stage1Normalizer.capitalizedFirstLetter(result)
        }
        // Text that opens with its own break ("\n\nnext topic" from a layout
        // command) needs no separating space — prepending one would deposit
        // a stray trailing space on the previous line.
        if let last = context.last, !last.isWhitespace, result.first?.isNewline != true {
            result = " " + result
        }
        return result
    }
}
