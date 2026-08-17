import CoreModels
import Foundation

/// Resolves which `Language` an utterance is, from whatever evidence the
/// engine could supply (docs/04 §2).
///
/// Lives here rather than inside an engine adapter because every adapter needs
/// the same answer and "what language was that?" must not vary by backend —
/// the whole text pipeline branches on it.
public enum LanguageDetector: Sendable {

    /// Resolves the language for one transcription result.
    ///
    /// Precedence:
    ///
    /// 1. **A pin.** The user said which language they are speaking; nothing
    ///    outranks that.
    /// 2. **The engine's reported tag**, unless the transcript's *dominant*
    ///    script contradicts it. The tag is a whole-clip guess made before
    ///    decoding and is unreliable on short utterances, so a transcript
    ///    that is mostly Han or Myanmar overrides a Latin tag — but a few
    ///    stray characters never do. One 中 in an English sentence, or a
    ///    single hallucinated Myanmar scalar (Whisper produces those on
    ///    Burmese audio), must not reroute the whole take through another
    ///    language's formatter, dictionary semantics, and cleanup prompt.
    /// 3. **The dominant script alone**, when the engine offered no usable
    ///    tag.
    /// 4. **English**, the fallback.
    ///
    /// - Parameters:
    ///   - reportedTag: BCP-47-ish tag from the engine ("en", "zh", "my"), if
    ///     it offers one. Tags outside `Language` are ignored rather than
    ///     forced onto the nearest case.
    ///   - text: the decoded transcript.
    ///   - mode: the active language mode.
    public static func detect(
        reportedTag: String?,
        text: String,
        mode: LanguageMode
    ) -> Language {
        if let pinned = mode.pinnedLanguage { return pinned }
        let dominant = dominantScriptLanguage(of: text)
        if let reportedTag, let reported = Language(rawValue: normalized(reportedTag)) {
            if let dominant, dominant != reported { return dominant }
            return reported
        }
        if let dominant { return dominant }
        return .english
    }

    /// The language whose script accounts for the majority of the letters in
    /// `text`, or nil when none does.
    ///
    /// Letters only — digits, punctuation, and whitespace say nothing about
    /// language. Latin never wins here: a mostly-Latin transcript proves only
    /// "some Latin-script language", which cannot pick between them; the
    /// reported tag or the English fallback decides those.
    public static func dominantScriptLanguage(of text: String) -> Language? {
        var han = 0
        var myanmar = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            letters += 1
            if Unicode.isHanScalar(scalar) {
                han += 1
            } else if Unicode.isMyanmarScalar(scalar) {
                myanmar += 1
            }
        }
        guard letters > 0 else { return nil }
        if han * 2 > letters { return .chinese }
        if myanmar * 2 > letters { return .burmese }
        return nil
    }

    /// Accepts the spellings engines actually emit — "MY", "my-MM", "zh_CN" —
    /// and reduces them to the primary subtag.
    private static func normalized(_ tag: String) -> String {
        let lowered = tag.lowercased()
        let primary = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return String(primary ?? lowered[...])
    }
}
