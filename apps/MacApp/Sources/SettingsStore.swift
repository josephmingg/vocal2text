import Combine
import CoreModels
import Foundation
import PersistenceKit
import SessionKit

/// User-facing settings, persisted to UserDefaults on every change and read
/// back with PRD defaults on launch (docs/01 FR-11.2; cleanup master switch
/// ships OFF per FR-7.1). Also serves as the `SessionConfiguring` seam for
/// `DictationSession`: the protocol's async getters are satisfied by this
/// class's MainActor-isolated properties (callers hop to the main actor).
@MainActor
final class SettingsStore: ObservableObject, SessionConfiguring {

    enum HotkeyChoice: String, CaseIterable {
        case fnKey
        case rightCommand
        case rightOption
    }

    // MARK: - Published settings

    /// Global cleanup master switch — ships OFF and gates stage 3 entirely
    /// (docs/05 §0 precedence).
    @Published var cleanupMasterSwitch: Bool {
        didSet { Self.defaults.set(cleanupMasterSwitch, forKey: Keys.cleanupMasterSwitch) }
    }

    @Published var languageMode: LanguageMode {
        didSet { Self.defaults.set(Self.string(for: languageMode), forKey: Keys.languageMode) }
    }

    @Published var stylePrompt: String {
        didSet { Self.defaults.set(stylePrompt, forKey: Keys.stylePrompt) }
    }

    @Published var hotkeyChoice: HotkeyChoice {
        didSet { Self.defaults.set(hotkeyChoice.rawValue, forKey: Keys.hotkeyChoice) }
    }

    @Published var audioRetentionDays: Int {
        didSet { Self.defaults.set(audioRetentionDays, forKey: Keys.audioRetentionDays) }
    }

    @Published var hudEnabled: Bool {
        didSet { Self.defaults.set(hudEnabled, forKey: Keys.hudEnabled) }
    }

    @Published var soundsEnabled: Bool {
        didSet { Self.defaults.set(soundsEnabled, forKey: Keys.soundsEnabled) }
    }

    /// Per-bundle-ID insertion strategy overrides (docs/03 §3.2: tier choice is
    /// configuration-driven, not failure-driven). Keys are bundle IDs, values
    /// are strategy names owned by the insertion layer.
    @Published var insertionStrategyOverrides: [String: String] {
        didSet {
            Self.defaults.set(insertionStrategyOverrides, forKey: Keys.insertionStrategyOverrides)
        }
    }

    /// Ollama model tag for the v1 cleanup provider (docs/05 §3.2: the user
    /// picks a pulled model; this default matches the Qwen-class guidance).
    @Published var ollamaModel: String {
        didSet { Self.defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
    }

    /// Set by the composition root once the database opens; dictionary lookups
    /// degrade to empty when the store is unavailable.
    var database: DatabaseStore?

    // MARK: - Init

    init() {
        let defaults = Self.defaults
        cleanupMasterSwitch = defaults.object(forKey: Keys.cleanupMasterSwitch) as? Bool ?? false
        languageMode = Self.languageMode(from: defaults.string(forKey: Keys.languageMode))
        stylePrompt = defaults.string(forKey: Keys.stylePrompt) ?? ""
        hotkeyChoice =
            HotkeyChoice(rawValue: defaults.string(forKey: Keys.hotkeyChoice) ?? "") ?? .fnKey
        audioRetentionDays = defaults.object(forKey: Keys.audioRetentionDays) as? Int ?? 30
        hudEnabled = defaults.object(forKey: Keys.hudEnabled) as? Bool ?? true
        soundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        insertionStrategyOverrides =
            defaults.object(forKey: Keys.insertionStrategyOverrides) as? [String: String] ?? [:]
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b-instruct"
    }

    // MARK: - SessionConfiguring

    // The protocol's `cleanupMasterSwitch` requirement is satisfied directly
    // by the stored property above.

    var globalLanguageMode: LanguageMode { languageMode }

    var globalStylePrompt: String { stylePrompt }

    /// Stage-3 budget: 6 s default (docs/05 §3.2); on expiry the session
    /// delivers the stage-2 text unchanged (FR-7.3).
    var cleanupTimeout: Duration { .seconds(6) }

    /// Runs off the main actor: the snapshot of the store handle hops to
    /// MainActor, but the (synchronous, blocking) SQLite read does not.
    nonisolated func enabledDictionaryEntries() async -> [DictionaryEntry] {
        let database = await MainActor.run { self.database }
        guard let database else { return [] }
        let entries = (try? database.dictionaryEntries()) ?? []
        return entries.filter { $0.isEnabled }
    }

    // MARK: - Persistence helpers

    private static let defaults = UserDefaults.standard

    private static func languageMode(from raw: String?) -> LanguageMode {
        // Persisted as "auto" or a Language raw value ("en"/"zh").
        guard let raw, let language = Language(rawValue: raw) else { return .auto }
        return .pinned(language)
    }

    private static func string(for mode: LanguageMode) -> String {
        switch mode {
        case .auto: return "auto"
        case .pinned(let language): return language.rawValue
        }
    }

    private enum Keys {
        static let cleanupMasterSwitch = "settings.cleanupMasterSwitch"
        static let languageMode = "settings.languageMode"
        static let stylePrompt = "settings.stylePrompt"
        static let hotkeyChoice = "settings.hotkeyChoice"
        static let audioRetentionDays = "settings.audioRetentionDays"
        static let hudEnabled = "settings.hudEnabled"
        static let soundsEnabled = "settings.soundsEnabled"
        static let insertionStrategyOverrides = "settings.insertionStrategyOverrides"
        static let ollamaModel = "settings.ollamaModel"
    }
}
