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
        if language == .chinese {
            if formatting.enforceFullWidthZhPunctuation {
                result = ZhText.enforceFullWidthPunctuationAfterHan(result)
            }
            if formatting.panguSpacing {
                result = ZhText.applyPanguSpacing(result)
            }
        }
        if language == .english, formatting.autoPunctuation {
            result = collapseDuplicateTerminalPunctuation(result)
        }
        if language == .english, formatting.smartSpacing, let context = precedingContext {
            result = smartSpaced(result, against: context)
        }
        return result
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// "!!" → "!", "?." → "?": a run of terminal marks keeps its first mark.
    /// Single marks ("U.S.", "3.14") are runs of one and never touched.
    private static func collapseDuplicateTerminalPunctuation(_ text: String) -> String {
        PipelineRegex.replacing(pattern: "([.!?])[.!?]+", in: text, with: "$1")
    }

    // Capitalization keys off the last non-whitespace character so "Done. "
    // (space already present) still starts a new sentence; the space prefix keys
    // off the literal last character so an existing space is never doubled.
    private static func smartSpaced(_ text: String, against context: String) -> String {
        var result = text
        if let lastVisible = context.reversed().first(where: { !$0.isWhitespace }),
           sentenceTerminators.contains(lastVisible) {
            result = Stage1Normalizer.capitalizedFirstLetter(result)
        }
        if let last = context.last, !last.isWhitespace {
            result = " " + result
        }
        return result
    }
}
