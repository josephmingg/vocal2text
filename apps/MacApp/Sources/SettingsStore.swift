import ASREngineWhisperKit
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

    /// Purely cosmetic HUD skin; never touches the dictation path.
    @Published var hudStyle: HUDStyle {
        didSet { Self.defaults.set(hudStyle.rawValue, forKey: Keys.hudStyle) }
    }

    @Published var soundsEnabled: Bool {
        didSet { Self.defaults.set(soundsEnabled, forKey: Keys.soundsEnabled) }
    }

    /// FR-11.4 opt-in: show a per-take latency breakdown toast after delivery.
    @Published var showTimingsToast: Bool {
        didSet { Self.defaults.set(showTimingsToast, forKey: Keys.showTimingsToast) }
    }

    /// FR-1.3 hands-free cap, configurable (docs/15 step 33): a forgotten
    /// locked take auto-stops after this many minutes instead of recording
    /// until the disk fills.
    @Published var lockCapMinutes: Int {
        didSet { Self.defaults.set(lockCapMinutes, forKey: Keys.lockCapMinutes) }
    }

    /// Hands-free auto-stop (the docs/15 step 22 follow-up): a locked take
    /// ends on its own after this many seconds of trailing silence. 0 = off
    /// (ships off, like every behavior-changing feature here).
    @Published var autoStopSilenceSeconds: Int {
        didSet { Self.defaults.set(autoStopSilenceSeconds, forKey: Keys.autoStopSilenceSeconds) }
    }

    /// docs/15 step 13's optional other half: unload the ASR model after this
    /// many idle minutes (0 = keep resident, the default — the whole point of
    /// preload is that the day's first dictation matches the tenth, so this
    /// exists only for memory-constrained Macs).
    @Published var idleUnloadMinutes: Int {
        didSet { Self.defaults.set(idleUnloadMinutes, forKey: Keys.idleUnloadMinutes) }
    }

    /// docs/15 step 36 remainder: capture from this device's stable hardware
    /// UID instead of the system default input. Empty = follow the default.
    @Published var inputDeviceUID: String {
        didSet { Self.defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
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

    /// WhisperKit model identifier for the primary EN/ZH engine (docs/15
    /// step 15 — Settings → Models kills the hardcoded name). Applies on the
    /// engine's next load; the composition root observes changes.
    @Published var whisperKitModel: String {
        didSet { Self.defaults.set(whisperKitModel, forKey: Keys.whisperKitModel) }
    }

    /// docs/15 step 14: route pinned-English dictations to Parakeet TDT v2
    /// on the Neural Engine. Ships OFF until the owner benchmarks it with
    /// vocal-bench; the routing seam reads the defaults key directly (see
    /// `parakeetEnglishDefaultsKey`) so a flip applies to the next dictation.
    @Published var parakeetEnglishEnabled: Bool {
        didSet { Self.defaults.set(parakeetEnglishEnabled, forKey: Keys.parakeetEnglish) }
    }

    /// The raw defaults key behind `parakeetEnglishEnabled`, read by the
    /// engine router off the main actor (UserDefaults is thread-safe).
    nonisolated static var parakeetEnglishDefaultsKey: String { Keys.parakeetEnglish }

    /// Set by the composition root once the database opens; dictionary lookups
    /// degrade to empty when the store is unavailable.
    var database: DatabaseStore?

    /// Whether the ASR model has ever loaded successfully on this machine
    /// (docs/15 step 13). Gates the silent launch preload: a background warm
    /// must never turn into a surprise ~600 MB download on a fresh install —
    /// onboarding owns that first, explicit download.
    var modelWarmedOnce: Bool {
        get { Self.defaults.bool(forKey: Keys.modelWarmedOnce) }
        set { Self.defaults.set(newValue, forKey: Keys.modelWarmedOnce) }
    }

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
        hudStyle = defaults.string(forKey: Keys.hudStyle).flatMap(HUDStyle.init(rawValue:)) ?? .jarvis
        soundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        showTimingsToast = defaults.object(forKey: Keys.showTimingsToast) as? Bool ?? false
        lockCapMinutes = defaults.object(forKey: Keys.lockCapMinutes) as? Int ?? 15
        autoStopSilenceSeconds =
            defaults.object(forKey: Keys.autoStopSilenceSeconds) as? Int ?? 0
        idleUnloadMinutes = defaults.object(forKey: Keys.idleUnloadMinutes) as? Int ?? 0
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID) ?? ""
        insertionStrategyOverrides =
            defaults.object(forKey: Keys.insertionStrategyOverrides) as? [String: String] ?? [:]
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b-instruct"
        whisperKitModel =
            defaults.string(forKey: Keys.whisperKitModel) ?? WhisperKitEngine.defaultModelName
        parakeetEnglishEnabled = defaults.object(forKey: Keys.parakeetEnglish) as? Bool ?? false

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
    /// MainActor, but the entry read does not. The store serves it from its
    /// in-memory cache after the first take (docs/15 step 48), so this is a
    /// SQLite read only immediately after launch or a dictionary edit.
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
            let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data),
            // The recorder cannot produce an unbindable spec, but a hand-edited
            // defaults value or a rollback from a future format can — and an
            // Escape or Caps Lock binding would break cancelling and never fire.
            HotkeySpec.validationError(for: spec.kind) == nil {
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
        static let hudStyle = "settings.hudStyle"
        static let soundsEnabled = "settings.soundsEnabled"
        static let showTimingsToast = "settings.showTimingsToast"
        static let lockCapMinutes = "settings.lockCapMinutes"
        static let autoStopSilenceSeconds = "settings.autoStopSilenceSeconds"
        static let idleUnloadMinutes = "settings.idleUnloadMinutes"
        static let inputDeviceUID = "settings.inputDeviceUID"
        static let insertionStrategyOverrides = "settings.insertionStrategyOverrides"
        static let ollamaModel = "settings.ollamaModel"
        static let whisperKitModel = "settings.whisperKitModel"
        static let parakeetEnglish = "settings.parakeetEnglish"
        static let modelWarmedOnce = "settings.modelWarmedOnce"
    }
}
