import ASRKit
import ASREngineSherpaOnnx
import ASREngineWhisperKit
import AudioPipeline
import CleanupKit
import Combine
import CoreModels
import Foundation
import PersistenceKit
import ProfileKit
import SessionKit

/// What the HUD (and menu-bar icon) renders. Owned by AppState; views only read it.
struct HUDState: Equatable {
    enum Mode: Equatable {
        case hidden
        case listening(startedAt: Date)
        case processing
        case error(String)
        /// Non-error transient message (clipboard fallback, secure-field block).
        case notice(String)
    }

    var mode: Mode
    var partialText: String
    var profileName: String
    var languageLabel: String
    var isRemoteCleanup: Bool
}

/// The macOS composition root: builds every engine seam once, owns the one
/// `DictationSession`, and mirrors its phases into `hudState` for the UI.
/// Views and the hotkey monitor call the three dictation methods; they never
/// talk to the session directly (docs/03 §2).
@MainActor
final class AppState: ObservableObject {

    let session: DictationSession
    let settings: SettingsStore
    let database: DatabaseStore?
    @Published var hudState: HUDState

    /// Retained so onboarding's "Warm up now" can trigger the guided model
    /// download/load explicitly (FR-2.4).
    private let engine: WhisperKitEngine
    /// Burmese engine (docs/04 §1): pinned မြန်မာ dictations route here via
    /// `routedEngine`; retained for the first-run download HUD hint.
    private let burmeseEngine: SherpaOnnxEngine
    /// What the session actually transcribes through: primary + per-language
    /// overrides. Warm-up goes through this too, so it prepares whichever
    /// engine the current language mode routes to.
    private let routedEngine: LanguageRoutingEngine

    /// Whether the configured cleanup provider sends text off-device — drives
    /// the HUD privacy badge (FR-7.4). Ollama at localhost: false.
    private let cleanupLeavesDevice: Bool

    private var phaseTask: Task<Void, Never>?
    /// Hotkey edges must reach the session actor in order; independent
    /// unstructured Tasks give no FIFO guarantee, so each control call chains
    /// on the previous one.
    private var controlTask: Task<Void, Never>?
    /// Built-in (or stored) profiles, built once so the resolver and the
    /// menu-bar pin picker agree on UUIDs (FR-8.3).
    let profiles: [Profile]

    init() {
        let settings = SettingsStore()
        let database = AppState.makeDatabase()
        settings.database = database

        let profiles = AppState.loadProfiles(database: database)
        let resolver = ProfileResolver(profiles: profiles)
        let frontmost = FrontmostContext()
        let relay = ResolutionRelay()

        let model = settings.ollamaModel
        let provider = OpenAICompatibleProvider(
            baseURL: AppState.ollamaBaseURL(),
            model: model,
            id: .ollama(model: model)
        )

        let engine = WhisperKitEngine()
        // Pinned မြန်မာ routes to the Burmese engine (Omnilingual CTC 1B,
        // 10.78% CER on FLEURS my_mm — docs/11 G13); everything else,
        // including auto mode, stays on WhisperKit. The routing contract is
        // documented on LanguageRoutingEngine.
        let burmeseEngine = SherpaOnnxEngine(variant: .omnilingual1B)
        let routedEngine = LanguageRoutingEngine(
            primary: engine,
            overrides: [.burmese: burmeseEngine]
        )
        let dependencies = DictationSession.Dependencies(
            audio: MicrophoneCaptureAdapter(microphone: MicrophoneCapture()),
            engine: routedEngine,
            // The pipeline is wired unconditionally; the session's own
            // precedence gating (docs/05 §0: master switch → per-profile
            // opt-in) decides per dictation whether stage 3 runs, and an
            // unreachable Ollama falls back to stage-2 text (FR-7.3).
            cleanup: CleanupPipeline(provider: provider),
            cleanupProviderID: .ollama(model: model),
            prewarmCleanup: {
                // Fired at press (docs/03 §2); skip the network touch entirely
                // while the master switch is off.
                guard await settings.cleanupMasterSwitch else { return }
                guard await provider.isAvailable() else { return }
                await provider.prewarm()
            },
            deliverer: MacTextDelivering(
                deliverer: TextDeliverer(
                    strategies: InsertionStrategyTable(
                        overrides: settings.insertionStrategyOverrides
                    ),
                    clipboard: ClipboardManager()
                ),
                onOutcome: { outcome in relay.noteDelivery(outcome) }
            ),
            store: DatabaseTranscriptStore(database: database),
            config: settings,
            profileResolution: {
                // Snapshot the frontmost context at press; the profile stays
                // pinned for the whole take (FR-3.6). The menu-bar pin wins
                // over routing (FR-8.3, docs/05 §4).
                let pinned = await MainActor.run { PinState.shared.pinnedProfileID }
                let snapshot = frontmost.snapshot()
                let resolution = resolver.resolve(
                    frontmostBundleID: snapshot.bundleID,
                    tabHostname: snapshot.tabHostname,
                    manualPinProfileID: pinned
                )
                await relay.noteResolved(profileName: resolution.profile.name)
                return (
                    profile: resolution.profile,
                    routeKind: resolution.routeKind,
                    pressTimeBundleID: snapshot.bundleID
                )
            }
        )

        self.settings = settings
        self.database = database
        self.engine = engine
        self.burmeseEngine = burmeseEngine
        self.routedEngine = routedEngine
        self.profiles = profiles
        self.cleanupLeavesDevice = provider.leavesDevice
        self.hudState = HUDState(
            mode: .hidden,
            partialText: "",
            profileName: "",
            languageLabel: AppState.languageLabel(for: settings.languageMode),
            isRemoteCleanup: false
        )
        self.session = DictationSession(dependencies: dependencies)

        relay.appState = self
        startPhaseMirror()
    }

    /// Loads (downloading on first run) the ASR model so the first dictation
    /// is fast. Called from onboarding's "Warm up now" (FR-2.4). Goes through
    /// the router: pinned မြန်မာ warms the Burmese engine instead.
    func warmUp() async throws {
        try await routedEngine.prepare(languageMode: settings.languageMode)
    }

    // MARK: - Dictation controls

    func startDictation() {
        hudState.partialText = ""
        hudState.languageLabel = Self.languageLabel(for: settings.languageMode)
        hudState.isRemoteCleanup = cleanupLeavesDevice && settings.cleanupMasterSwitch
        // First-run honesty (FR-2.4): if the routed model isn't resident yet,
        // the release will trigger a download (WhisperKit ~600 MB, Burmese
        // ~790 MB) or a slow load — say so instead of looking frozen.
        let engine = engine
        let burmeseEngine = burmeseEngine
        let mode = settings.languageMode
        Task { [weak self] in
            if mode == .pinned(.burmese) {
                let loaded = await burmeseEngine.isModelLoaded
                guard !loaded else { return }
                let availability = await burmeseEngine.availability(for: .burmese)
                let hint: String
                if case .needsDownload = availability {
                    hint =
                        "First Burmese run: downloading the မြန်မာ speech model (~790 MB) — this can take a while. Later dictations skip it."
                } else {
                    hint = "Loading the မြန်မာ speech model — the first dictation after launch takes longer."
                }
                self?.hudState.partialText = hint
            } else {
                let loaded = await engine.isModelLoaded
                guard !loaded else { return }
                self?.hudState.partialText =
                    "First run: downloading the speech model (~600 MB) and preparing it — this can take several minutes. Later dictations are instant."
            }
        }
        enqueueControl { session in await session.pressBegan() }
    }

    func stopDictation(isLockMode: Bool) {
        DeliverySounds.playStop(enabled: settings.soundsEnabled)
        enqueueControl { session in await session.pressEnded(isLockMode: isLockMode) }
    }

    func cancelDictation() {
        enqueueControl { session in await session.cancel() }
    }

    /// Chains session control calls so hotkey edges arrive in press order —
    /// independently spawned Tasks would race a release past its press.
    private func enqueueControl(
        _ operation: @escaping @Sendable (DictationSession) async -> Void
    ) {
        let session = session
        let previous = controlTask
        controlTask = Task {
            await previous?.value
            await operation(session)
        }
    }

    // MARK: - Phase mirroring

    private func startPhaseMirror() {
        phaseTask = Task { [weak self] in
            guard let session = self?.session else { return }
            let phases = await session.phases
            for await phase in phases {
                guard let self else { return }
                await self.handle(phase: phase, session: session)
            }
        }
    }

    private func handle(phase: DictationSession.Phase, session: DictationSession) async {
        switch phase {
        case .arming:
            hudState.mode = .listening(startedAt: Date())
        case .recording:
            hudState.mode = .listening(startedAt: Date())
            DeliverySounds.playStart(enabled: settings.soundsEnabled)
        case .transcribing, .cleaning, .delivering:
            hudState.mode = .processing
        case .cancelled:
            hudState.mode = .hidden
            hudState.partialText = ""
        case .idle:
            // The session clears lastError at every pressBegan, so any error
            // visible when it returns to idle belongs to this take.
            if case .notice = hudState.mode {
                // A delivery notice (clipboard fallback / secure block) is
                // already showing; let its own dismiss timer run.
            } else if let error = await session.lastError {
                hudState.mode = .error(Self.message(for: error))
                scheduleErrorDismiss()
            } else {
                hudState.mode = .hidden
            }
            hudState.partialText = ""
        }
    }

    /// Delivery outcomes the user must hear about (FR-3.2/3.4/3.6) — invoked
    /// by the deliverer seam before the session finishes the take.
    func showDelivery(outcome: DeliveryOutcome) {
        switch outcome {
        case .inserted:
            break
        case .copiedToClipboard:
            showNotice("Copied — press ⌘V to paste")
        case .blockedSecureField(let culprit):
            let suffix = culprit.map { " (\($0))" } ?? ""
            showNotice("Secure field\(suffix) — nothing inserted or saved")
        }
    }

    /// Shows a transient HUD notice that dismisses itself.
    ///
    /// Notices must always be posted through here: `handle(phase:)` leaves an
    /// existing notice alone on the way back to `.idle` precisely because a
    /// dismiss timer is expected to be running for it. A notice assigned
    /// straight to `hudState.mode` therefore sticks on screen indefinitely.
    func showNotice(_ message: String) {
        hudState.mode = .notice(message)
        scheduleErrorDismiss()
    }

    private func scheduleErrorDismiss() {
        let shown = hudState.mode
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if self.hudState.mode == shown {
                self.hudState.mode = .hidden
            }
        }
    }

    // MARK: - Composition helpers

    private static func makeDatabase() -> DatabaseStore? {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            print("Vocal: Application Support directory unavailable — history disabled")
            return nil
        }
        let directory = appSupport.appendingPathComponent("Vocal", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("vocal.sqlite").path
            return try DatabaseStore(path: path)
        } catch {
            print("Vocal: failed to open database — history disabled: \(error)")
            return nil
        }
    }

    private static func loadProfiles(database: DatabaseStore?) -> [Profile] {
        if let database {
            do {
                let stored = try database.profiles()
                if !stored.isEmpty { return stored }
            } catch {
                print("Vocal: failed to load profiles — using built-ins: \(error)")
            }
        }
        return BuiltInProfiles.makeAll()
    }

    /// Ollama server root; its OpenAI-compatible surface lives under /v1
    /// (docs/05 §3.2). The Settings Cleanup pane persists a custom URL under
    /// "ollamaBaseURL"; localhost is the default.
    private static func ollamaBaseURL() -> URL {
        if let custom = UserDefaults.standard.string(forKey: "ollamaBaseURL"),
           let url = URL(string: custom), url.host() != nil {
            return url
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 11_434
        // scheme + host + port always compose a URL; the fallback only keeps
        // this accessor total without a force unwrap.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    private static func languageLabel(for mode: LanguageMode) -> String {
        switch mode {
        case .auto: return "Auto"
        case .pinned(let language): return language.shortLabel
        }
    }

    private static func message(for error: TranscriptionError) -> String {
        switch error {
        case .modelNotInstalled: return "Speech model not installed"
        case .engineUnavailable: return "Transcription engine unavailable"
        case .audioUnreadable: return "Could not capture microphone audio"
        case .cancelled: return "Dictation cancelled"
        }
    }
}

// MARK: - Seam adapters

/// Lets the press-time profile resolution (a Sendable closure that cannot
/// capture the not-yet-initialized AppState) report the resolved profile name
/// back to the HUD.
@MainActor
private final class ResolutionRelay {
    weak var appState: AppState?

    func noteResolved(profileName: String) {
        appState?.hudState.profileName = profileName
    }

    func noteDelivery(_ outcome: DeliveryOutcome) {
        appState?.showDelivery(outcome: outcome)
    }
}

/// `MicrophoneSession` mirrors SessionKit's `CaptureSession` field-for-field;
/// AudioPipeline deliberately does not depend on SessionKit, so the app target
/// bridges the two (comment in AudioPipeline.swift).
private struct MicrophoneCaptureAdapter: AudioCapturing {
    let microphone: MicrophoneCapture

    func start() async throws -> CaptureSession {
        let session = try await microphone.start()
        return CaptureSession(
            chunks: session.chunks,
            finish: session.finish,
            cancel: session.cancel
        )
    }
}

/// Hops delivery onto the main actor, where `TextDeliverer` (AppKit pasteboard
/// + CGEvent synthesis) must run.
private struct MacTextDelivering: TextDelivering {
    let deliverer: TextDeliverer
    let onOutcome: @MainActor (DeliveryOutcome) -> Void

    func deliver(_ text: String, context: DeliveryContext) async -> DeliveryOutcome {
        let outcome = await deliverer.deliver(text, context: context)
        await onOutcome(outcome)
        return outcome
    }
}

/// Keeps the synchronous GRDB write off the main actor and the session actor.
/// A missing database degrades to a no-op save; the delivered text already
/// landed (DictationSession treats save failures as non-fatal by design).
private actor DatabaseTranscriptStore: TranscriptStoring {
    private let database: DatabaseStore?

    init(database: DatabaseStore?) {
        self.database = database
    }

    func save(_ record: TranscriptRecord) async throws {
        guard let database else { return }
        try database.save(record)
    }
}
