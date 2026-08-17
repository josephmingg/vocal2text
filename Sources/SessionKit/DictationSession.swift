import ASRKit
import CleanupKit
import CoreModels
import Foundation
import TextPipeline

/// The one actor that owns the dictation lifecycle (docs/03 §2). Views render
/// its published phases and never own logic; every platform seam (audio,
/// delivery, persistence, configuration) is injected via `Dependencies`, so
/// the whole machine runs on Linux under test.
///
/// Flow per take: press starts audio, pins the profile (FR-3.6), and fires
/// the cleanup prewarm — audio first, the other two concurrently beside it;
/// release stops audio, joins the pinned profile, and runs
/// transcribe → stage 1 → stage 2 (dictionary) → stage 3 (cleanup, optional)
/// → stage 4 → deliver → save, measuring each stage with `ContinuousClock`.
public actor DictationSession {

    /// Lifecycle phases, in normal order. `cancelled` is a transient phase on
    /// the way back to `idle` after `cancel()`.
    public enum Phase: Sendable, Equatable {
        case idle
        case arming
        case recording(startedAt: ContinuousClock.Instant)
        case transcribing
        case cleaning
        case delivering
        case cancelled
    }

    /// The stage-3 pipeline chosen for one take, plus the provider identity
    /// history records — `CleanupPipeline` does not expose its provider, so
    /// the two travel together.
    public struct CleanupSelection: Sendable {
        public var pipeline: CleanupPipeline
        public var providerID: CleanupProviderID

        public init(pipeline: CleanupPipeline, providerID: CleanupProviderID) {
            self.pipeline = pipeline
            self.providerID = providerID
        }
    }

    /// Chooses the stage-3 pipeline for one take, called after the profile is
    /// pinned and only when cleanup is actually going to run.
    ///
    /// Resolving per take rather than per launch is what makes a profile's
    /// `providerOverride` real (docs/11 G3) and lets a changed model or server
    /// URL take effect on the next dictation instead of the next launch
    /// (docs/11 G15). Returning nil means no provider is configured, and the
    /// take is recorded as `skipped(providerUnavailable)`.
    public typealias CleanupSelecting = @Sendable (Profile) async -> CleanupSelection?

    /// Retains a delivered take's audio, returning the path history should
    /// record — nil when audio is not being kept (the user's retention
    /// setting) or the write failed (FR-5.1, docs/11 G9).
    ///
    /// Called only after delivery succeeds, so a blocked secure field or a
    /// discarded take never leaves a recording behind, and a failure here can
    /// never cost the user the transcript.
    public typealias AudioArchiving = @Sendable (PCMChunk, UUID) async -> String?

    /// Everything a session needs, injected by the composition root.
    public struct Dependencies: Sendable {
        public var audio: any AudioCapturing
        public var engine: any TranscriptionEngine
        /// Stage-3 provider selection, resolved per take.
        public var selectCleanup: CleanupSelecting
        /// Retains the take's audio after delivery; nil keeps nothing.
        public var archiveAudio: AudioArchiving?
        /// Fired fire-and-forget at hotkey press so the model is hot at
        /// release (docs/03 §2). Wire to `CleanupProvider.prewarm`; defaults
        /// to a no-op.
        public var prewarmCleanup: @Sendable () async -> Void
        public var deliverer: any TextDelivering
        public var store: any TranscriptStoring
        public var config: any SessionConfiguring
        /// Resolved once at press and pinned for the whole take (FR-3.6).
        public var profileResolution:
            @Sendable () async -> (
                profile: Profile,
                routeKind: TranscriptRecord.RouteKind,
                pressTimeBundleID: String?
            )
        /// Wall-clock source for `TranscriptRecord.createdAt`; injectable so
        /// tests pin timestamps.
        public var now: @Sendable () -> Date

        /// Fixed-pipeline form: every take uses the same provider. Used by
        /// tests and by platforms with a single built-in provider; the Mac app
        /// passes a `selectCleanup` closure instead.
        public init(
            audio: any AudioCapturing,
            engine: any TranscriptionEngine,
            cleanup: CleanupPipeline? = nil,
            cleanupProviderID: CleanupProviderID = .openAICompatible(name: "unconfigured"),
            archiveAudio: AudioArchiving? = nil,
            prewarmCleanup: @escaping @Sendable () async -> Void = {},
            deliverer: any TextDelivering,
            store: any TranscriptStoring,
            config: any SessionConfiguring,
            profileResolution: @escaping @Sendable () async -> (
                profile: Profile,
                routeKind: TranscriptRecord.RouteKind,
                pressTimeBundleID: String?
            ),
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.init(
                audio: audio,
                engine: engine,
                selectCleanup: { _ in
                    cleanup.map { CleanupSelection(pipeline: $0, providerID: cleanupProviderID) }
                },
                archiveAudio: archiveAudio,
                prewarmCleanup: prewarmCleanup,
                deliverer: deliverer,
                store: store,
                config: config,
                profileResolution: profileResolution,
                now: now
            )
        }

        public init(
            audio: any AudioCapturing,
            engine: any TranscriptionEngine,
            selectCleanup: @escaping CleanupSelecting,
            archiveAudio: AudioArchiving? = nil,
            prewarmCleanup: @escaping @Sendable () async -> Void = {},
            deliverer: any TextDelivering,
            store: any TranscriptStoring,
            config: any SessionConfiguring,
            profileResolution: @escaping @Sendable () async -> (
                profile: Profile,
                routeKind: TranscriptRecord.RouteKind,
                pressTimeBundleID: String?
            ),
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.audio = audio
            self.engine = engine
            self.selectCleanup = selectCleanup
            self.archiveAudio = archiveAudio
            self.prewarmCleanup = prewarmCleanup
            self.deliverer = deliverer
            self.store = store
            self.config = config
            self.profileResolution = profileResolution
            self.now = now
        }
    }

    // MARK: - State

    /// The press-time profile resolution, still in flight. Resolution can
    /// block on platform I/O (macOS reads the frontmost browser's tab URL via
    /// an osascript round-trip, up to 1.5 s), so it runs concurrently with
    /// audio start and is joined at release — the profile is not needed until
    /// then. It stays a *press-time* snapshot either way (FR-3.6): the
    /// frontmost context is sampled when the task starts, not when it is read.
    typealias PendingResolution = Task<
        (profile: Profile, routeKind: TranscriptRecord.RouteKind, pressTimeBundleID: String?),
        Never
    >

    private struct ActiveTake {
        var resolution: PendingResolution
        var capture: CaptureSession
        var pressedAt: ContinuousClock.Instant
    }

    private let deps: Dependencies
    private let clock = ContinuousClock()

    private var phaseValue: Phase = .idle
    private var phaseSubscribers: [UUID: AsyncStream<Phase>.Continuation] = [:]
    private var take: ActiveTake?
    /// Release/cancel edges that arrived during the `.arming` suspension
    /// window; honored the moment recording starts (a lost release would
    /// leave the mic running — NFR-1).
    private var pendingRelease: Bool?
    private var pendingCancel = false

    /// The most recent transcription (or capture) failure. Documented v1
    /// choice: a failed transcription produces no text worth a history row —
    /// raw-audio recovery lives in the capture layer (FR-11.3) — so the
    /// session delivers and saves nothing, surfaces the error here for the
    /// HUD, and returns to idle.
    public private(set) var lastError: TranscriptionError?

    /// The fire-and-forget prewarm task from the latest press; kept so tests
    /// can await its completion deterministically.
    private(set) var prewarmTask: Task<Void, Never>?

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: - Observation

    /// The current lifecycle phase.
    public var phase: Phase {
        phaseValue
    }

    /// A stream of phase changes for UI observation. Each access returns an
    /// independent subscription (transitions are multicast to every stored
    /// continuation) that first yields the current phase, then every
    /// subsequent transition. Buffering is unbounded, so a slow consumer
    /// never blocks the session.
    public var phases: AsyncStream<Phase> {
        let (stream, continuation) = AsyncStream<Phase>.makeStream()
        continuation.yield(phaseValue)
        let id = UUID()
        phaseSubscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removePhaseSubscriber(id) }
        }
        return stream
    }

    private func removePhaseSubscriber(_ id: UUID) {
        phaseSubscribers[id] = nil
    }

    private func transition(to newPhase: Phase) {
        phaseValue = newPhase
        for continuation in phaseSubscribers.values {
            continuation.yield(newPhase)
        }
    }

    // MARK: - Press lifecycle

    /// Hotkey press: start audio capture, pin the profile (FR-3.6), and fire
    /// the cleanup prewarm. No-op unless idle. If audio fails to start there
    /// is nothing to persist; the error lands in `lastError` and the session
    /// returns to idle.
    ///
    /// Capture start is the *first* thing awaited. Profile resolution and the
    /// prewarm both run concurrently beside it, because either can block on
    /// platform I/O and any millisecond spent before the mic opens is speech
    /// the user already spoke and will never get back.
    public func pressBegan() async {
        guard phaseValue == .idle else { return }
        lastError = nil
        pendingRelease = nil
        pendingCancel = false
        transition(to: .arming)

        let resolve = deps.profileResolution
        let resolution = PendingResolution { await resolve() }

        let prewarm = deps.prewarmCleanup
        prewarmTask = Task { await prewarm() }

        let pressedAt = clock.now
        do {
            let capture = try await deps.audio.start()
            take = ActiveTake(
                resolution: resolution,
                capture: capture,
                pressedAt: pressedAt
            )
            transition(to: .recording(startedAt: pressedAt))
            // A release or Escape that arrived while we were suspended in
            // profile resolution / audio start (the .arming window) must not
            // be lost — the mic would run until the next full press cycle.
            if pendingCancel {
                pendingCancel = false
                pendingRelease = nil
                await cancel()
            } else if let release = pendingRelease {
                pendingRelease = nil
                await finishPress(isLockMode: release, heldDurationOverride: nil)
            }
        } catch {
            take = nil
            pendingRelease = nil
            pendingCancel = false
            resolution.cancel()
            lastError = .audioUnreadable("capture failed to start: \(error)")
            transition(to: .idle)
        }
    }

    /// Hotkey release: stop capture and run the full pipeline through delivery
    /// and history. A release during `.arming` is latched and honored the
    /// moment recording starts.
    public func pressEnded(isLockMode: Bool = false) async {
        if phaseValue == .arming {
            pendingRelease = isLockMode
            return
        }
        await finishPress(isLockMode: isLockMode, heldDurationOverride: nil)
    }

    /// Escape during capture (FR-1.6): abort the take — the session
    /// transcribes, delivers, and saves nothing. The capture layer owns the
    /// 24 h recoverable-audio window for cancelled takes. A cancel during
    /// `.arming` is latched like a pending release.
    public func cancel() async {
        if phaseValue == .arming {
            pendingCancel = true
            return
        }
        guard case .recording = phaseValue, let active = take else { return }
        take = nil
        active.resolution.cancel()
        await active.capture.cancel()
        transition(to: .cancelled)
        transition(to: .idle)
    }

    // MARK: - Release pipeline

    /// `heldDurationOverride` is a test seam substituting the measured hold
    /// time in the FR-1.5 accidental-tap check; production always passes nil.
    func finishPress(isLockMode: Bool, heldDurationOverride: Duration?) async {
        guard case .recording(let startedAt) = phaseValue, let active = take else { return }
        take = nil
        transition(to: .transcribing)

        let held = heldDurationOverride ?? startedAt.duration(to: clock.now)
        let audio = await active.capture.finish()
        let captureSeconds = Self.seconds(active.pressedAt.duration(to: clock.now))

        // FR-1.5, v1 shape: the session has no VAD, so captured-audio duration
        // stands in for "speech detected" — a sub-500 ms hold is discarded
        // silently only when the audio is also shorter than 500 ms.
        if held < .milliseconds(500), audio.durationSeconds < 0.5 {
            active.resolution.cancel()
            transition(to: .idle)
            return
        }

        // Join the press-time resolution started in `pressBegan`. It has had
        // the whole utterance to finish, so this is normally already complete.
        let resolved = await active.resolution.value
        _ = await runPipeline(
            audio: audio,
            resolved: resolved,
            isLockMode: isLockMode,
            captureSeconds: captureSeconds,
            source: .dictation
        )
    }

    /// Recovers a cancelled take's audio (FR-1.6, docs/11 G9): the identical
    /// post-capture pipeline — transcribe, dictionary, cleanup gating,
    /// formatting, delivery, history — so a recovered take is indistinguishable
    /// from one that was never cancelled, except for its `source`.
    ///
    /// The profile is resolved fresh: the take is being delivered *now*, into
    /// whatever is frontmost now, so pinning the app from a press minutes ago
    /// would route by a context that no longer exists.
    ///
    /// Returns whether the audio was consumed. `false` means the take is still
    /// worth another attempt later — the session was busy, or transcription
    /// failed — so the caller must keep the recording rather than discard it.
    @discardableResult
    public func recover(audio: PCMChunk) async -> Bool {
        guard phaseValue == .idle, audio.durationSeconds > 0 else { return false }
        lastError = nil
        transition(to: .transcribing)
        let resolved = await deps.profileResolution()
        return await runPipeline(
            audio: audio,
            resolved: resolved,
            isLockMode: false,
            captureSeconds: audio.durationSeconds,
            source: .recovered
        )
    }

    /// Everything a take does once its audio exists. Shared by the live press
    /// path and recovery so the two can never drift apart.
    ///
    /// Returns whether the take reached a terminal outcome that consumes its
    /// audio. Only a transcription failure returns `false`: nothing was
    /// produced from the recording, so re-running it is a real second chance.
    /// A secure-field block returns `true` — FR-3.2 means that take leaves no
    /// trace, and holding its raw audio back for another try would defeat the
    /// rule it just enforced.
    @discardableResult
    private func runPipeline(
        audio: PCMChunk,
        resolved: (
            profile: Profile,
            routeKind: TranscriptRecord.RouteKind,
            pressTimeBundleID: String?
        ),
        isLockMode: Bool,
        captureSeconds: Double,
        source: TranscriptSource
    ) async -> Bool {
        let profile = resolved.profile

        let languageMode: LanguageMode
        if let override = profile.languageOverride {
            languageMode = override
        } else {
            languageMode = await deps.config.globalLanguageMode
        }
        let entries = await deps.config.enabledDictionaryEntries()
        let writtenForms = entries.map(\.written)

        let transcriptionStart = clock.now
        let result: TranscriptionResult
        do {
            result = try await deps.engine.transcribe(
                audio, languageMode: languageMode, dictionaryTerms: writtenForms
            )
        } catch {
            lastError =
                (error as? TranscriptionError) ?? .engineUnavailable(String(describing: error))
            transition(to: .idle)
            return false
        }
        let transcriptionSeconds = Self.seconds(transcriptionStart.duration(to: clock.now))

        let language = result.detectedLanguage
        let formatting = profile.formatting

        let dictionaryStart = clock.now
        let normalized = Stage1Normalizer.normalize(
            result.text, language: language, formatting: formatting
        )
        let stage2Text = DictionaryEngine.apply(normalized, entries: entries, language: language)
            .text
        let dictionarySeconds = Self.seconds(dictionaryStart.duration(to: clock.now))

        var deliveryText = stage2Text
        var cleanupSeconds = 0.0
        let cleanupOutcome: CleanupOutcome

        // Precedence per docs/05 §0: master switch, then per-profile opt-in,
        // then provider availability.
        let masterSwitch = await deps.config.cleanupMasterSwitch
        if !masterSwitch {
            cleanupOutcome = .skipped(reason: .masterSwitchOff)
        } else if !profile.cleanupEnabled {
            cleanupOutcome = .skipped(reason: .profileDisabled)
        } else if !Self.cleanupAllowed(for: language, profile: profile) {
            cleanupOutcome = .skipped(reason: .languageOptOut)
        } else if let selection = await deps.selectCleanup(profile) {
            transition(to: .cleaning)
            // Resolved for this take from this profile, so history records the
            // provider that actually ran (FR-5.1) — including a profile's
            // `providerOverride` (docs/11 G3) and any settings change made
            // since launch (docs/11 G15).
            let pipeline = selection.pipeline
            let providerID = selection.providerID
            let stylePrompt: String
            if profile.ignoresGlobalStyle {
                stylePrompt = ""
            } else {
                stylePrompt = await deps.config.globalStylePrompt
            }
            let timeout = await deps.config.cleanupTimeout
            let request = CleanupRequest(
                text: stage2Text,
                language: language,
                profilePrompt: profile.promptText,
                stylePrompt: stylePrompt,
                protectedTerms: writtenForms
            )
            let cleanupStart = clock.now
            let outcome = await pipeline.run(request, timeout: timeout)
            cleanupSeconds = Self.seconds(cleanupStart.duration(to: clock.now))
            switch outcome {
            case .cleaned(let cleaned, let model):
                deliveryText = cleaned
                cleanupOutcome = .applied(provider: providerID, model: model)
            case .fellBack(let reason):
                // FR-7.3: cleanup failure never loses the dictation — the
                // stage-2 text is delivered and the fallback reason logged.
                cleanupOutcome = Self.fallbackOutcome(reason: reason, provider: providerID)
            }
        } else {
            cleanupOutcome = .skipped(reason: .providerUnavailable)
        }

        // v1 delivers into a fresh insertion point; the preceding-context seam
        // (session-tracked last insert / AX read) arrives with the macOS app.
        let formatted = Stage4Formatter.format(
            deliveryText, language: language, formatting: formatting, precedingContext: nil
        )

        transition(to: .delivering)
        let context = DeliveryContext(
            pressTimeAppBundleID: resolved.pressTimeBundleID,
            isLockMode: isLockMode,
            formatting: formatting,
            language: language
        )
        let deliveryStart = clock.now
        let delivery = await deps.deliverer.deliver(formatted, context: context)
        let deliverySeconds = Self.seconds(deliveryStart.duration(to: clock.now))

        // FR-3.2: secure input means nothing was inserted and nothing may be
        // persisted — no history row for this take.
        if case .blockedSecureField = delivery {
            transition(to: .idle)
            return true
        }

        var targetBundleID = resolved.pressTimeBundleID
        if case .inserted(_, let appBundleID) = delivery, let appBundleID {
            targetBundleID = appBundleID
        }

        // FR-5.1 (docs/11 G9): retain the audio only for a take that actually
        // landed, and only when the user's retention setting keeps any. The
        // transcript id names the file, so the two are found together.
        let transcriptID = UUID()
        var audioPath: String?
        if let archive = deps.archiveAudio {
            audioPath = await archive(audio, transcriptID)
        }

        let record = TranscriptRecord(
            id: transcriptID,
            createdAt: deps.now(),
            source: source,
            language: language,
            rawText: result.text,
            deliveredText: formatted,
            durationSeconds: audio.durationSeconds,
            targetAppBundleID: targetBundleID,
            profileName: profile.name,
            routeKind: resolved.routeKind,
            cleanup: cleanupOutcome,
            timings: TimingBreakdown(
                captureSeconds: captureSeconds,
                transcriptionSeconds: transcriptionSeconds,
                dictionarySeconds: dictionarySeconds,
                cleanupSeconds: cleanupSeconds,
                deliverySeconds: deliverySeconds
            ),
            audioPath: audioPath
        )
        // A failed save must not un-deliver text that already landed; the
        // session still returns to idle (history write errors surface via
        // PersistenceKit, not here).
        try? await deps.store.save(record)
        transition(to: .idle)
        return true
    }

    // MARK: - Helpers

    /// Whether stage 3 may run for this language under this profile.
    ///
    /// Some languages are worse off with cleanup than without it: the small
    /// local models this app targets corrupt Burmese rather than tidy it
    /// (docs/04 Appendix A), and a cleanup step that damages the transcript is
    /// strictly worse than no cleanup at all. Those languages therefore stay
    /// on the deterministic stages by default.
    ///
    /// Pinning the language on a profile is the opt-in. It is an explicit,
    /// per-profile act — "this profile is for Burmese" — so a user who wants
    /// to experiment with a capable model has a way in, while someone who
    /// merely code-switches into Burmese mid-session never gets surprised.
    static func cleanupAllowed(for language: Language, profile: Profile) -> Bool {
        if language.allowsCleanupByDefault { return true }
        return profile.languageOverride?.pinnedLanguage == language
    }

    /// Maps a `CleanupPipeline` fallback reason onto history metadata: the
    /// "validator: <rule>" prefix and the protected-terms guard are validator
    /// rejections; everything else (provider errors, timeouts) is a failure.
    static func fallbackOutcome(reason: String, provider: CleanupProviderID) -> CleanupOutcome {
        let validatorPrefix = "validator: "
        if reason.hasPrefix(validatorPrefix) {
            return .rejectedByValidator(
                provider: provider, rule: String(reason.dropFirst(validatorPrefix.count))
            )
        }
        if reason == "protected-terms" {
            return .rejectedByValidator(provider: provider, rule: "protected-terms")
        }
        return .failed(provider: provider, reason: reason)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
