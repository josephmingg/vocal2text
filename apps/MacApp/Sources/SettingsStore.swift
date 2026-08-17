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

    /// The push-to-talk binding — a preset or a recorded custom combination
    /// (docs/13). Persisted as JSON so the shape can grow without another
    /// migration.
    @Published var hotkeySpec: HotkeySpec {
        didSet { Self.persist(hotkeySpec) }
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
        let hotkey = Self.loadHotkeySpec(from: defaults)
        hotkeySpec = hotkey.spec
        audioRetentionDays = defaults.object(forKey: Keys.audioRetentionDays) as? Int ?? 30
        hudEnabled = defaults.object(forKey: Keys.hudEnabled) as? Bool ?? true
        soundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        insertionStrategyOverrides =
            defaults.object(forKey: Keys.insertionStrategyOverrides) as? [String: String] ?? [:]
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b-instruct"

        // Settle the legacy hotkey migration on first launch so later reads are
        // plain decodes. `didSet` does not fire from `init`, hence the explicit
        // write; the legacy key is left in place for rollback (docs/13 §3).
        if hotkey.needsPersisting {
            Self.persist(hotkeySpec)
        }
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

    /// Resolution order: the stored spec, then the legacy enum raw string
    /// (migrated once), then the shipping default. A spec that fails to decode
    /// — a rollback from a future format, or a corrupted value — falls through
    /// to the same path rather than leaving the app without a hotkey.
    private static func loadHotkeySpec(
        from defaults: UserDefaults
    ) -> (spec: HotkeySpec, needsPersisting: Bool) {
        if let data = defaults.data(forKey: Keys.hotkeySpec),
            let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
            return (spec: spec, needsPersisting: false)
        }
        if let legacy = defaults.string(forKey: Keys.legacyHotkeyChoice),
            let spec = HotkeySpec.migratingLegacyChoice(legacy) {
            return (spec: spec, needsPersisting: true)
        }
        return (spec: HotkeySpec.default, needsPersisting: false)
    }

    private static func persist(_ spec: HotkeySpec) {
        guard let data = try? JSONEncoder().encode(spec) else { return }
        defaults.set(data, forKey: Keys.hotkeySpec)
    }

    private enum Keys {
        static let cleanupMasterSwitch = "settings.cleanupMasterSwitch"
        static let languageMode = "settings.languageMode"
        static let stylePrompt = "settings.stylePrompt"
        static let hotkeySpec = "settings.hotkeySpec"
        /// Pre-spec key, read once by the migration and never written again.
        /// Left in the domain so downgrading to an older build still works.
        static let legacyHotkeyChoice = "settings.hotkeyChoice"
        static let audioRetentionDays = "settings.audioRetentionDays"
        static let hudEnabled = "settings.hudEnabled"
        static let soundsEnabled = "settings.soundsEnabled"
        static let insertionStrategyOverrides = "settings.insertionStrategyOverrides"
        static let ollamaModel = "settings.ollamaModel"
    }
}
