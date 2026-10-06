import Foundation

/// The one-click output style (docs/17 §5, after Glaido's Standard / Casual /
/// Lowercase / Raw): a simple global layer over profiles. Applies only to
/// profiles that use the global style (`Profile.ignoresGlobalStyle` false), so
/// Terminal / Code stays verbatim whatever is picked here. Deterministic —
/// it works with AI cleanup off, and the model cannot undo it.
public enum DictationStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Today's behaviour: punctuation, capitals, cleanup per profile.
    case standard
    /// Standard, but a single short sentence loses its full stop — chat-like.
    case casual
    /// Casual, all lowercase — dictionary words, acronyms and inner-capital
    /// names ("iPhone") keep their casing.
    case lowercase
    /// The recognizer's words as heard: no AI cleanup, no reformatting;
    /// artifact stripping and dictionary fixes still apply.
    case raw

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .casual: "Casual"
        case .lowercase: "Lowercase"
        case .raw: "Raw"
        }
    }

    public var summary: String {
        switch self {
        case .standard: "Punctuation and capitals, cleaned per app profile."
        case .casual: "Like Standard, but short one-liners drop the final full stop."
        case .lowercase: "Casual and all lowercase; dictionary words and acronyms keep their capitals."
        case .raw: "Exactly what the recognizer heard — no cleanup, no reformatting."
        }
    }
}
