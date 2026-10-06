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
    /// Explicit snippet choice; nil derives it from the written form (see
    /// `isSnippet`). Optional so documents written before it existed decode
    /// unchanged and older builds simply ignore the key.
    public var snippet: Bool?

    /// A snippet is a voice shortcut ("my address" → a multi-line address),
    /// not a spelling fix: it fires only when it is the *whole* dictation
    /// (docs/17 F5), its written form is never fed to the recognizer as a
    /// bias term, and cleanup never sees it as a protected term. Unset, a
    /// multi-line or long (> 40 characters) written form makes an entry a
    /// snippet — the same line the recognizer's bias filter already drew.
    public var isSnippet: Bool {
        snippet ?? Self.looksLikeSnippet(written)
    }

    public static func looksLikeSnippet(_ written: String) -> Bool {
        written.contains(where: \.isNewline) || written.count > 40
    }

    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        matchMode: MatchMode? = nil,
        languages: Set<Language>? = nil,
        isEnabled: Bool = true,
        createdAt: Date = .init(timeIntervalSince1970: 0),
        lastAppliedAt: Date? = nil,
        applyCount: Int = 0,
        snippet: Bool? = nil
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        // Unspaced scripts have no word boundaries to anchor on, so entries
        // written in one default to phrase matching (docs/05 §2).
        self.matchMode =
            matchMode
            ?? ((spoken.containsHanCharacters || spoken.containsMyanmarCharacters)
                ? .phrase : .word)
        self.languages = languages
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastAppliedAt = lastAppliedAt
        self.applyCount = applyCount
        self.snippet = snippet
    }
}

extension Array where Element == DictionaryEntry {
    /// Written forms that are vocabulary — recognizer bias terms and
    /// cleanup's protected terms. Snippets are expansions, not words.
    public var vocabularyTerms: [String] {
        filter { !$0.isSnippet }.map(\.written)
    }
}

extension String {
    /// True if the string contains any Han (CJK ideograph) scalar.
    public var containsHanCharacters: Bool {
        unicodeScalars.contains { Unicode.isHanScalar($0) }
    }

    /// True if the string contains any Myanmar-script scalar.
    public var containsMyanmarCharacters: Bool {
        unicodeScalars.contains { Unicode.isMyanmarScalar($0) }
    }
}

/// Script predicates shared by the models, the text pipeline, and the cleanup
/// validator. One definition per script, so "is this Burmese?" cannot drift
/// between the layer that detects it and the layer that formats it.
extension Unicode {
    public static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)        // CJK Unified
            || (0x3400...0x4DBF).contains(scalar.value) // Extension A
            || (0xF900...0xFAFF).contains(scalar.value) // Compatibility
    }

    /// The Myanmar block plus the two extension blocks. Covers Burmese proper
    /// and the minority-language letters that share the script, so text mixing
    /// them is never half-detected.
    public static func isMyanmarScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x1000...0x109F).contains(scalar.value)        // Myanmar
            || (0xAA60...0xAA7F).contains(scalar.value) // Extended-A
            || (0xA9E0...0xA9FF).contains(scalar.value) // Extended-B
    }
}
