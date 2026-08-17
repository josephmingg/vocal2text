import ASRKit
import ASREngineSherpaOnnx
import ASREngineWhisperKit
import AppKit
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
    /// Live microphone levels, oldest first, one per captured chunk
    /// (~12×/second). Empty outside a take (FR-4.1).
    var levels: [Float] = []
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

    /// Set by `AppDelegate` once the tap is built. Settings needs it to suspend
    /// the global hotkey while the user records a replacement — otherwise
    /// pressing the current key in the recorder starts a real dictation behind
    /// the sheet.
    weak var hotkeyMonitor: HotkeyMonitor?

    /// Bumped on every accepted hotkey down-edge, so a "press it now" tester can
    /// confirm the key works without knowing anything about the event tap.
    @Published private(set) var hotkeyPressCount = 0
    /// While a tester is on screen, hotkey edges only light it up. Pressing your
    /// key to prove it works must not leave a stray recording behind.
    private(set) var isHotkeyTestModeActive = false

    func noteHotkeyPress() {
        hotkeyPressCount &+= 1
    }

    func beginHotkeyTest() {
        isHotkeyTestModeActive = true
    }

    func endHotkeyTest() {
        isHotkeyTestModeActive = false
    }

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
    /// the HUD privacy badge (FR-7.4). Ollama at localhost: false. Computed
    /// from the *current* server URL rather than the one read at launch, so
    /// pointing Vocal at a remote endpoint is reflected on the next dictation
    /// (the settings-take-effect rule behind docs/11 G15).
    private var cleanupLeavesDevice: Bool {
        OpenAICompatibleProvider(
            baseURL: Self.ollamaBaseURL(), model: settings.ollamaModel
        ).leavesDevice
    }

    private var phaseTask: Task<Void, Never>?
    /// Hotkey edges must reach the session actor in order; independent
    /// unstructured Tasks give no FIFO guarantee, so each control call chains
    /// on the previous one.
    private var controlTask: Task<Void, Never>?
    /// Bumped at every take boundary. The first-run model hint is computed by
    /// an async availability check that can outlive a short take; a hint may
    /// only write to the HUD while its own take is still current (docs/11 G16).
    private var hintGeneration = 0
    /// Set when the FR-1.3 low-disk guard finished a take early, so the notice
    /// shows after delivery instead of being overwritten by phase changes.
    private var pendingLowDiskNotice = false
    /// Live profile set (docs/11 G17): persisted, seeded from the built-ins on
    /// first run, and edited by Settings → Profiles. One instance, so the
    /// resolver, the menu-bar pin picker, and the editor agree on UUIDs
    /// (FR-8.3).
    let profileStore: ProfileStore
    /// The cancelled (or crash-interrupted) take still inside its 24 h window,
    /// if any — what the menu bar offers back (FR-1.6, docs/11 G9). Refreshed
    /// at launch, when a take is cancelled, and whenever the menu is opened;
    /// nil while a take is in flight, since that take's own sidecar is on disk
    /// and is not something to hand back.
    @Published private(set) var recoverableTake: RecoveryStore.Candidate? = nil

    init() {
        let settings = SettingsStore()
        let database = AppState.makeDatabase()
        settings.database = database

        let profileStore = ProfileStore(database: database)
        let frontmost = FrontmostContext()
        let relay = ResolutionRelay()

        // Rebuilt per take from the live settings (docs/11 G15) and the take's
        // profile (docs/11 G3) — see `selectCleanup` below. This one is only
        // for the press-time prewarm, which needs *a* provider before the
        // profile is known; a model changed since launch still prewarms the
        // old one, which costs nothing but a wasted keep-alive ping.
        let prewarmProvider = OpenAICompatibleProvider(
            baseURL: AppState.ollamaBaseURL(),
            model: settings.ollamaModel,
            id: .ollama(model: settings.ollamaModel)
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
        let microphone = MicrophoneCapture()
        let dependencies = DictationSession.Dependencies(
            audio: MicrophoneCaptureAdapter(microphone: microphone),
            engine: routedEngine,
            // Built per take, only when the session has already decided stage 3
            // will run (docs/05 §0 gating). Constructing the provider is a few
            // string copies — no network — so this is cheaper than the
            // relaunch it replaces (docs/11 G3/G15).
            selectCleanup: { profile in
                let (baseURL, globalModel) = await MainActor.run {
                    (AppState.ollamaBaseURL(), settings.ollamaModel)
                }
                let model = AppState.cleanupModel(for: profile, globalModel: globalModel)
                let provider = OpenAICompatibleProvider(
                    baseURL: baseURL,
                    model: model,
                    id: .ollama(model: model)
                )
                return DictationSession.CleanupSelection(
                    pipeline: CleanupPipeline(provider: provider),
                    providerID: .ollama(model: model)
                )
            },
            // FR-5.1 (docs/11 G9): "Keep audio" in Settings → History & Privacy
            // decides whether a delivered take leaves a recording behind, and
            // the encode runs off the main actor so it never delays the HUD.
            archiveAudio: { audio, transcriptID in
                let retentionDays = await MainActor.run { settings.audioRetentionDays }
                guard AudioRetentionPolicy.keepsAudio(retentionDays: retentionDays) else {
                    return nil
                }
                guard let directory = AppState.audioDirectory() else { return nil }
                return AudioArchive.write(
                    audio.samples, forTranscript: transcriptID, in: directory
                )
            },
            prewarmCleanup: {
                // Fired at press (docs/03 §2); skip the network touch entirely
                // while the master switch is off.
                guard await settings.cleanupMasterSwitch else { return }
                guard await prewarmProvider.isAvailable() else { return }
                await prewarmProvider.prewarm()
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
                // over routing (FR-8.3, docs/05 §4). Profiles are read from
                // the live store at every press, so a Settings edit applies to
                // the next dictation without relaunching (docs/11 G17); the
                // resolver itself is a throwaway wrapper over a tiny array.
                let (pinned, currentProfiles) = await MainActor.run {
                    (PinState.shared.pinnedProfileID, profileStore.profiles)
                }
                let snapshot = frontmost.snapshot()
                let resolution = ProfileResolver(profiles: currentProfiles).resolve(
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
        self.profileStore = profileStore
        self.hudState = HUDState(
            mode: .hidden,
            partialText: "",
            profileName: "",
            languageLabel: AppState.languageLabel(for: settings.languageMode),
            isRemoteCleanup: false
        )
        self.session = DictationSession(dependencies: dependencies)

        relay.appState = self
        // FR-1.3 (docs/11 G4): when free disk drops below the guard floor
        // mid-take, finish the take through the normal stop path — the audio
        // captured so far is transcribed and delivered, and the user is told
        // why the recording stopped. Routed through the relay because `self`
        // cannot be captured by a concurrent closure from inside init.
        Task {
            await microphone.setLowDiskHandler {
                Task { @MainActor in
                    relay.noteLowDisk()
                }
            }
            // Live waveform (FR-4.1): the HUD showed a synthesized ripple, which
            // looked identical whether the microphone was hearing the user or
            // nothing at all.
            await microphone.setLevelHandler { level in
                Task { @MainActor in
                    relay.noteLevel(level)
                }
            }
        }
        // Enforce the retention window on the recordings already on disk.
        Self.sweepRetainedAudio(retentionDays: settings.audioRetentionDays)
        startPhaseMirror()
        // A take interrupted by a crash or a quit leaves its sidecar behind, so
        // the offer has to survive a relaunch to be worth anything (FR-1.6).
        refreshRecoverableTake()
    }

    /// Appends one captured microphone level, keeping the most recent
    /// `WaveformView.barCount` so the waveform scrolls.
    func appendLevel(_ level: Float) {
        var levels = hudState.levels
        levels.append(level)
        if levels.count > WaveformView.barCount {
            levels.removeFirst(levels.count - WaveformView.barCount)
        }
        hudState.levels = levels
    }

    /// The FR-1.3 mid-take low-disk guard fired: end the take normally and
    /// queue the explanation for when the HUD returns to idle.
    func lowDiskGuardTripped() {
        pendingLowDiskNotice = true
        stopDictation(isLockMode: false)
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
        hudState.levels = []
        hudState.languageLabel = Self.languageLabel(for: settings.languageMode)
        hudState.isRemoteCleanup = cleanupLeavesDevice && settings.cleanupMasterSwitch
        // First-run honesty (FR-2.4): if the routed model isn't resident yet,
        // the release will trigger a download (WhisperKit ~600 MB, Burmese
        // ~790 MB) or a slow load — say so instead of looking frozen. The
        // availability check can outlive a short take, so the hint is tagged
        // with this take's generation and dropped when stale (docs/11 G16).
        let engine = engine
        let burmeseEngine = burmeseEngine
        let mode = settings.languageMode
        hintGeneration += 1
        let generation = hintGeneration
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
                guard let self, self.hintGeneration == generation else { return }
                self.hudState.partialText = hint
            } else {
                let loaded = await engine.isModelLoaded
                guard !loaded else { return }
                guard let self, self.hintGeneration == generation else { return }
                self.hudState.partialText =
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

    // MARK: - Cancelled-take recovery (FR-1.6, docs/11 G9)

    /// Rescans for a recoverable take.
    func refreshRecoverableTake() {
        // A take in flight owns the newest sidecar; offering it back mid-press
        // would hand the user the recording they are still making.
        guard isIdle else {
            recoverableTake = nil
            return
        }
        // This Task inherits main-actor isolation, so `self` never crosses an
        // isolation boundary — only the scan's `Sendable` result does. Doing
        // the reverse (a detached task reaching back to the main actor) is
        // what Swift 6 rejects as "sending 'self' risks causing data races".
        Task { [weak self] in
            let candidate = await Self.scanForRecoverableTake()
            guard let self, self.isIdle else { return }
            self.recoverableTake = candidate
        }
    }

    /// Looks for the newest recoverable sidecar off the main actor: the scan
    /// lists and stats a directory, which is small but is still file I/O, and
    /// it runs while the menu is opening.
    private nonisolated static func scanForRecoverableTake() async -> RecoveryStore.Candidate? {
        await Task.detached(priority: .utility) {
            RecoveryStore.latestRecoverable()
        }.value
    }

    /// Runs the newest cancelled take back through the full pipeline, exactly
    /// as if it had never been cancelled, and delivers it into whatever is
    /// frontmost now.
    ///
    /// The recording is deleted only once the session reports it consumed —
    /// "recover" that loses the audio on a transcription failure would be a
    /// worse offer than not making one.
    func recoverLastCancelledTake() {
        guard let candidate = recoverableTake else { return }
        // Clear the offer immediately: the scan is asynchronous, and a second
        // click before it finishes would run the same audio twice.
        recoverableTake = nil
        // Start handing focus back now, while the samples are read and the
        // model warms — see `yieldFocusToPreviousApp`.
        NSApp.deactivate()
        let url = candidate.url
        enqueueControl { session in
            await AppState.yieldFocusToPreviousApp()
            guard let samples = RecoveryStore.samples(at: url), !samples.isEmpty else {
                // Unreadable or empty: nothing to recover and nothing to keep.
                RecoveryStore.discard(at: url)
                return
            }
            if await session.recover(audio: PCMChunk(samples: samples)) {
                RecoveryStore.discard(at: url)
            }
        }
        // Re-offer the take if the session declined it or transcription failed.
        let pending = controlTask
        Task { [weak self] in
            await pending?.value
            self?.refreshRecoverableTake()
        }
    }

    /// Hands focus back to the app the user was working in, and waits for the
    /// handoff to actually land.
    ///
    /// Every other path into the pipeline starts from a hotkey, and the HUD
    /// panel is non-activating, so the target app never loses focus. Recovery
    /// is the exception: it starts from a menu-bar click, which makes Vocal
    /// frontmost — and delivery pastes into whatever is frontmost. Without
    /// this, a recovered take would be pasted into Vocal itself, which is to
    /// say nowhere.
    ///
    /// `deactivate()` is called at click time, so this usually returns on the
    /// first check; the wait only covers a slow handoff. Bounded at ~600 ms
    /// because it sits in the control chain — a hotkey press arriving now
    /// queues behind it, and a wrong paste target is a smaller harm than a
    /// dictation that takes a visible moment to start.
    private static func yieldFocusToPreviousApp() async {
        let ownBundleID = Bundle.main.bundleIdentifier
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != ownBundleID {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Whether no take is currently being recorded or processed.
    private var isIdle: Bool {
        switch hudState.mode {
        case .listening, .processing: return false
        case .hidden, .error, .notice: return true
        }
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
            hintGeneration += 1
            pendingLowDiskNotice = false
            hudState.mode = .hidden
            hudState.partialText = ""
            hudState.levels = []
            // The take just became recoverable; the offer has to appear without
            // waiting for the next launch. Ordered after `mode` so the idle
            // check inside sees the take as over (FR-1.6).
            refreshRecoverableTake()
        case .idle:
            // The take is over: any first-run hint still in flight is stale
            // (docs/11 G16).
            hintGeneration += 1
            // The session clears lastError at every pressBegan, so any error
            // visible when it returns to idle belongs to this take.
            if pendingLowDiskNotice {
                pendingLowDiskNotice = false
                showNotice("Disk almost full — take saved before recording stopped")
            } else if case .notice = hudState.mode {
                // A delivery notice (clipboard fallback / secure block) is
                // already showing; let its own dismiss timer run.
            } else if let error = await session.lastError {
                hudState.mode = .error(Self.message(for: error))
                scheduleErrorDismiss()
            } else {
                hudState.mode = .hidden
            }
            hudState.partialText = ""
            hudState.levels = []
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

    /// The Ollama model a take runs cleanup on: the profile's override when it
    /// names one, else the global Settings → Cleanup model (docs/11 G3).
    ///
    /// Only `.ollama` overrides are honored because Ollama is the only
    /// provider v1 carries configuration for — a profile asking for an
    /// OpenAI-compatible endpoint has no URL or key to reach it with, so it
    /// falls back to the global model rather than failing every take.
    nonisolated static func cleanupModel(for profile: Profile, globalModel: String) -> String {
        guard case .ollama(let model)? = profile.providerOverride else { return globalModel }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? globalModel : trimmed
    }

    /// Where retained take audio lives: `Application Support/Vocal/audio`,
    /// beside the database that points at it (docs/11 G9).
    nonisolated static func audioDirectory() -> URL? {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return appSupport
            .appendingPathComponent("Vocal", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
    }

    /// Applies the retention window at launch. The setting is a promise about
    /// what is on disk, not merely about what gets written — lowering it must
    /// remove what the old window kept.
    private static func sweepRetainedAudio(retentionDays: Int) {
        guard let directory = audioDirectory() else { return }
        Task.detached(priority: .utility) {
            let removed = AudioArchive.sweep(directory: directory, retentionDays: retentionDays)
            if removed > 0 {
                print("Vocal: removed \(removed) expired audio recording(s)")
            }
        }
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
        case .audioUnreadable(let detail):
            // The capture layer refuses to start below the FR-1.3 disk floor;
            // the session wraps that in audioUnreadable, so the reason is only
            // recoverable from the detail string (docs/11 G4).
            if detail.contains("insufficientDiskSpace") {
                return "Disk almost full — free up space to record"
            }
            return "Could not capture microphone audio"
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

    func noteLowDisk() {
        appState?.lowDiskGuardTripped()
    }

    func noteLevel(_ level: Float) {
        appState?.appendLevel(level)
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
        var record = record
        if record.targetAppName == nil, let bundleID = record.targetAppBundleID {
            // FR-5.1 (docs/11 G8): history should say "Slack", not a bundle
            // ID. Resolved at save time — the target app is still running
            // moments after delivery; a lookup miss just keeps HistoryView's
            // bundle-ID fallback.
            record.targetAppName = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first?.localizedName
            }
        }
        try database.save(record)
    }
}
