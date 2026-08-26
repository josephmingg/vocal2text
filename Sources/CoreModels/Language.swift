import Foundation

/// Languages the pipeline understands. Designed additive: a new language is a
/// new case plus rule branches in the shared stages (docs/04 §2 records how
/// additive that stayed in practice for Burmese).
public enum Language: String, Codable, Sendable, CaseIterable, Hashable {
    case english = "en"
    case chinese = "zh"
    /// Burmese (Myanmar), added in v1.1. Unspaced script, so it shares the
    /// Chinese side of every "does this language have word boundaries"
    /// decision rather than the English one (docs/04 Appendix A).
    case burmese = "my"

    public var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        case .burmese: "မြန်မာ"
        }
    }

    /// Compact label for the menu-bar toggle and the HUD badge, where there is
    /// room for two or three characters.
    public var shortLabel: String {
        switch self {
        case .english: "EN"
        case .chinese: "中文"
        case .burmese: "မြန်မာ"
        }
    }

    /// True when the script runs words together, so word-boundary logic
    /// (regex `\b`, whitespace tokenization, Latin space hygiene) does not
    /// apply. Drives dictionary match-mode defaults and validator thresholds.
    public var isUnspacedScript: Bool {
        switch self {
        case .english: false
        case .chinese, .burmese: true
        }
    }

    /// Whether AI cleanup (stage 3) is offered for this language by default.
    ///
    /// Burmese ships opt-out: the small local models this app targets corrupt
    /// Burmese text rather than tidy it (docs/04 Appendix A), so a Burmese
    /// dictation goes through the deterministic stages only unless the user
    /// deliberately turns cleanup on for it.
    public var allowsCleanupByDefault: Bool {
        switch self {
        case .english, .chinese: true
        case .burmese: false
        }
    }
}

/// The user-facing language mode for a dictation: automatic per-utterance
/// detection, or pinned to one language (menu-bar toggle / per-profile pin).
public enum LanguageMode: Codable, Sendable, Hashable {
    case auto
    case pinned(Language)

    public var pinnedLanguage: Language? {
        if case .pinned(let l) = self { return l }
        return nil
    }
}

/// What both apps tell the user about Burmese support, in one place.
///
/// Burmese ships with a genuinely uneven story — the text layer is complete
/// while recognition quality is not — and it would be easy to imply
/// EN/ZH-grade accuracy by staying vague. This says what works and what does
/// not, and both platforms show the same words.
public enum BurmeseSupportNote: Sendable {
    /// Long form for a settings pane.
    public static let text = """
        Burmese (မြန်မာ) is new in 1.1. In place today: Unicode normalization, \
        script-aware formatting, and the custom dictionary. On the Mac, the \
        digit-set preference and spoken punctuation are set per profile in \
        Settings → Profiles (the iPhone app has no profile editor yet); the \
        spoken-command vocabulary still needs native-speaker validation, so \
        commands ship off and English-only. Recognition: on the Mac, pinning \
        မြန်မာ runs a dedicated Burmese model (Meta's Omnilingual ASR — about \
        1 character in 9 wrong in our benchmark; the first Burmese dictation \
        downloads ~790 MB). Auto-detect, and iPhone for now, still fall to \
        Whisper, which transcribes Burmese poorly. AI cleanup stays off for \
        Burmese: small local models corrupt it more often than they help.
        """

    /// Short form for the HUD and engine availability reporting.
    public static let shortCaveat =
        "Whisper transcribes Burmese poorly — expect frequent errors."
}

/// Chinese script preference. v1 ships Simplified output; Traditional arrives
/// later as a deterministic conversion toggle (owner decision, docs/08 B5).
public enum ChineseScript: String, Codable, Sendable {
    case simplified
    case traditional
}

/// Which digits Burmese output uses (docs/04 Appendix A: "Myanmar vs Arabic
/// digits as a preference"). Recognizers are inconsistent about this, so the
/// choice is enforced deterministically in stage 4 rather than hoped for.
public enum MyanmarDigits: String, Codable, Sendable, CaseIterable {
    /// Leave whatever the recognizer produced.
    case asRecognized
    /// ၀၁၂၃၄၅၆၇၈၉ (U+1040–U+1049).
    case myanmar
    /// 0123456789.
    case western

    public var displayName: String {
        switch self {
        case .asRecognized: "As recognized"
        case .myanmar: "မြန်မာ (၀၁၂၃)"
        case .western: "Western (0123)"
        }
    }
}
