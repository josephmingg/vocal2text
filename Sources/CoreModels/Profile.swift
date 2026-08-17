import Foundation

/// How a profile is matched to the current dictation context (docs/05 §4).
public enum Route: Codable, Sendable, Hashable {
    /// Matches a frontmost app bundle identifier, e.g. "com.tinyspeck.slackmacgap".
    case app(bundleID: String)
    /// Matches a browser tab hostname (suffix match on registrable domain +
    /// subdomains), e.g. "mail.google.com". The hostname is used in memory only
    /// and never persisted (FR-8.4).
    case website(hostname: String)
    /// Exactly one profile owns the default route.
    case defaultRoute
}

/// Formatting behavior gates for pipeline stages 1 and 4 (docs/05 §0).
/// Verbatim-style profiles (Terminal) bypass punctuation/capitalization/spacing;
/// artifact stripping and dictionary overrides always run.
public struct FormattingOptions: Codable, Sendable, Hashable {
    /// Allow stage 1/4 to add or repair punctuation and capitalization.
    public var autoPunctuation: Bool
    /// Allow stage 4 smart spacing relative to surrounding text.
    public var smartSpacing: Bool
    /// Allow paragraph/bullet shaping by the cleanup LLM.
    public var structureAllowed: Bool
    /// Chinese: enforce full-width punctuation in stage 4.
    public var enforceFullWidthZhPunctuation: Bool
    /// Chinese: insert thin spacing between Han and Latin/digit runs.
    public var panguSpacing: Bool

    public init(
        autoPunctuation: Bool = true,
        smartSpacing: Bool = true,
        structureAllowed: Bool = false,
        enforceFullWidthZhPunctuation: Bool = true,
        panguSpacing: Bool = false
    ) {
        self.autoPunctuation = autoPunctuation
        self.smartSpacing = smartSpacing
        self.structureAllowed = structureAllowed
        self.enforceFullWidthZhPunctuation = enforceFullWidthZhPunctuation
        self.panguSpacing = panguSpacing
    }

    /// Verbatim mode: nothing is reshaped; only artifacts + dictionary apply.
    public static let verbatim = FormattingOptions(
        autoPunctuation: false,
        smartSpacing: false,
        structureAllowed: false,
        enforceFullWidthZhPunctuation: false,
        panguSpacing: false
    )
}

/// A cleanup profile: its own AI prompt plus routing rules (requirement F8).
public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var icon: String
    /// Per-profile cleanup opt-in. Only effective when the global cleanup master
    /// switch is ON (docs/05 §0 precedence).
    public var cleanupEnabled: Bool
    /// The profile's AI instructions, injected as the prompt's TASK slot.
    public var promptText: String
    /// Overrides the global default cleanup provider when set.
    public var providerOverride: CleanupProviderID?
    public var formatting: FormattingOptions
    /// Ignore the global custom style prompt (e.g. Terminal).
    public var ignoresGlobalStyle: Bool
    public var routes: [Route]
    /// Higher wins when multiple profiles match the same context.
    public var priority: Int
    /// Pin the language mode for this profile (nil = follow global setting).
    public var languageOverride: LanguageMode?

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "person.wave.2",
        cleanupEnabled: Bool = false,
        promptText: String = "",
        providerOverride: CleanupProviderID? = nil,
        formatting: FormattingOptions = .init(),
        ignoresGlobalStyle: Bool = false,
        routes: [Route] = [],
        priority: Int = 0,
        languageOverride: LanguageMode? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.cleanupEnabled = cleanupEnabled
        self.promptText = promptText
        self.providerOverride = providerOverride
        self.formatting = formatting
        self.ignoresGlobalStyle = ignoresGlobalStyle
        self.routes = routes
        self.priority = priority
        self.languageOverride = languageOverride
    }
}

/// Identifies a cleanup provider configuration (docs/05 §3.2).
public enum CleanupProviderID: Codable, Sendable, Hashable {
    /// Apple Foundation Models — zero-install on OS 26 Apple-Intelligence hardware.
    case appleFoundationModels
    /// Downloadable local model served in-process (MLX). Post-v1 wiring; the seam exists now.
    case localMLX(modelID: String)
    /// Ollama at localhost (macOS).
    case ollama(model: String)
    /// Any OpenAI-compatible endpoint. `remoteLabel` shows in the privacy badge.
    case openAICompatible(name: String)
}
