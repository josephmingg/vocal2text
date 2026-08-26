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
/// Flow per take: press starts audio capture immediately and kicks off profile
/// resolution + cleanup prewarm concurrently (FR-3.6 pins at press because the
/// resolution task snapshots the frontmost context at spawn; only the await
/// moves to release, so a slow browser AppleScript can never delay the
/// microphone). Release stops audio and hands the take to a processing
/// pipeline — transcribe → stage 1 → stage 2 (dictionary) → stage 3 (cleanup,
/// optional) → stage 4 → deliver → save — measured per stage with
/// `ContinuousClock`. Pipelines are chained in take order but run detached
/// from capture, so a new press is accepted while the previous take is still
/// transcribing or cleaning.
public actor DictationSession {

    /// Lifecycle phases, in normal order. `cancelled` is a transient phase on
    /// the way back to `idle` after `cancel()`. While a new take records over
    /// a still-processing previous take, the capture phases win the display.
    public enum Phase: Sendable, Equatable {
        case idle
        case arming
        case recording(startedAt: ContinuousClock.Instant)
        case transcribing
        case cleaning
        case delivering
        case cancelled
    }

    /// What press-time routing resolves to; awaited at release, never at press.
    public typealias ResolvedRoute = (
        profile: Profile,
        routeKind: TranscriptRecord.RouteKind,
        pressTimeBundleID: String?
    )

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
        /// Spawned at press so the snapshot happens at press time (FR-3.6),
        /// awaited only at release so it can never delay audio start (a
        /// browser-URL fetch may block up to ~1.5 s).
        public var profileResolution: @Sendable () async -> ResolvedRoute
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
            profileResolution: @escaping @Sendable () async -> ResolvedRoute,
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
        var resolution: Task<ResolvedRoute, Never>
        var capture: CaptureSession
        var pressedAt: ContinuousClock.Instant
    }

    /// Everything the detached processing pipeline needs once capture ended.
    private struct PendingTake {
        var resolution: Task<ResolvedRoute, Never>
        var audio: PCMChunk
        var captureSeconds: Double
        var isLockMode: Bool
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
    /// Pipelines queued or running. Capture phases always win the display;
    /// this only decides whether an ended capture settles to `.transcribing`
    /// (work still in flight) or `.idle`.
    private var queuedPipelines = 0

    /// The most recent transcription (or capture) failure. Documented v1
    /// choice: a failed transcription produces no text worth a history row —
    /// raw-audio recovery lives in the capture layer (FR-11.3) — so the
    /// session delivers and saves nothing, surfaces the error here for the
    /// HUD, and returns to idle.
    public private(set) var lastError: TranscriptionError?

    /// The fire-and-forget prewarm task from the latest press; kept so tests
    /// can await its completion deterministically.
    private(set) var prewarmTask: Task<Void, Never>?
    /// The chained processing pipeline for the most recent released take.
    /// Awaiting it drains every queued pipeline (each chains on the previous);
    /// kept so tests — and any caller that must observe delivery — can wait
    /// deterministically.
    private(set) var pipelineTask: Task<Void, Never>?

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

    /// Where the phase lands when no capture is active: `.transcribing` while
    /// pipelines are still in flight, `.idle` otherwise. Callers guarantee no
    /// capture is active (or arming) when they call this.
    private func settleAfterCaptureEnd() {
        transition(to: queuedPipelines > 0 ? .transcribing : .idle)
    }

    /// Pipeline-driven transitions must never stomp a newer capture's phase:
    /// while a press is arming or recording, the capture phases win.
    private func transitionIfNoCaptureActive(_ newPhase: Phase) {
        guard take == nil, phaseValue != .arming else { return }
        transition(to: newPhase)
    }

    // MARK: - Press lifecycle

    /// Hotkey press: start audio capture immediately; profile resolution
    /// (pinned at press, FR-3.6) and the cleanup prewarm run concurrently.
    /// Accepted whenever no capture is active — a previous take may still be
    /// processing (its pipeline runs detached). If audio fails to start there
    /// is nothing to persist; the error lands in `lastError`.
    public func pressBegan() async {
        switch phaseValue {
        case .arming, .recording:
            return
        default:
            break
        }
        lastError = nil
        pendingRelease = nil
        pendingCancel = false
        transition(to: .arming)

        let prewarm = deps.prewarmCleanup
        prewarmTask = Task { await prewarm() }

        // The resolution task starts now, so the frontmost-context snapshot
        // happens at press time; only the await moves to release (docs/03 §2:
        // the microphone must never wait on a browser AppleScript).
        let resolve = deps.profileResolution
        let resolution = Task { await resolve() }

        let pressedAt = clock.now
        do {
            let capture = try await deps.audio.start()
            take = ActiveTake(resolution: resolution, capture: capture, pressedAt: pressedAt)
            transition(to: .recording(startedAt: pressedAt))
            // A release or Escape that arrived while we were suspended in
            // audio start (the .arming window) must not be lost — the mic
            // would run until the next full press cycle.
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
            settleAfterCaptureEnd()
        }
    }

    /// Hotkey release: stop capture and hand the take to the processing
    /// pipeline (transcribe → clean → deliver → save), which runs detached so
    /// the next press is accepted immediately. A release during `.arming` is
    /// latched and honored the moment recording starts.
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
        settleAfterCaptureEnd()
    }

    // MARK: - Release pipeline

    /// Stops capture and queues the processing pipeline. Pipelines chain on
    /// each other so takes deliver in press order even when a new recording
    /// starts before the previous take finished processing.
    ///
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
            settleAfterCaptureEnd()
            return
        }

        let pending = PendingTake(
            resolution: active.resolution,
            audio: audio,
            captureSeconds: captureSeconds,
            isLockMode: isLockMode
        )
        queuedPipelines += 1
        let previous = pipelineTask
        pipelineTask = Task {
            await previous?.value
            await self.runPipeline(pending)
        }
    }

    private func runPipeline(_ pending: PendingTake) async {
        // Usually resolved long before release; worst case (hung browser) the
        // ~1.5 s fetch overlaps recording instead of delaying the microphone.
        let resolved = await pending.resolution.value
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
                pending.audio, languageMode: languageMode, dictionaryTerms: writtenForms
            )
        } catch {
            lastError =
                (error as? TranscriptionError) ?? .engineUnavailable(String(describing: error))
            finishPipeline()
            return
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
        } else if let pipeline = deps.cleanup {
            transitionIfNoCaptureActive(.cleaning)
            // History must record what actually ran (FR-5.1). Only one pipeline
            // is injected today, so a profile's providerOverride is routing
            // intent, not reality — runtime provider selection is a known gap
            // (docs/11).
            let providerID = deps.cleanupProviderID
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

        transitionIfNoCaptureActive(.delivering)
        let context = DeliveryContext(
            pressTimeAppBundleID: resolved.pressTimeBundleID,
            isLockMode: pending.isLockMode,
            formatting: formatting
        )
        let deliveryStart = clock.now
        let delivery = await deps.deliverer.deliver(formatted, context: context)
        let deliverySeconds = Self.seconds(deliveryStart.duration(to: clock.now))

        // FR-3.2: secure input means nothing was inserted and nothing may be
        // persisted — no history row for this take.
        if case .blockedSecureField = delivery {
            finishPipeline()
            return
        }

        var targetBundleID = resolved.pressTimeBundleID
        if case .inserted(_, let appBundleID) = delivery, let appBundleID {
            targetBundleID = appBundleID
        }

        let record = TranscriptRecord(
            createdAt: deps.now(),
            source: .dictation,
            language: language,
            rawText: result.text,
            deliveredText: formatted,
            durationSeconds: pending.audio.durationSeconds,
            targetAppBundleID: targetBundleID,
            profileName: profile.name,
            routeKind: resolved.routeKind,
            cleanup: cleanupOutcome,
            timings: TimingBreakdown(
                captureSeconds: pending.captureSeconds,
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
        finishPipeline()
    }

    /// Pipeline epilogue: settle the display phase unless a newer capture is
    /// active (its phases win until its own release re-queues a pipeline).
    private func finishPipeline() {
        queuedPipelines -= 1
        guard take == nil, phaseValue != .arming else { return }
        settleAfterCaptureEnd()
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
