import Foundation

/// Languages the pipeline understands. Designed additive: a new language is a new
/// case plus rule files — no pipeline changes (docs/04 §2).
public enum Language: String, Codable, Sendable, CaseIterable, Hashable {
    case english = "en"
    case chinese = "zh"

    public var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
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

/// Chinese script preference. v1 ships Simplified output; Traditional arrives
/// later as a deterministic conversion toggle (owner decision, docs/08 B5).
public enum ChineseScript: String, Codable, Sendable {
    case simplified
    case traditional
}
