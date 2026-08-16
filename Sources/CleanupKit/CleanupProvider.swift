import CoreModels
import Foundation

/// Input to stage 3: the stage-2 (dictionary-applied) transcript plus everything
/// needed to assemble the prompt (docs/05 §3.3).
public struct CleanupRequest: Sendable, Hashable {
    public var text: String
    public var language: Language
    /// The active profile's TASK instructions.
    public var profilePrompt: String
    /// Global custom style prompt; empty when unset or profile ignores it.
    public var stylePrompt: String
    /// Dictionary written forms + user-flagged terms (protected, docs/05 §3.4).
    public var protectedTerms: [String]

    public init(
        text: String,
        language: Language,
        profilePrompt: String = "",
        stylePrompt: String = "",
        protectedTerms: [String] = []
    ) {
        self.text = text
        self.language = language
        self.profilePrompt = profilePrompt
        self.stylePrompt = stylePrompt
        self.protectedTerms = protectedTerms
    }
}

public struct CleanupResponse: Sendable, Hashable {
    public var text: String
    public var modelName: String

    public init(text: String, modelName: String) {
        self.text = text
        self.modelName = modelName
    }
}

public enum CleanupError: Error, Sendable, Equatable {
    case providerUnavailable(String)
    case timedOut
    case transport(String)
    case unsupportedLanguage
    case guardrailRefusal
    case malformedOutput(String)
}

/// The pluggable cleanup seam (docs/03 §8.2). Adapters: Apple Foundation Models,
/// HTTP (Ollama + OpenAI-compatible), MLX (post-v1), fakes for tests.
public protocol CleanupProvider: Sendable {
    var id: CleanupProviderID { get }
    /// True when a remote network hop is involved — drives the HUD privacy badge (FR-7.4).
    var leavesDevice: Bool { get }

    func isAvailable() async -> Bool

    /// Fire-and-forget warmup at hotkey press so the model is hot at release.
    func prewarm() async

    func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse
}
