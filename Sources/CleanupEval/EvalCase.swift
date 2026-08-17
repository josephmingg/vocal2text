import CleanupKit
import CoreModels
import Foundation

/// One stage-3 eval case (docs/05 §7): a transcript, the profile context it is
/// dictated under, and the hard rules its cleaned output must satisfy.
///
/// Cases are data, not code, so the set grows by editing JSON in `evals/cleanup/`
/// and the results stay diffable across model and prompt changes.
public struct EvalCase: Codable, Sendable, Hashable, Identifiable {

    /// Stable identifier — appears in the report, so keep it when editing a case
    /// or the diff stops being readable.
    public var id: String
    /// Which behaviour this case exists to pin (docs/05 §7 groups).
    public var category: String
    public var language: Language
    /// Stage-2 text, as the pipeline would hand it to the provider.
    public var input: String
    /// What a good cleanup looks like. Scored by edit distance only — never
    /// pass/fail, because more than one wording is legitimately correct.
    public var reference: String
    /// The active profile's TASK instructions.
    public var profilePrompt: String
    /// Global custom style prompt; empty when unset, or when the profile ignores
    /// it (the "ignore global style" case sets this empty on purpose).
    public var stylePrompt: String
    /// Dictionary written forms the model must not mangle.
    public var protectedTerms: [String]
    public var rules: [EvalRule]
    /// Why this case is here, for whoever reads a failure six months from now.
    public var note: String?

    public init(
        id: String,
        category: String,
        language: Language,
        input: String,
        reference: String,
        profilePrompt: String = "",
        stylePrompt: String = "",
        protectedTerms: [String] = [],
        rules: [EvalRule] = [],
        note: String? = nil
    ) {
        self.id = id
        self.category = category
        self.language = language
        self.input = input
        self.reference = reference
        self.profilePrompt = profilePrompt
        self.stylePrompt = stylePrompt
        self.protectedTerms = protectedTerms
        self.rules = rules
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, language, input, reference
        case profilePrompt, stylePrompt, protectedTerms, rules, note
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        language = try c.decode(Language.self, forKey: .language)
        input = try c.decode(String.self, forKey: .input)
        reference = try c.decode(String.self, forKey: .reference)
        profilePrompt = try c.decodeIfPresent(String.self, forKey: .profilePrompt) ?? ""
        stylePrompt = try c.decodeIfPresent(String.self, forKey: .stylePrompt) ?? ""
        protectedTerms = try c.decodeIfPresent([String].self, forKey: .protectedTerms) ?? []
        rules = try c.decodeIfPresent([EvalRule].self, forKey: .rules) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// The request the app itself would build for this case.
    public var request: CleanupRequest {
        CleanupRequest(
            text: input,
            language: language,
            profilePrompt: profilePrompt,
            stylePrompt: stylePrompt,
            protectedTerms: protectedTerms
        )
    }
}

/// A machine-checkable hard rule. Deliberately few kinds: a rule a human has to
/// interpret is a rule that scores differently on different days, and AC-4's
/// "≥ 90% of hard-rule checks" is only meaningful if the checks are exact.
public struct EvalRule: Codable, Sendable, Hashable {

    public enum Kind: String, Codable, Sendable {
        /// Every value must appear in the output (case-insensitive).
        case mustContain
        /// No value may appear — fillers, banned words, or the answer to a
        /// question the model was supposed to transcribe rather than answer.
        case mustNotContain
        /// The shipping `ProtectedTermsVerifier` must accept the output.
        case preservesTerms
        /// Output must not exceed this many words. The blunt instrument that
        /// catches a model that decided to be helpful.
        case maxWords
    }

    public var kind: Kind
    public var values: [String]?
    public var limit: Int?
    /// Match exactly as written. Needed for capitalisation cases — a
    /// case-insensitive rule cannot tell `vocal2text` from `Vocal2Text`, and
    /// silently "fails" the correct output.
    public var caseSensitive: Bool?

    public init(
        kind: Kind, values: [String]? = nil, limit: Int? = nil, caseSensitive: Bool? = nil
    ) {
        self.kind = kind
        self.values = values
        self.limit = limit
        self.caseSensitive = caseSensitive
    }

    /// Human-readable form, used in the report.
    public var label: String {
        let cased = (caseSensitive ?? false) ? ", cased" : ""
        switch kind {
        case .mustContain: return "mustContain(\((values ?? []).joined(separator: ", "))\(cased))"
        case .mustNotContain:
            return "mustNotContain(\((values ?? []).joined(separator: ", "))\(cased))"
        case .preservesTerms: return "preservesTerms"
        case .maxWords: return "maxWords(\(limit.map(String.init) ?? "?"))"
        }
    }
}
