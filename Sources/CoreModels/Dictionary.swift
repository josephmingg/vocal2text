import Foundation

/// A user dictionary override: what the recognizer tends to produce → what should
/// appear. Semantics specified in docs/05 §2 and enforced by TextPipeline stage 2.
public struct DictionaryEntry: Codable, Sendable, Hashable, Identifiable {
    public enum MatchMode: String, Codable, Sendable {
        /// Word-boundary match (Latin scripts). Multi-word spoken forms allowed;
        /// internal whitespace matches any single whitespace run.
        case word
        /// Literal substring match (CJK — no word boundaries exist).
        case phrase
    }

    public var id: UUID
    /// What ASR tends to produce, matched case-insensitively.
    public var spoken: String
    /// What should appear; casing is authoritative.
    public var written: String
    public var matchMode: MatchMode
    /// nil = applies to all languages.
    public var languages: Set<Language>?
    public var isEnabled: Bool
    public var createdAt: Date
    public var lastAppliedAt: Date?
    public var applyCount: Int

    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        matchMode: MatchMode? = nil,
        languages: Set<Language>? = nil,
        isEnabled: Bool = true,
        createdAt: Date = .init(timeIntervalSince1970: 0),
        lastAppliedAt: Date? = nil,
        applyCount: Int = 0
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        // Entries containing Han characters default to phrase matching (docs/05 §2).
        self.matchMode = matchMode ?? (spoken.containsHanCharacters ? .phrase : .word)
        self.languages = languages
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastAppliedAt = lastAppliedAt
        self.applyCount = applyCount
    }
}

extension String {
    /// True if the string contains any Han (CJK ideograph) scalar.
    public var containsHanCharacters: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)        // CJK Unified
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
                || (0xF900...0xFAFF).contains(scalar.value) // Compatibility
        }
    }
}
