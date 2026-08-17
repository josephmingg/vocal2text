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
    }

    private let coreTemplate: String
    private let languageRules: [Language: String]
    /// Wrapper for a non-empty style prompt; see `styleBlock(for:)`.
    private let styleSection: String

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
            styleSection: Self.loadPrompt(named: "style_section")
        )
    }

    /// Injection seam for tests and prompt experiments. `styleSection` defaults
    /// to a bare passthrough so an injected core template behaves verbatim.
    public init(
        coreTemplate: String,
        languageRules: [Language: String],
        styleSection: String = "{STYLE_PROMPT}"
    ) {
        self.coreTemplate = coreTemplate
        self.languageRules = languageRules
        self.styleSection = styleSection
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
