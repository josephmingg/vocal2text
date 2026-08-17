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
    private let englishRules: String
    private let chineseRules: String

    /// Loads the bundled templates. A missing resource degrades to an empty
    /// template rather than crashing; the assembler itself never fails.
    public init() {
        self.init(
            coreTemplate: Self.loadPrompt(named: "system_core"),
            englishRules: Self.loadPrompt(named: "lang_en"),
            chineseRules: Self.loadPrompt(named: "lang_zh")
        )
    }

    /// Injection seam for tests and prompt experiments.
    public init(coreTemplate: String, englishRules: String, chineseRules: String) {
        self.coreTemplate = coreTemplate
        self.englishRules = englishRules
        self.chineseRules = chineseRules
    }

    /// The full system prompt for one cleanup call: core template with language
    /// rules, protected terms, profile prompt, and style prompt filled in. The
    /// style slot sits after the profile slot so profile instructions win on
    /// conflict (docs/05 §5).
    public func systemPrompt(for request: CleanupRequest) -> String {
        let rules = (request.language == .chinese ? chineseRules : englishRules)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return coreTemplate
            .replacingOccurrences(of: Slot.languageRules, with: rules)
            .replacingOccurrences(of: Slot.protectedTerms, with: protectedTermsBlock(for: request))
            .replacingOccurrences(of: Slot.profilePrompt, with: block(request.profilePrompt))
            .replacingOccurrences(of: Slot.stylePrompt, with: block(request.stylePrompt))
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
