import ASRKit
import ASREngineParakeet
import ASREngineSherpaOnnx
import ASREngineWhisperKit
import AVFoundation
import AppKit
import AudioPipeline
import CleanupKit
import Combine
import CoreModels
import Foundation
import PersistenceKit
import ProfileKit
import SessionKit
import TextPipeline
import UniformTypeIdentifiers

/// What the HUD (and menu-bar icon) renders. Owned by AppState; views only read it.
struct HUDState: Equatable {
    enum Mode: Equatable {
        case hidden
        case listening(startedAt: Date)
        case processing(stage: ProcessingStage)
        case error(String)
        /// Non-error transient message (clipboard fallback, secure-field block).
        case notice(String)
    }

    /// Which pipeline stage the processing HUD is in (docs/15 step 23): the
    /// delivering flash makes the paste moment visible instead of the whole
    /// post-release stretch reading as one undifferentiated spinner.
    enum ProcessingStage: Equatable {
        case transcribing
        case cleaning
        case delivering
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
    /// Whether the global hotkey tap is armed (docs/15 W9): false when
    /// Accessibility is missing or the tap failed to start — the menu bar
    /// shows a warning instead of the app looking alive with a dead hotkey.
    @Published var hotkeyArmed = true

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
    /// The docs/15 step 16 VAD; retained so the launch preload can fetch its
    /// (~0.6 MB) model before the first take needs it.
    private let speechDetector: SileroVoiceActivityDetector
    /// Parakeet fast path (docs/15 step 14); retained for the first-run
    /// download hint when the pinned-English toggle is on.
    private let parakeetEngine: ParakeetEngine

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
    private var settingsSinks: Set<AnyCancellable> = []
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
    /// Set when a mid-take audio-device change ended the take (docs/15
    /// step 36), so the explanation lands once the HUD settles.
    private var pendingDeviceChangeNotice = false
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

        // The primary model is a setting now (docs/15 step 15), not a
        // hardcoded name; Settings → Models switches it live.
        let engine = WhisperKitEngine(modelName: settings.whisperKitModel)
        // Pinned မြန်မာ routes to the Burmese engine (Omnilingual CTC 1B,
        // 10.78% CER on FLEURS my_mm — docs/11 G13); everything else,
        // including auto mode, stays on WhisperKit. The routing contract is
        // documented on LanguageRoutingEngine.
        let burmeseEngine = SherpaOnnxEngine(variant: .omnilingual1B)
        // docs/15 step 14: pinned-English can route to Parakeet TDT v2 on
        // the Neural Engine (~100× real time). Behind a live toggle read
        // straight from defaults so a Settings flip applies to the next
        // dictation; auto mode and pinned ZH stay on WhisperKit, so
        // code-switching accuracy is untouched.
        let parakeetEngine = ParakeetEngine()
        let englishRoute = SwitchedEngine(
            isOn: { UserDefaults.standard.bool(forKey: SettingsStore.parakeetEnglishDefaultsKey) },
            on: parakeetEngine,
            off: engine
        )
        let routedEngine = LanguageRoutingEngine(
            primary: engine,
            overrides: [.burmese: burmeseEngine, .english: englishRoute]
        )
        let microphone = MicrophoneCapture()
        // docs/15 step 16: Silero VAD gates and trims each finished take —
        // silence delivers nothing instead of hallucinated text, and the
        // engine only decodes the speech envelope.
        let speechDetector = SileroVoiceActivityDetector()
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
            analyzeSpeech: { audio in
                await speechDetector.analyze(audio)
            },
            // docs/15 step 29: the AX caret read that makes smart spacing
            // format against what is really before the insertion point.
            readPrecedingContext: {
                await MainActor.run { AXInserter.precedingContext() }
            },
            // docs/15 step 35: a failed transcription leaves its audio in the
            // ordinary 24-hour recovery window — the same menu offer as a
            // cancelled take, so zero silent losses.
            preserveFailedAudio: { audio in
                RecoveryStore.preserve(samples: audio.samples)
            },
            // Streaming preview (docs/15 step 22), display-only per FR-4.1.
            // Gated to the Parakeet route on purpose: its decode is fast
            // enough that a release landing mid-preview waits a fraction of a
            // second on the engine actor at worst, where Whisper's
            // multi-second decode would hold the final pass hostage — the
            // exact latency Phase 2 removed.
            previewTranscribe: { audio in
                let eligible = await MainActor.run {
                    settings.parakeetEnglishEnabled
                        && settings.languageMode == .pinned(.english)
                }
                guard eligible else { return nil }
                // Never trigger the ~600 MB download from a preview tick; the
                // preload and the take's own path own that moment.
                guard await parakeetEngine.isModelLoaded else { return nil }
                return try? await parakeetEngine.transcribe(
                    audio, languageMode: .pinned(.english), dictionaryTerms: []
                ).text
            },
            onPartial: { text in
                Task { @MainActor in
                    relay.notePartial(text)
                }
            },
            prewarmCleanup: {
                // Fired at press (docs/03 §2); skip the network touch entirely
                // while the master switch is off. No availability preflight:
                // prewarm already swallows every error, so the probe was a
                // second HTTP round-trip for nothing (docs/15 step 19). The
                // provider is rebuilt here (string copies, no network) so a
                // model or server changed since launch prewarms the right one.
                let snapshot = await MainActor.run {
                    settings.cleanupMasterSwitch
                        ? (
                            baseURL: AppState.ollamaBaseURL(),
                            model: settings.ollamaModel,
                            language: settings.languageMode.pinnedLanguage ?? .english,
                            stylePrompt: settings.stylePrompt
                        )
                        : nil
                }
                guard let snapshot else { return }
                let provider = OpenAICompatibleProvider(
                    baseURL: snapshot.baseURL,
                    model: snapshot.model,
                    id: .ollama(model: snapshot.model)
                )
                // Shaped like the take's real request so the server's prompt
                // cache holds the reusable system-prompt prefix, not a "hi".
                let terms = await settings.enabledDictionaryEntries().map(\.written)
                await provider.prewarm(
                    for: CleanupRequest(
                        text: "",
                        language: snapshot.language,
                        stylePrompt: snapshot.stylePrompt,
                        protectedTerms: terms
                    )
                )
            },
            deliverer: MacTextDelivering(
                deliverer: TextDeliverer(
                    strategies: InsertionStrategyTable(
                        overrides: settings.insertionStrategyOverrides
                    ),
                    clipboard: ClipboardManager()
                ),
                onOutcome: { outcome, text in relay.noteDelivery(outcome, text: text) }
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
                let snapshot = await frontmost.snapshot()
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
        self.speechDetector = speechDetector
        self.parakeetEngine = parakeetEngine
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
            // docs/15 step 36: an AirPods connect or input switch mid-take
            // reconfigures the engine under the tap; end the take through the
            // normal stop path so the audio captured so far is delivered.
            await microphone.setConfigurationChangeHandler {
                Task { @MainActor in
                    relay.noteDeviceChange()
                }
            }
            // Build and prepare the first take's audio engine now (docs/15
            // step 50), so the first press finds the allocation already paid.
            // Touches no microphone hardware — no permission prompt, no
            // privacy indicator. Ordered after the handlers so a press racing
            // launch never records without its guards installed.
            await microphone.preheat()
        }
        // Enforce the retention window on the recordings already on disk.
        Self.sweepRetainedAudio(retentionDays: settings.audioRetentionDays)
        // A language-mode change can point the router at a different engine;
        // warm it when the choice is made, not inside the next take (docs/15
        // step 13). The new value rides the publisher — @Published emits on
        // willSet, so reading the property here would see the old mode.
        settings.$languageMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.preloadEngineIfWarmedBefore(mode: mode)
            }
            .store(in: &settingsSinks)
        // Turning the Parakeet route on warms it right away (docs/15 step
        // 14) so the first pinned-English dictation after the flip doesn't
        // pay the download inside the take. Gated on modelWarmedOnce like
        // every background load.
        settings.$parakeetEnglishEnabled
            .dropFirst()
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                // Deferred one main-actor turn: @Published emits on willSet,
                // and the router reads the defaults key that didSet writes.
                Task { @MainActor [weak self] in
                    guard let self, self.settings.languageMode == .pinned(.english) else { return }
                    self.preloadEngineIfWarmedBefore()
                }
            }
            .store(in: &settingsSinks)
        // Settings → Models switches the primary model live (docs/15 step
        // 15): drop the resident pipe, then warm the chosen model in the
        // background so the next take doesn't pay the load.
        settings.$whisperKitModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] name in
                guard let self else { return }
                let engine = self.engine
                Task { [weak self] in
                    await engine.setModel(name: name)
                    await MainActor.run { self?.preloadEngineIfWarmedBefore() }
                }
            }
            .store(in: &settingsSinks)
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
        feedAutoStopGate(level)
    }

    // MARK: - Hands-free auto-stop on trailing silence (docs/15 step 22 follow-up)

    private var autoStopGate: TrailingSilenceGate?
    private var autoStopEpoch: ContinuousClock.Instant?
    private var pendingAutoStopNotice = false

    /// AppDelegate reports lock-mode transitions so the gate exists exactly
    /// while a hands-free take runs. Off (0 s) means no gate at all — the
    /// level path stays a plain waveform feed.
    func handsFreeLockChanged(active: Bool) {
        guard active, settings.autoStopSilenceSeconds > 0 else {
            autoStopGate = nil
            autoStopEpoch = nil
            return
        }
        autoStopGate = TrailingSilenceGate(
            holdSeconds: Double(settings.autoStopSilenceSeconds)
        )
        autoStopEpoch = ContinuousClock.now
    }

    private func feedAutoStopGate(_ level: Float) {
        guard let epoch = autoStopEpoch, case .listening = hudState.mode else { return }
        let seconds = Self.seconds(epoch.duration(to: ContinuousClock.now))
        guard autoStopGate?.ingest(level: level, at: seconds) == true else { return }
        autoStopGate = nil
        autoStopEpoch = nil
        pendingAutoStopNotice = true
        // Same forced-stop path as the mid-take guards: lock bookkeeping is
        // cleared and the truthful isLockMode reaches the deliverer.
        stopDictation(isLockMode: endLockModeForForcedStop?() ?? true)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// Streaming-preview line for the HUD's partial row (docs/15 step 22).
    /// Only while a take is visibly live: a preview that raced the take's end
    /// must not resurrect text over an idle or error state.
    func showPreview(_ text: String) {
        switch hudState.mode {
        case .listening, .processing:
            hudState.partialText = text
        case .hidden, .error, .notice:
            break
        }
    }

    /// Set by AppDelegate. A mid-take guard that force-ends a take must ask
    /// it whether hands-free lock was active (so `isLockMode` reaches the
    /// deliverer truthfully and the FR-3.6 wandering-focus guard holds) and
    /// have it clear its lock bookkeeping — otherwise `isLockModeActive`
    /// dangles and swallows the next press, while the cap timer later fires
    /// a bogus notice.
    var endLockModeForForcedStop: (() -> Bool)?

    /// The FR-1.3 mid-take low-disk guard fired: end the take normally and
    /// queue the explanation for when the HUD returns to idle.
    func lowDiskGuardTripped() {
        pendingLowDiskNotice = true
        stopDictation(isLockMode: endLockModeForForcedStop?() ?? false)
    }

    /// docs/15 step 36: the audio device changed under a live take.
    func deviceChangedMidTake() {
        guard case .listening = hudState.mode else { return }
        pendingDeviceChangeNotice = true
        stopDictation(isLockMode: endLockModeForForcedStop?() ?? false)
    }

    // MARK: - Permission health (docs/15 step 37)

    /// True when microphone access is denied or was revoked (a TCC reset) —
    /// the menu bar warns instead of the app sitting silently deaf.
    @Published private(set) var microphonePermissionDenied = false

    func refreshPermissionHealth() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionDenied = (status == .denied || status == .restricted)
    }

    /// Loads (downloading on first run) the ASR model so the first dictation
    /// is fast. Called from onboarding's "Warm up now" (FR-2.4). Goes through
    /// the router: pinned မြန်မာ warms the Burmese engine instead.
    func warmUp() async throws {
        try await routedEngine.prepare(languageMode: settings.languageMode)
        settings.modelWarmedOnce = true
    }

    /// Loads the routed ASR model in the background (docs/15 step 13) so the
    /// day's first dictation feels identical to the tenth — without this, the
    /// press after every relaunch paid the multi-second model load inside the
    /// take itself. Called at launch and again when the language mode changes
    /// (the router may then point at a different engine).
    ///
    /// Gated on a previous successful load: a silent preload must never turn
    /// into a surprise ~600 MB download on a fresh install — onboarding owns
    /// that first, explicit download. Utility priority keeps the CoreML
    /// compile off launch-critical threads; failures only log, because the
    /// take path retries the load itself and owns user-facing errors.
    func preloadEngineIfWarmedBefore(mode: LanguageMode? = nil) {
        guard settings.modelWarmedOnce else { return }
        let engine = routedEngine
        let languageMode = mode ?? settings.languageMode
        let detector = speechDetector
        Task.detached(priority: .utility) {
            // The VAD's ~0.6 MB model first, so the very next take is gated;
            // then the big ASR load.
            await detector.prepare()
            do {
                try await engine.prepare(languageMode: languageMode)
            } catch {
                VocalLog.engine.error(
                    "background model preload failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
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
        let parakeetEngine = parakeetEngine
        let parakeetOn = settings.parakeetEnglishEnabled
        let mode = settings.languageMode
        hintGeneration += 1
        let generation = hintGeneration
        Task { [weak self] in
            if mode == .pinned(.english), parakeetOn {
                let loaded = await parakeetEngine.isModelLoaded
                guard !loaded else { return }
                guard let self, self.hintGeneration == generation else { return }
                self.hudState.partialText =
                    "First Parakeet run: downloading the fast English model (~600 MB) and preparing it — later dictations are instant."
            } else if mode == .pinned(.burmese) {
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

    /// Short-tap release (docs/15 W10): the mic stops now, but a
    /// speech-bearing take is held until the double-tap window closes (see
    /// AppDelegate's commit / discard calls) so the first tap of a lock
    /// gesture never pastes.
    func endDictationProvisionally() {
        DeliverySounds.playStop(enabled: settings.soundsEnabled)
        enqueueControl { session in await session.pressEndedProvisionally() }
    }

    func commitProvisionalDictation() {
        enqueueControl { session in await session.commitProvisionalTake() }
    }

    func discardProvisionalDictation() {
        enqueueControl { session in await session.discardProvisionalTake() }
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

    // MARK: - File import (docs/15 step 44, FR-6 — scoped)

    /// Imports an audio file into History: decode → transcribe → deterministic
    /// stages → history row. No delivery (there is no insertion point), no
    /// cleanup (the prompt is tuned for dictation, and an import has no
    /// profile). Timestamped segments and the quadratic-pipeline hardening
    /// FR-6 also calls for remain open in the plan.
    ///
    /// Known bound: the import transcribes on the same engine the live
    /// pipeline uses, and engines are actors — a dictation released while a
    /// long import is decoding queues behind it. A second engine instance
    /// would double model memory; until FR-6 gets its own progress/cancel
    /// UI, the trade is documented rather than half-solved.
    func importAudioFile() {
        guard let database else {
            showNotice("History is unavailable — cannot import")
            return
        }
        // An LSUIElement app opening a modal panel from the menu-bar popover
        // must activate first, or the panel can appear behind the frontmost
        // app without key focus.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        showNotice("Importing \(url.lastPathComponent)…")
        let engine = routedEngine
        let mode = settings.languageMode
        let settings = settings
        Task { [weak self] in
            do {
                let entries = await settings.enabledDictionaryEntries()
                // Everything heavy — decode, transcription, and the text
                // stages over what may be hours of transcript — stays off the
                // main actor; only the save and the notice come back to it.
                let (record, wasTruncated) = try await Task.detached(priority: .userInitiated) {
                    () -> (TranscriptRecord, Bool) in
                    let decoded = try AudioFileDecoder.decode(url: url)
                    let clock = ContinuousClock()
                    let start = clock.now
                    let result = try await engine.transcribe(
                        decoded.audio, languageMode: mode, dictionaryTerms: entries.map(\.written)
                    )
                    let elapsed = start.duration(to: clock.now)
                    let language = result.detectedLanguage
                    let formatting = FormattingOptions()
                    let normalized = Stage1Normalizer.normalize(
                        result.text, language: language, formatting: formatting
                    )
                    let stage2 = DictionaryEngine.apply(
                        normalized, entries: entries, language: language
                    ).text
                    let formatted = Stage4Formatter.format(
                        stage2, language: language, formatting: formatting, precedingContext: nil
                    )
                    let record = TranscriptRecord(
                        createdAt: Date(),
                        source: .fileImport,
                        language: language,
                        rawText: result.text,
                        deliveredText: formatted,
                        durationSeconds: decoded.audio.durationSeconds,
                        profileName: "Import",
                        routeKind: .defaultRoute,
                        // Imports run without a profile, so stage 3 never applies.
                        cleanup: .skipped(reason: .profileDisabled),
                        timings: TimingBreakdown(
                            transcriptionSeconds: Double(elapsed.components.seconds)
                                + Double(elapsed.components.attoseconds) / 1e18
                        ),
                        importedFilename: url.lastPathComponent
                    )
                    return (record, decoded.wasTruncated)
                }.value
                try database.save(record)
                let suffix = wasTruncated ? " (truncated at the 4 h cap)" : ""
                self?.showNotice("Imported \(url.lastPathComponent)\(suffix) — see History")
            } catch {
                self?.showNotice("Import failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Auto-learned vocabulary (docs/15 step 27)

    /// The pending "Add 'X' to your dictionary?" proposal, surfaced in the
    /// menu bar. Replaced by newer proposals; cleared when accepted.
    @Published private(set) var vocabularySuggestion: VocabularySuggestor.Suggestion?
    private var lastDeliveryForLearning: (text: String, at: Date)?

    private func noteDeliveredForLearning(_ text: String) {
        defer { lastDeliveryForLearning = (text, Date()) }
        guard let previous = lastDeliveryForLearning else { return }
        guard
            let suggestion = VocabularySuggestor.suggestion(
                previousText: previous.text,
                currentText: text,
                gapSeconds: Date().timeIntervalSince(previous.at)
            )
        else { return }
        // Skip proposals the dictionary already answers.
        let existing = (try? database?.dictionaryEntries()) ?? []
        guard !existing.contains(where: {
            $0.spoken.lowercased() == suggestion.spoken.lowercased()
        }) else { return }
        vocabularySuggestion = suggestion
        showNotice("New word? The menu bar can add “\(suggestion.written)” to your dictionary")
    }

    /// The user accepted the proposal: it becomes an ordinary dictionary
    /// entry, applied by stage 2 from the next take on.
    func acceptVocabularySuggestion() {
        guard let suggestion = vocabularySuggestion, let database else { return }
        let entry = DictionaryEntry(
            spoken: suggestion.spoken,
            written: suggestion.written,
            createdAt: Date()
        )
        do {
            try database.save(entry)
            vocabularySuggestion = nil
            showNotice("Added “\(suggestion.written)” to your dictionary")
        } catch {
            showNotice("Could not save the entry: \(error.localizedDescription)")
        }
    }

    func dismissVocabularySuggestion() {
        vocabularySuggestion = nil
    }

    // MARK: - Re-paste + undo (docs/15 step 28)

    /// The newest delivered dictation, or nil when history has none — what
    /// the menu bar's re-paste and undo act on.
    private func latestDeliveredRecord() -> TranscriptRecord? {
        guard let database else { return nil }
        // A bounded fetch: decoding the whole history (imports included) on
        // the main thread to find one row is a beachball. 50 covers any
        // plausible run of cancelled takes and imports at the top.
        let records = (try? database.recentTranscripts(limit: 50)) ?? []
        return records.first { !$0.isCancelled && $0.source != .fileImport }
    }

    /// Menu-bar "Paste Last Transcript Again" (Wispr's ⌘⌃V, docs/15 step 28):
    /// re-delivers the newest transcript into whatever is frontmost, through
    /// the same insertion ladder as a live take.
    func pasteLastTranscriptAgain() {
        guard let record = latestDeliveredRecord() else {
            showNotice("Nothing to paste yet")
            return
        }
        NSApp.deactivate()
        let overrides = settings.insertionStrategyOverrides
        Task { @MainActor in
            await Self.yieldFocusToPreviousApp()
            let deliverer = TextDeliverer(
                strategies: InsertionStrategyTable(overrides: overrides)
            )
            // The text is already fully formatted; the deliverer only routes
            // by app and mode, so default formatting metadata is fine here.
            let context = DeliveryContext(
                pressTimeAppBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                isLockMode: false,
                formatting: FormattingOptions(),
                language: record.language
            )
            let outcome = await deliverer.deliver(record.deliveredText, context: context)
            self.showDelivery(outcome: outcome)
        }
    }

    /// The undo safety net (docs/15 step 28, Part 2b form): replace the last
    /// insertion with the raw transcription, or remove it entirely. AX-only —
    /// where the focused element can't be read and edited, nothing changes
    /// and the HUD says so, which beats guessing with synthesized keystrokes.
    func undoLastInsertion(replaceWithRaw: Bool) {
        guard let record = latestDeliveredRecord() else {
            showNotice("Nothing to undo yet")
            return
        }
        NSApp.deactivate()
        Task { @MainActor in
            await Self.yieldFocusToPreviousApp()
            let replacement = replaceWithRaw ? record.rawText : ""
            if AXUndo.replaceLastOccurrence(of: record.deliveredText, with: replacement) {
                self.showNotice(
                    replaceWithRaw
                        ? "Replaced with the raw transcription" : "Last insertion removed"
                )
            } else {
                self.showNotice("Undo isn't available in this app")
            }
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
            // A press is live again — a scheduled idle unload must not pull
            // the model out from under it.
            idleUnloadTask?.cancel()
            hudState.mode = .listening(startedAt: Date())
        case .recording:
            // Keep the arming timestamp: resetting it here visibly restarted
            // the HUD's elapsed timer a beat into every take (docs/15 W13).
            if case .listening = hudState.mode {
                // already listening since arming
            } else {
                hudState.mode = .listening(startedAt: Date())
            }
            DeliverySounds.playStart(enabled: settings.soundsEnabled)
        case .transcribing:
            hudState.mode = .processing(stage: .transcribing)
        case .cleaning:
            hudState.mode = .processing(stage: .cleaning)
        case .delivering:
            hudState.mode = .processing(stage: .delivering)
        case .cancelled:
            hintGeneration += 1
            pendingLowDiskNotice = false
            // A device change queued its notice for a take the user then
            // cancelled — the flag must not survive to caption the next take.
            pendingDeviceChangeNotice = false
            pendingAutoStopNotice = false
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
            // visible when it returns to idle belongs to this take. The error
            // outranks the guards' pending notices — a take a guard ended
            // whose transcription then failed must not claim "take saved".
            if let error = await session.lastError {
                pendingLowDiskNotice = false
                pendingDeviceChangeNotice = false
                pendingAutoStopNotice = false
                DeliverySounds.playError(enabled: settings.soundsEnabled)
                hudState.mode = .error(Self.message(for: error))
                scheduleErrorDismiss()
                // docs/15 step 35: a failed take just preserved its audio;
                // surface the recovery offer without waiting for a relaunch.
                refreshRecoverableTake()
            } else if pendingLowDiskNotice {
                pendingLowDiskNotice = false
                showNotice("Disk almost full — take saved before recording stopped")
            } else if pendingDeviceChangeNotice {
                pendingDeviceChangeNotice = false
                showNotice("Audio device changed — take saved")
            } else if case .notice = hudState.mode {
                // A delivery notice (clipboard fallback / secure block) is
                // already showing; let its own dismiss timer run.
                pendingAutoStopNotice = false
            } else if pendingAutoStopNotice {
                pendingAutoStopNotice = false
                showNotice("Stopped after silence — take delivered")
            } else if settings.showTimingsToast, let timings = await session.lastTimings {
                // FR-11.4 opt-in: show where the time went after each take.
                showNotice(Self.timingsSummary(timings))
            } else {
                hudState.mode = .hidden
            }
            hudState.partialText = ""
            hudState.levels = []
            scheduleIdleUnload()
        }
    }

    // MARK: - Idle model unload (docs/15 step 13, the optional other half)

    private var idleUnloadTask: Task<Void, Never>?

    /// Arms (or re-arms) the idle unload countdown when a take settles.
    /// Keep-resident (0) is the default — this exists for memory-constrained
    /// Macs, and the next press simply pays the model load again.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let minutes = settings.idleUnloadMinutes
        guard minutes > 0 else { return }
        let engine = routedEngine
        idleUnloadTask = Task {
            try? await Task.sleep(for: .seconds(min(24 * 60, max(1, minutes)) * 60))
            guard !Task.isCancelled else { return }
            await engine.unload()
            VocalLog.session.info("idle unload: ASR model released after \(minutes) min")
        }
    }

    /// One-line "where the time went" summary for the latency toast.
    private static func timingsSummary(_ timings: TimingBreakdown) -> String {
        var parts = [String(format: "transcribe %.2fs", timings.transcriptionSeconds)]
        if timings.cleanupSeconds > 0 {
            parts.append(String(format: "cleanup %.2fs", timings.cleanupSeconds))
        }
        parts.append(String(format: "deliver %.2fs", timings.deliverySeconds))
        let total = String(format: "%.2fs", timings.totalPostReleaseSeconds)
        return "Delivered in \(total) (\(parts.joined(separator: ", ")))"
    }

    /// Delivery outcomes the user must hear about (FR-3.2/3.4/3.6) — invoked
    /// by the deliverer seam before the session finishes the take.
    func showDelivery(outcome: DeliveryOutcome, text: String = "") {
        // Reaching delivery means transcription ran, so the model is on disk
        // and loaded — record that, so future launches may preload silently
        // even if onboarding's "Warm up now" was skipped (docs/15 step 13).
        if !settings.modelWarmedOnce {
            settings.modelWarmedOnce = true
        }
        // docs/15 step 27: a quick re-dictation that differs by one respelled
        // span is the user fixing a mis-hearing — propose (never auto-apply)
        // the dictionary entry. Secure-field takes leave no trace, so they
        // don't participate.
        switch outcome {
        case .blockedSecureField:
            break
        case .inserted, .copiedToClipboard:
            if !text.isEmpty {
                noteDeliveredForLearning(text)
            }
        }
        switch outcome {
        case .inserted:
            // docs/15 step 23: the paste landing gets its own sound.
            DeliverySounds.playDelivered(enabled: settings.soundsEnabled)
        case .copiedToClipboard:
            Diagnostics.shared.increment(.clipboardFallbacks)
            showNotice("Copied — press ⌘V to paste")
        case .blockedSecureField(let culprit):
            Diagnostics.shared.increment(.secureFieldBlocks)
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

    private var dismissGeneration = 0

    private func scheduleErrorDismiss() {
        // Generation-tokened: comparing modes by value would let take N's
        // timer dismiss take N+1's *identical* notice almost immediately
        // (HUDState.Mode is Equatable, and repeated clipboard fallbacks
        // produce the same string). Only the newest timer may dismiss, and
        // only while an error/notice is still what's showing.
        dismissGeneration += 1
        let generation = dismissGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.dismissGeneration == generation else { return }
            switch self.hudState.mode {
            case .error, .notice:
                self.hudState.mode = .hidden
            case .hidden, .listening, .processing:
                break
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
            VocalLog.persistence.error("Application Support unavailable — history disabled")
            return nil
        }
        let directory = appSupport.appendingPathComponent("Vocal", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("vocal.sqlite").path
            return try DatabaseStore(path: path)
        } catch {
            VocalLog.persistence.error(
                "database open failed — history disabled: \(String(describing: error), privacy: .public)"
            )
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

    /// The ModelStore root: `Application Support/Vocal/models` — the same
    /// tree `SherpaOnnxEngine` and the VAD install into, so Settings → Models
    /// measures and deletes exactly what they wrote (docs/15 step 15).
    nonisolated static func modelsDirectory() -> URL? {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return appSupport
            .appendingPathComponent("Vocal", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
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
                VocalLog.persistence.info("removed \(removed) expired audio recording(s)")
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

    func notePartial(_ text: String) {
        appState?.showPreview(text)
    }

    func noteDelivery(_ outcome: DeliveryOutcome, text: String) {
        appState?.showDelivery(outcome: outcome, text: text)
    }

    func noteLowDisk() {
        appState?.lowDiskGuardTripped()
    }

    func noteDeviceChange() {
        appState?.deviceChangedMidTake()
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
    let onOutcome: @MainActor (DeliveryOutcome, String) -> Void

    func deliver(_ text: String, context: DeliveryContext) async -> DeliveryOutcome {
        let outcome = await deliverer.deliver(text, context: context)
        await onOutcome(outcome, text)
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
