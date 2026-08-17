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
/// Flow per take: press resolves and pins the profile (FR-3.6), starts audio,
/// and fires the cleanup prewarm; release stops audio and runs
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

    /// Everything a session needs, injected by the composition root.
    public struct Dependencies: Sendable {
        public var audio: any AudioCapturing
        public var engine: any TranscriptionEngine
        /// Stage-3 pipeline; nil when no provider is configured.
        public var cleanup: CleanupPipeline?
        /// Identity of the provider behind `cleanup`, recorded in history
        /// outcomes. `CleanupPipeline` does not expose its provider, so the
        /// composition root supplies the ID alongside the pipeline; a
        /// profile's `providerOverride` wins when set.
        public var cleanupProviderID: CleanupProviderID
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

        public init(
            audio: any AudioCapturing,
            engine: any TranscriptionEngine,
            cleanup: CleanupPipeline? = nil,
            cleanupProviderID: CleanupProviderID = .openAICompatible(name: "unconfigured"),
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
            self.cleanup = cleanup
            self.cleanupProviderID = cleanupProviderID
            self.prewarmCleanup = prewarmCleanup
            self.deliverer = deliverer
            self.store = store
            self.config = config
            self.profileResolution = profileResolution
            self.now = now
        }
    }

    // MARK: - State

    private struct ActiveTake {
        var profile: Profile
        var routeKind: TranscriptRecord.RouteKind
        var pressTimeBundleID: String?
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

    /// Hotkey press: resolve and pin the profile (FR-3.6), fire the cleanup
    /// prewarm, and start audio capture. No-op unless idle. If audio fails to
    /// start there is nothing to persist; the error lands in `lastError` and
    /// the session returns to idle.
    public func pressBegan() async {
        guard phaseValue == .idle else { return }
        lastError = nil
        pendingRelease = nil
        pendingCancel = false
        transition(to: .arming)

        let resolved = await deps.profileResolution()

        let prewarm = deps.prewarmCleanup
        prewarmTask = Task { await prewarm() }

        let pressedAt = clock.now
        do {
            let capture = try await deps.audio.start()
            take = ActiveTake(
                profile: resolved.profile,
                routeKind: resolved.routeKind,
                pressTimeBundleID: resolved.pressTimeBundleID,
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
            transition(to: .idle)
            return
        }

        let languageMode: LanguageMode
        if let override = active.profile.languageOverride {
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
            return
        }
        let transcriptionSeconds = Self.seconds(transcriptionStart.duration(to: clock.now))

        let language = result.detectedLanguage
        let formatting = active.profile.formatting

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
        } else if !active.profile.cleanupEnabled {
            cleanupOutcome = .skipped(reason: .profileDisabled)
        } else if let pipeline = deps.cleanup {
            transition(to: .cleaning)
            // History must record what actually ran (FR-5.1). Only one pipeline
            // is injected today, so a profile's providerOverride is routing
            // intent, not reality — runtime provider selection is a known gap
            // (docs/11).
            let providerID = deps.cleanupProviderID
            let stylePrompt: String
            if active.profile.ignoresGlobalStyle {
                stylePrompt = ""
            } else {
                stylePrompt = await deps.config.globalStylePrompt
            }
            let timeout = await deps.config.cleanupTimeout
            let request = CleanupRequest(
                text: stage2Text,
                language: language,
                profilePrompt: active.profile.promptText,
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
            pressTimeAppBundleID: active.pressTimeBundleID,
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
            return
        }

        var targetBundleID = active.pressTimeBundleID
        if case .inserted(_, let appBundleID) = delivery, let appBundleID {
            targetBundleID = appBundleID
        }

        let record = TranscriptRecord(
            createdAt: deps.now(),
            source: .dictation,
            language: language,
            rawText: result.text,
            deliveredText: formatted,
            durationSeconds: audio.durationSeconds,
            targetAppBundleID: targetBundleID,
            profileName: active.profile.name,
            routeKind: active.routeKind,
            cleanup: cleanupOutcome,
            timings: TimingBreakdown(
                captureSeconds: captureSeconds,
                transcriptionSeconds: transcriptionSeconds,
                dictionarySeconds: dictionarySeconds,
                cleanupSeconds: cleanupSeconds,
                deliverySeconds: deliverySeconds
            )
        )
        // A failed save must not un-deliver text that already landed; the
        // session still returns to idle (history write errors surface via
        // PersistenceKit, not here).
        try? await deps.store.save(record)
        transition(to: .idle)
    }

    // MARK: - Helpers

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
