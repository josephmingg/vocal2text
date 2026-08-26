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
///
/// Processing is decoupled from capture (docs/15 W3): released takes queue
/// onto a pipeline chain that runs detached, in press order, so a new press
/// is accepted while the previous take is still transcribing or cleaning.
/// Capture phases win the displayed phase; an ended capture settles to
/// `.transcribing` while pipelines are in flight and `.idle` otherwise.
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

    /// What press-time routing resolves to; spawned at press, awaited only in
    /// the release pipeline.
    public typealias ResolvedRoute = (
        profile: Profile,
        routeKind: TranscriptRecord.RouteKind,
        pressTimeBundleID: String?
    )

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

    /// Produces the current hypothesis for the audio captured so far (docs/15
    /// step 22 streaming preview), or nil when preview is unavailable for the
    /// current configuration (engine not loaded, route not preview-capable).
    /// Called serially, at most one in flight; must be cheap enough that a
    /// release landing mid-call waits a fraction of a second at worst.
    public typealias PreviewTranscribing = @Sendable (PCMChunk) async -> String?

    /// Preserves a failed take's audio for later recovery (docs/15 step 35):
    /// invoked only when transcription fails, with the exact samples the take
    /// captured — the platform writes them wherever its recovery offer looks.
    public typealias FailedAudioPreserving = @Sendable (PCMChunk) async -> Void

    /// Reads the text immediately before the insertion point at release time
    /// (docs/15 step 29) — the AX caret read on macOS. nil means the platform
    /// cannot see it for this target; the session then falls back to its own
    /// last-insert record, and to fresh-insertion formatting.
    public typealias PrecedingContextReading = @Sendable () async -> String?

    /// Locates the speech inside a finished take (docs/15 step 16, FR-1.5):
    /// returns the padded sample range worth transcribing, or nil when the
    /// take contains no speech at all — the session then delivers nothing
    /// rather than let the engine hallucinate text for silence. An analyzer
    /// that cannot run (model missing, download failed) must return the full
    /// range, never nil: losing VAD must not lose takes.
    public typealias SpeechAnalyzing = @Sendable (PCMChunk) async -> Range<Int>?

    /// Everything a session needs, injected by the composition root.
    public struct Dependencies: Sendable {
        public var audio: any AudioCapturing
        public var engine: any TranscriptionEngine
        /// Stage-3 provider selection, resolved per take.
        public var selectCleanup: CleanupSelecting
        /// Retains the take's audio after delivery; nil keeps nothing.
        public var archiveAudio: AudioArchiving?
        /// VAD gate + trim (docs/15 step 16); nil transcribes the whole take.
        public var analyzeSpeech: SpeechAnalyzing?
        /// Preceding-context read for smart spacing (docs/15 step 29); nil
        /// keeps fresh-insertion formatting everywhere.
        public var readPrecedingContext: PrecedingContextReading?
        /// Failed-take audio preservation (docs/15 step 35); nil discards.
        public var preserveFailedAudio: FailedAudioPreserving?
        /// Streaming preview decode (docs/15 step 22); nil disables preview.
        public var previewTranscribe: PreviewTranscribing?
        /// Receives the prefix-committed preview line for display (FR-4.1:
        /// display-only — the batch pass stays the correctness path).
        public var onPartial: (@Sendable (String) -> Void)?
        /// Cadence of the preview decode loop; tests shorten it.
        public var previewInterval: Duration
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
            analyzeSpeech: SpeechAnalyzing? = nil,
            readPrecedingContext: PrecedingContextReading? = nil,
            preserveFailedAudio: FailedAudioPreserving? = nil,
            previewTranscribe: PreviewTranscribing? = nil,
            onPartial: (@Sendable (String) -> Void)? = nil,
            previewInterval: Duration = .milliseconds(400),
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
                analyzeSpeech: analyzeSpeech,
                readPrecedingContext: readPrecedingContext,
                preserveFailedAudio: preserveFailedAudio,
                previewTranscribe: previewTranscribe,
                onPartial: onPartial,
                previewInterval: previewInterval,
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
            analyzeSpeech: SpeechAnalyzing? = nil,
            readPrecedingContext: PrecedingContextReading? = nil,
            preserveFailedAudio: FailedAudioPreserving? = nil,
            previewTranscribe: PreviewTranscribing? = nil,
            onPartial: (@Sendable (String) -> Void)? = nil,
            previewInterval: Duration = .milliseconds(400),
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
            self.analyzeSpeech = analyzeSpeech
            self.readPrecedingContext = readPrecedingContext
            self.preserveFailedAudio = preserveFailedAudio
            self.previewTranscribe = previewTranscribe
            self.onPartial = onPartial
            self.previewInterval = previewInterval
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
        /// Press → mic open (docs/15 step 47) — speech lost at take start.
        var armSeconds: Double
    }

    /// Everything the detached processing pipeline needs once capture ended.
    private struct PendingTake {
        var resolution: PendingResolution
        var audio: PCMChunk
        var captureSeconds: Double
        var armSeconds: Double
        var isLockMode: Bool
    }

    /// A release edge latched during the `.arming` suspension window.
    private enum PendingRelease {
        case normal(isLockMode: Bool)
        case provisional
    }

    private let deps: Dependencies
    private let clock = ContinuousClock()

    private var phaseValue: Phase = .idle
    private var phaseSubscribers: [UUID: AsyncStream<Phase>.Continuation] = [:]
    private var take: ActiveTake?
    /// Release/cancel edges that arrived during the `.arming` suspension
    /// window; honored the moment recording starts (a lost release would
    /// leave the mic running — NFR-1).
    private var pendingRelease: PendingRelease?
    private var pendingCancel = false
    /// Pipelines queued or running (the live press path and `recover` both
    /// count). Capture phases always win the display; this only decides
    /// whether an ended capture settles to `.transcribing` (work still in
    /// flight) or `.idle`.
    private var queuedPipelines = 0
    /// What this session last inserted, where, and when (docs/15 step 29):
    /// the fallback preceding context for targets AX cannot read.
    private var lastInsertion: (suffix: String, bundleID: String?, at: Date)?

    /// A speech-bearing short-tap take held while the double-tap window is
    /// open (FR-1.5 × FR-1.3, docs/15 W10): the mic is already stopped; the
    /// take is committed if no second tap arrives, discarded if the pair
    /// turned out to be the hands-free lock gesture.
    private var provisionalTake: PendingTake?

    /// The most recent transcription (or capture) failure. Documented v1
    /// choice: a failed transcription produces no text worth a history row —
    /// raw-audio recovery lives in the capture layer (FR-11.3) — so the
    /// session delivers and saves nothing, surfaces the error here for the
    /// HUD, and returns to idle.
    public private(set) var lastError: TranscriptionError?

    /// Timings of the most recently completed (delivered) take, cleared at
    /// each press — the FR-11.4 surface the HUD's latency toast reads.
    public private(set) var lastTimings: TimingBreakdown?

    /// The fire-and-forget prewarm task from the latest press; kept so tests
    /// can await its completion deterministically.
    private(set) var prewarmTask: Task<Void, Never>?
    /// The live streaming-preview loop for the current capture (docs/15
    /// step 22); cancelled the moment capture ends, so a preview decode can
    /// never outlive its take.
    private var previewTask: Task<Void, Never>?
    /// The chained processing pipeline for the most recent released take.
    /// Awaiting it drains every queued pipeline (each chains on the previous);
    /// kept so tests — and any caller that must observe delivery — can wait
    /// deterministically.
    private(set) var pipelineTask: Task<Void, Never>?
    /// The chained post-delivery persistence work (audio archive encode +
    /// history write) for the most recent delivered take (docs/15 step 49).
    /// Neither affects the delivered text, so the session settles to idle
    /// without awaiting them; chaining keeps history rows in press order, and
    /// tests await this to observe saves deterministically.
    private(set) var persistenceTask: Task<Void, Never>?

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

    /// Pipeline epilogue: settle the display phase unless a newer capture is
    /// active (its phases win until its own release re-queues a pipeline).
    private func finishPipeline() {
        queuedPipelines -= 1
        guard take == nil, phaseValue != .arming else { return }
        settleAfterCaptureEnd()
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
        // Accepted whenever no capture is active — a previous take may still
        // be processing on the detached pipeline (docs/15 W3).
        switch phaseValue {
        case .arming, .recording:
            return
        default:
            break
        }
        lastError = nil
        lastTimings = nil
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
                pressedAt: pressedAt,
                armSeconds: Self.seconds(pressedAt.duration(to: clock.now))
            )
            startPreview(chunks: capture.chunks)
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
                switch release {
                case .normal(let isLockMode):
                    await finishPress(isLockMode: isLockMode, heldDurationOverride: nil)
                case .provisional:
                    await finishPress(
                        isLockMode: false, heldDurationOverride: nil, provisional: true
                    )
                }
            }
        } catch {
            take = nil
            pendingRelease = nil
            pendingCancel = false
            resolution.cancel()
            lastError = .audioUnreadable("capture failed to start: \(error)")
            settleAfterCaptureEnd()
        }
    }

    /// Hotkey release: stop capture and run the full pipeline through delivery
    /// and history. A release during `.arming` is latched and honored the
    /// moment recording starts.
    public func pressEnded(isLockMode: Bool = false) async {
        if phaseValue == .arming {
            pendingRelease = .normal(isLockMode: isLockMode)
            return
        }
        await finishPress(isLockMode: isLockMode, heldDurationOverride: nil)
    }

    /// Short-tap release while the double-tap window is still open (docs/15
    /// W10): capture stops now, but a speech-bearing take is held instead of
    /// queued — `commitProvisionalTake` delivers it once the window closes
    /// with no second tap; `discardProvisionalTake` drops it when the pair
    /// turned out to be the hands-free lock gesture, so the first tap of a
    /// double-tap can never paste text before the second tap locks.
    public func pressEndedProvisionally() async {
        if phaseValue == .arming {
            pendingRelease = .provisional
            return
        }
        await finishPress(isLockMode: false, heldDurationOverride: nil, provisional: true)
    }

    /// The double-tap window closed with no second tap: queue the held take.
    public func commitProvisionalTake() async {
        guard let pending = provisionalTake else { return }
        provisionalTake = nil
        queuePipeline(pending)
    }

    /// The tap pair was a lock gesture: the held take is dropped unseen.
    public func discardProvisionalTake() async {
        guard provisionalTake != nil else { return }
        provisionalTake = nil
        guard take == nil, phaseValue != .arming else { return }
        settleAfterCaptureEnd()
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
        stopPreview()
        active.resolution.cancel()
        await active.capture.cancel()
        transition(to: .cancelled)
        settleAfterCaptureEnd()
    }

    // MARK: - Streaming preview (docs/15 step 22)

    /// Consumes the live chunk stream and periodically re-transcribes the
    /// audio captured so far, pushing a prefix-committed line to `onPartial`.
    /// Display-only per FR-4.1: nothing here touches the take's audio path or
    /// the batch pass that produces the delivered text.
    ///
    /// Two children: a reader that drains the stream promptly (the capture
    /// layer's buffer is bounded, so a slow consumer would drop chunks) into
    /// a private accumulator, and a decoder that wakes on `previewInterval`,
    /// re-decodes once at least a second of new audio exists, and commits
    /// the stable prefix so the display never flickers.
    private func startPreview(chunks: AsyncStream<PCMChunk>) {
        guard let preview = deps.previewTranscribe, let onPartial = deps.onPartial else { return }
        let interval = deps.previewInterval
        previewTask = Task {
            let buffer = PreviewSampleBuffer()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await chunk in chunks {
                        await buffer.append(chunk.samples)
                    }
                }
                group.addTask {
                    var committer = PrefixCommitter()
                    var decodedSampleCount = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: interval)
                        if Task.isCancelled { break }
                        let samples = await buffer.snapshot()
                        guard samples.count - decodedSampleCount >= PCMChunk.sampleRate else {
                            continue
                        }
                        decodedSampleCount = samples.count
                        guard
                            let hypothesis = await preview(PCMChunk(samples: samples)),
                            !Task.isCancelled
                        else { continue }
                        let line = committer.ingest(hypothesis)
                        if !line.isEmpty {
                            onPartial(line)
                        }
                    }
                }
                // The reader ends when capture finishes, the decoder on
                // cancellation; whichever ends first releases the other.
                await group.next()
                group.cancelAll()
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    // MARK: - Release pipeline

    /// Stops capture and queues the processing pipeline (docs/15 W3).
    /// Pipelines chain on each other so takes deliver in press order even
    /// when a new recording starts before the previous take finished.
    ///
    /// `heldDurationOverride` is a test seam substituting the measured hold
    /// time in the FR-1.5 accidental-tap check; production always passes nil.
    /// `provisional` holds a speech-bearing take instead of queueing it (see
    /// `pressEndedProvisionally`).
    func finishPress(
        isLockMode: Bool, heldDurationOverride: Duration?, provisional: Bool = false
    ) async {
        guard case .recording(let startedAt) = phaseValue, let active = take else { return }
        take = nil
        stopPreview()
        transition(to: .transcribing)

        let held = heldDurationOverride ?? startedAt.duration(to: clock.now)
        let audio = await active.capture.finish()
        let captureSeconds = Self.seconds(active.pressedAt.duration(to: clock.now))

        // FR-1.5, v1 shape: the session has no VAD, so captured-audio duration
        // stands in for "speech detected" — a sub-500 ms hold is discarded
        // silently only when the audio is also shorter than 500 ms.
        if held < .milliseconds(500), audio.durationSeconds < 0.5 {
            active.resolution.cancel()
            settleAfterCaptureEnd()
            return
        }

        let pending = PendingTake(
            resolution: active.resolution,
            audio: audio,
            captureSeconds: captureSeconds,
            armSeconds: active.armSeconds,
            isLockMode: isLockMode
        )
        if provisional {
            provisionalTake = pending
        } else {
            queuePipeline(pending)
        }
    }

    /// Chains the take onto the detached pipeline; delivery order follows
    /// press order because each pipeline awaits its predecessor.
    private func queuePipeline(_ pending: PendingTake) {
        queuedPipelines += 1
        let previous = pipelineTask
        pipelineTask = Task {
            await previous?.value
            // Join the press-time resolution started in `pressBegan`. It has
            // had the whole utterance to finish, so this is normally already
            // complete; worst case (hung browser) the ~1.5 s fetch overlapped
            // recording instead of delaying the microphone.
            let resolved = await pending.resolution.value
            _ = await self.runPipeline(
                audio: pending.audio,
                resolved: resolved,
                isLockMode: pending.isLockMode,
                captureSeconds: pending.captureSeconds,
                armSeconds: pending.armSeconds,
                source: .dictation
            )
        }
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
        queuedPipelines += 1
        return await runPipeline(
            audio: audio,
            resolved: resolved,
            isLockMode: false,
            captureSeconds: audio.durationSeconds,
            armSeconds: 0,
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
        armSeconds: Double,
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

        // docs/15 step 16: the VAD gate runs inside the transcription timing
        // window — it is part of release-to-text, not free. The engine only
        // hears the padded speech envelope: leading/trailing silence is where
        // decode time is wasted and hallucinations come from. History and the
        // audio archive keep the full take; only the engine's input shrinks.
        let transcriptionStart = clock.now
        var engineAudio = audio
        if let analyze = deps.analyzeSpeech {
            guard let span = await analyze(audio) else {
                // FR-1.5's real answer: no speech in the take, nothing to
                // deliver, and transcribing silence can only invent text.
                // Consumed on purpose — a silent recording is not worth
                // re-offering through recovery.
                finishPipeline()
                return true
            }
            let clamped = span.clamped(to: audio.samples.startIndex..<audio.samples.endIndex)
            if !clamped.isEmpty, clamped.count < audio.samples.count {
                engineAudio = PCMChunk(samples: Array(audio.samples[clamped]))
            }
        }

        let result: TranscriptionResult
        do {
            result = try await deps.engine.transcribe(
                engineAudio, languageMode: languageMode, dictionaryTerms: writtenForms
            )
        } catch {
            lastError =
                (error as? TranscriptionError) ?? .engineUnavailable(String(describing: error))
            Diagnostics.shared.increment(.transcriptionFailures)
            // docs/15 step 35: a failure must leave the recording behind.
            // The capture layer's crash sidecar died with the successful
            // finish(), but the samples are right here — hand them to the
            // platform's recovery store so the menu can offer them back.
            // Recovery re-runs (source == .recovered) skip this: the caller
            // still holds the original file and keeps it on a false return.
            if source == .dictation, let preserve = deps.preserveFailedAudio {
                await preserve(audio)
            }
            finishPipeline()
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
        } else if await cleanupHasNothingToDo(stage2Text, language: language, profile: profile) {
            // docs/15 step 20: no fillers, no correction cues, punctuation
            // already sane, and no profile/style instructions in effect — the
            // model would round-trip the text unchanged, so don't pay the
            // round-trip. Deterministic, and the eval-backed tests on the
            // heuristic keep it honest.
            cleanupOutcome = .skipped(reason: .notNeeded)
        } else if let selection = await deps.selectCleanup(profile) {
            transitionIfNoCaptureActive(.cleaning)
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
                // R5 early-warning signal (docs/07): count what fell back.
                if case .rejectedByValidator = cleanupOutcome {
                    Diagnostics.shared.increment(.cleanupValidatorRejections)
                } else {
                    Diagnostics.shared.increment(.cleanupFailures)
                }
            }
        } else {
            cleanupOutcome = .skipped(reason: .providerUnavailable)
        }

        // docs/15 step 29 (FR-3.3): smart spacing formats against what is
        // actually before the caret. The AX read is ground truth; when it
        // cannot see the target, the session's own last-insert record stands
        // in — same app, within two minutes. Platforms that provide neither
        // keep fresh-insertion formatting.
        var precedingContext: String?
        if formatting.smartSpacing, let read = deps.readPrecedingContext {
            precedingContext = await read()
            if precedingContext == nil,
                let last = lastInsertion,
                last.bundleID != nil,
                last.bundleID == resolved.pressTimeBundleID,
                deps.now().timeIntervalSince(last.at) <= 120 {
                precedingContext = last.suffix
            }
        }
        let formatted = Stage4Formatter.format(
            deliveryText,
            language: language,
            formatting: formatting,
            precedingContext: precedingContext
        )

        transitionIfNoCaptureActive(.delivering)
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
            finishPipeline()
            return true
        }

        var targetBundleID = resolved.pressTimeBundleID
        if case .inserted(_, let appBundleID) = delivery, let appBundleID {
            targetBundleID = appBundleID
        }

        // Remember what landed for the next take's fallback context; a
        // clipboard fallback lands wherever the user pastes, so it clears
        // the record instead of poisoning it.
        if case .inserted = delivery {
            lastInsertion = (String(formatted.suffix(64)), targetBundleID, deps.now())
        } else {
            lastInsertion = nil
        }

        // FR-5.1 (docs/11 G9): retain the audio only for a take that actually
        // landed, and only when the user's retention setting keeps any. The
        // transcript id names the file, so the two are found together.
        let transcriptID = UUID()
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
                armSeconds: armSeconds,
                captureSeconds: captureSeconds,
                transcriptionSeconds: transcriptionSeconds,
                dictionarySeconds: dictionarySeconds,
                cleanupSeconds: cleanupSeconds,
                deliverySeconds: deliverySeconds
            ),
            audioPath: nil
        )
        lastTimings = record.timings
        // The audio archive encode and the history write happen after the
        // session settles (docs/15 step 49): the text already landed, neither
        // changes it, and awaiting an AAC encode here held the next queued
        // take — and the HUD's return to idle — hostage to disk work. Chained
        // so rows land in press order; a failed save must not un-deliver text
        // that already landed (history write errors surface via
        // PersistenceKit, not here).
        let archive = deps.archiveAudio
        let store = deps.store
        let previousPersist = persistenceTask
        persistenceTask = Task {
            await previousPersist?.value
            var record = record
            if let archive {
                record.audioPath = await archive(audio, transcriptID)
            }
            try? await store.save(record)
        }
        finishPipeline()
        return true
    }

    // MARK: - Helpers

    /// The docs/15 step 20 skip gate, in full: the text-level heuristic can
    /// only excuse the model when no instructions give it other work — a
    /// profile TASK prompt or an effective style prompt can rewrite even a
    /// perfectly clean transcript, so their presence always runs stage 3.
    private func cleanupHasNothingToDo(
        _ stage2Text: String, language: Language, profile: Profile
    ) async -> Bool {
        let profilePrompt = profile.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profilePrompt.isEmpty else { return false }
        if !profile.ignoresGlobalStyle {
            let style = await deps.config.globalStylePrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard style.isEmpty else { return false }
        }
        return CleanupSkipHeuristic.canSkip(stage2Text, language: language)
    }

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

/// Accumulates the live capture for the preview decoder (docs/15 step 22).
/// Deliberately separate from the capture layer's own accumulation: the
/// preview must never touch the take's authoritative audio path.
private actor PreviewSampleBuffer {
    private var samples: [Float] = []

    func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    func snapshot() -> [Float] {
        samples
    }
}
