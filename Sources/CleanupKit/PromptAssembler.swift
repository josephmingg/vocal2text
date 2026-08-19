import CoreModels
import Foundation

/// Assembles the stage-3 system prompt from the versioned prompt resources
/// bundled with CleanupKit (docs/05 §3.3). Templates are loaded once at init
/// and cached; the per-request slots are filled on each call.
public struct PromptAssembler: Sendable {
    /// Placeholder tokens in `system_core.txt`.
    private enum Slot {
        static let languageRules = "{LANGUAGE_RULES}"
        static let protectedTerms = "{PROTECTED_TERMS}"
        static let profilePrompt = "{PROFILE_PROMPT}"
        static let stylePrompt = "{STYLE_PROMPT}"
        /// Lives inside `lang_en.txt`, so it is filled after the language
        /// rules are spliced in.
        static let spellingRule = "{SPELLING_RULE}"
    }

    private let coreTemplate: String
    private let languageRules: [Language: String]
    /// Wrapper for a non-empty style prompt; see `styleBlock(for:)`.
    private let styleSection: String
    /// Spelling instruction used when no style prompt is set; see
    /// `spellingRuleBlock(for:)`.
    private let spellingDefault: String

    /// Loads the bundled templates. A missing resource degrades to an empty
    /// template rather than crashing; the assembler itself never fails.
    public init() {
        self.init(
            coreTemplate: Self.loadPrompt(named: "system_core"),
            languageRules: [
                .english: Self.loadPrompt(named: "lang_en"),
                .chinese: Self.loadPrompt(named: "lang_zh"),
                .burmese: Self.loadPrompt(named: "lang_my"),
            ],
            styleSection: Self.loadPrompt(named: "style_section"),
            spellingDefault: Self.loadPrompt(named: "spelling_default")
        )
    }

    /// Injection seam for tests and prompt experiments. `styleSection` defaults
    /// to a bare passthrough so an injected core template behaves verbatim, and
    /// `spellingDefault` to nothing at all — an injected template that carries
    /// no `{SPELLING_RULE}` slot is then unaffected either way.
    public init(
        coreTemplate: String,
        languageRules: [Language: String],
        styleSection: String = "{STYLE_PROMPT}",
        spellingDefault: String = ""
    ) {
        self.coreTemplate = coreTemplate
        self.languageRules = languageRules
        self.styleSection = styleSection
        self.spellingDefault = spellingDefault
    }

    /// Convenience for the two-language call sites that predate Burmese.
    public init(coreTemplate: String, englishRules: String, chineseRules: String) {
        self.init(
            coreTemplate: coreTemplate,
            languageRules: [.english: englishRules, .chinese: chineseRules]
        )
    }

    /// The full system prompt for one cleanup call: core template with language
    /// rules, protected terms, profile prompt, and style prompt filled in. The
    /// style slot sits after the profile slot so profile instructions win on
    /// conflict (docs/05 §5).
    public func systemPrompt(for request: CleanupRequest) -> String {
        let rules = (languageRules[request.language] ?? languageRules[.english] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return coreTemplate
            .replacingOccurrences(of: Slot.languageRules, with: rules)
            .replacingOccurrences(of: Slot.spellingRule, with: spellingRuleBlock(for: request))
            .replacingOccurrences(of: Slot.protectedTerms, with: protectedTermsBlock(for: request))
            .replacingOccurrences(of: Slot.profilePrompt, with: block(request.profilePrompt))
            .replacingOccurrences(of: Slot.stylePrompt, with: styleBlock(for: request))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The transcript as the single user message, fenced so the model treats it
    /// as content to transform rather than instructions to follow.
    public func userMessage(for request: CleanupRequest) -> String {
        "<TRANSCRIPT>\n\(request.text)\n</TRANSCRIPT>"
    }

    private func protectedTermsBlock(for request: CleanupRequest) -> String {
        let terms = request.protectedTerms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "(none)" }
        return terms.map { "- \($0)" }.joined(separator: "\n")
    }

    private func block(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(none)" : trimmed
    }

    /// The whole STYLE section, or nothing at all when the user set no style
    /// prompt — which is the common case.
    ///
    /// The section carries a licence: it tells the model that one instruction
    /// may override "keep the speaker's wording" for spelling and word choice.
    /// Shipping that licence unconditionally, above a slot reading "(none)",
    /// gave qwen2.5:3b-instruct a standing permission with nothing concrete to
    /// bind it to, and it generalised: embedded English inside Chinese came
    /// back translated (eval `mix-002`, `mix-007`) and an English dictation
    /// came back in Chinese outright (`en-corr-010`, rejected by the validator
    /// as `language-mismatch`). No style prompt, no licence.
    /// "Keep the speaker's spelling variant" — but only when nothing else has
    /// been asked about spelling.
    ///
    /// A style prompt of "Use British spelling." used to be shipped underneath
    /// a language rule reading "keep the speaker's wording *and spelling
    /// variant*". Those are a flat contradiction about the same operation, and
    /// qwen2.5:3b-instruct resolved it by doing nothing whatsoever: eval
    /// `style-001`, `style-002` and `style-008` came back byte-identical to
    /// their input, missing even the full stop the model adds everywhere else.
    /// The STYLE section's override clause was not enough — an override is a
    /// weaker signal to a small model than never stating the conflict.
    ///
    /// Silence is not the answer either. With no style prompt this rule is the
    /// only thing stopping the model Americanising a British speaker, so it
    /// ships whenever the STYLE section does not. Exactly one of the two is
    /// ever present, and spelling has exactly one instruction at a time.
    /// The slot sits flush against the preceding sentence's full stop, and this
    /// supplies its own leading space, so dropping the rule leaves one space
    /// between sentences rather than two.
    private func spellingRuleBlock(for request: CleanupRequest) -> String {
        let hasStyle = !request.stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasStyle else { return "" }
        let rule = spellingDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        return rule.isEmpty ? "" : " \(rule)"
    }

    private func styleBlock(for request: CleanupRequest) -> String {
        let trimmed = request.stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return styleSection
            .replacingOccurrences(of: Slot.stylePrompt, with: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadPrompt(named name: String) -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "txt", subdirectory: "Prompts"
            ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}
