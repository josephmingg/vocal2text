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
    /// Precedence, strongest evidence first:
    ///
    /// 1. **A pin.** The user said which language they are speaking; nothing
    ///    outranks that. Auto-detect is the top complaint about tools in this
    ///    category, which is why the pin exists at all.
    /// 2. **The script in the output.** Myanmar or Han characters are proof,
    ///    not inference. Whisper's own language ID is a whole-clip guess made
    ///    before decoding and is unreliable on short utterances — but it
    ///    cannot produce Myanmar characters for an English sentence.
    /// 3. **The engine's reported tag**, for languages that share the Latin
    ///    script and so cannot be told apart from characters.
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
        if let fromScript = scriptLanguage(of: text) { return fromScript }
        if let reportedTag, let reported = Language(rawValue: normalized(reportedTag)) {
            return reported
        }
        return .english
    }

    /// The language a string's script proves, or nil when the script is shared
    /// (Latin) and therefore proves nothing.
    ///
    /// Checked in order of how exclusive each script is. Burmese comes first:
    /// Myanmar characters appear in no other language this app supports, while
    /// Burmese text routinely embeds Latin words and digits.
    public static func scriptLanguage(of text: String) -> Language? {
        if text.containsMyanmarCharacters { return .burmese }
        if text.containsHanCharacters { return .chinese }
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
