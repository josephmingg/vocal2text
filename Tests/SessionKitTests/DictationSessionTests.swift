import ASRKit
import CleanupKit
import CoreModels
import Foundation
import Testing
@testable import SessionKit

/// Cleanup provider fake: scripts the response and counts calls.
private actor ScriptedCleanupProvider: CleanupProvider {
    enum Script: Sendable {
        /// Respond with the request text uppercased.
        case uppercase
        /// Respond with a fixed string.
        case fixed(String)
    }

    nonisolated let id: CleanupProviderID = .openAICompatible(name: "Scripted")
    nonisolated let leavesDevice = false

    private let script: Script
    private(set) var cleanupCallCount = 0
    private(set) var prewarmCount = 0

    init(script: Script) {
        self.script = script
    }

    func isAvailable() async -> Bool { true }

    func prewarm() async {
        prewarmCount += 1
    }

    func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse {
        cleanupCallCount += 1
        switch script {
        case .uppercase:
            return CleanupResponse(text: request.text.uppercased(), modelName: "scripted-upper")
        case .fixed(let text):
            return CleanupResponse(text: text, modelName: "scripted-fixed")
        }
    }
}

/// Fails the first transcription, then succeeds — the shape of "the model was
/// not loaded yet, and now it is", which is exactly when a user retries a
/// recovered take.
private actor FailThenSucceedEngine: TranscriptionEngine {
    nonisolated let id = "fail-then-succeed"
    nonisolated let displayName = "Fail Then Succeed"

    private let result: TranscriptionResult
    private var calls = 0

    init(result: TranscriptionResult) {
        self.result = result
    }

    func availability(for language: Language) async -> EngineAvailability { .ready }
    func prepare(languageMode: LanguageMode) async throws {}
    func unload() async {}

    func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        calls += 1
        if calls == 1 { throw TranscriptionError.engineUnavailable("model not loaded") }
        return result
    }

    nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        // Unused: the session transcribes on release, never by streaming.
        AsyncThrowingStream<TranscriptionUpdate, Error> { continuation in
            continuation.finish()
        }
    }
}

/// Blocks its first transcription until released, then fails it; later
/// calls succeed — a take that fails while the next one is recording.
private actor GatedFailFirstEngine: TranscriptionEngine {
    nonisolated let id = "gated-fail-first"
    nonisolated let displayName = "Gated Fail First"

    private let result: TranscriptionResult
    private var calls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: TranscriptionResult) {
        self.result = result
    }

    func release() {
        released = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func availability(for language: Language) async -> EngineAvailability { .ready }
    func prepare(languageMode: LanguageMode) async throws {}
    func unload() async {}

    func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        calls += 1
        guard calls == 1 else { return result }
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        throw TranscriptionError.engineUnavailable("first take fails")
    }

    nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream<TranscriptionUpdate, Error> { continuation in
            continuation.finish()
        }
    }
}

/// Records each cleanup request it receives and echoes the text back.
private actor CapturingCleanupProvider: CleanupProvider {
    nonisolated let id: CleanupProviderID = .openAICompatible(name: "Capturing")
    nonisolated let leavesDevice = false
    private(set) var requests: [CleanupRequest] = []

    func isAvailable() async -> Bool { true }
    func prewarm() async {}

    func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse {
        requests.append(request)
        return CleanupResponse(text: request.text, modelName: "capturing")
    }
}

/// Counts reads of the surrounding text, so a test can prove the opt-in gate.
private actor ReadCounter {
    private(set) var count = 0
    func read() -> String? {
        count += 1
        return "We met Siobhan yesterday" + CleanupRequest.cursorMarker
    }
}

/// Collects the commands a session hands to the platform.
private actor CommandSink {
    private(set) var commands: [VoiceCommand] = []
    func receive(_ command: VoiceCommand) { commands.append(command) }
}

/// A session wired for command mode, with a scripted transcript.
private func makeCommandSession(
    transcript: String,
    wakeWord: Bool,
    sink: CommandSink,
    deliverer: RecordingTextDeliverer,
    store: InMemoryStore = InMemoryStore()
) -> DictationSession {
    var dependencies = DictationSession.Dependencies(
        audio: ScriptedAudioCapturing(
            chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
            log: CaptureLog()
        ),
        engine: FakeTranscriptionEngine(
            result: TranscriptionResult(text: transcript, detectedLanguage: .english)
        ),
        deliverer: deliverer,
        store: store,
        config: WakeWordConfig(enabled: wakeWord),
        profileResolution: { (Profile(name: "Default"), .app, "com.example.mail") },
        now: { fixedNow }
    )
    dependencies.handleCommand = { await sink.receive($0) }
    dependencies.captureSelection = { "The meeting moved to Friday." }
    return DictationSession(dependencies: dependencies)
}

private struct WakeWordConfig: SessionConfiguring {
    var enabled: Bool
    var cleanupMasterSwitch: Bool { get async { false } }
    var globalLanguageMode: LanguageMode { get async { .auto } }
    var globalStylePrompt: String { get async { "" } }
    var cleanupTimeout: Duration { get async { .seconds(5) } }
    var wakeWordCommandsEnabled: Bool { get async { enabled } }
    func enabledDictionaryEntries() async -> [DictionaryEntry] { [] }
}

private let fixedNow = Date(timeIntervalSince1970: 1_723_000_000)

/// One-shot latch for scripting suspension points (e.g. a profile resolution
/// that must not have completed before the microphone started).
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct Harness {
    let session: DictationSession
    let engine: FakeTranscriptionEngine
    let deliverer: RecordingTextDeliverer
    let store: InMemoryStore
    let captureLog: CaptureLog

    /// Delivery/save now happen on the detached pipeline (chained per take);
    /// awaiting the latest pipeline task drains every queued take.
    func drainPipeline() async {
        if let task = await session.pipelineTask {
            await task.value
        }
        // The archive + history write settle after the pipeline (docs/15
        // step 49); tests that assert on saved records must see them land.
        if let task = await session.persistenceTask {
            await task.value
        }
    }
}

private func makeHarness(
    engineResult: TranscriptionResult = TranscriptionResult(
        text: "let's meet on saturday", detectedLanguage: .english
    ),
    engineFailure: TranscriptionError? = nil,
    engineDelay: Duration = .zero,
    audioSeconds: Double = 2.0,
    profile: Profile = Profile(name: "Default"),
    config: StaticConfig = StaticConfig(),
    cleanup: CleanupPipeline? = nil,
    cleanupProviderID: CleanupProviderID = .ollama(model: "qwen2.5"),
    /// Per-take provider selection. Defaults to the fixed `cleanup` pipeline,
    /// so existing tests read unchanged.
    selectCleanup: DictationSession.CleanupSelecting? = nil,
    prewarm: @escaping @Sendable () async -> Void = {},
    deliveryOutcome: DeliveryOutcome = .inserted(method: .paste, appBundleID: "com.example.notes"),
    profileResolution: (@Sendable () async -> DictationSession.ResolvedRoute)? = nil,
    analyzeSpeech: DictationSession.SpeechAnalyzing? = nil,
    readPrecedingContext: DictationSession.PrecedingContextReading? = nil,
    preserveFailedAudio: DictationSession.FailedAudioPreserving? = nil
) -> Harness {
    let captureLog = CaptureLog()
    let sampleCount = max(0, Int(audioSeconds * Double(PCMChunk.sampleRate)))
    let audio = ScriptedAudioCapturing(
        chunk: PCMChunk(samples: [Float](repeating: 0, count: sampleCount)),
        log: captureLog
    )
    let engine = FakeTranscriptionEngine(
        result: engineResult, delay: engineDelay, failure: engineFailure
    )
    let deliverer = RecordingTextDeliverer(outcome: deliveryOutcome)
    let store = InMemoryStore()
    let dependencies = DictationSession.Dependencies(
        audio: audio,
        engine: engine,
        selectCleanup: selectCleanup
            ?? { _ in
                cleanup.map {
                    DictationSession.CleanupSelection(
                        pipeline: $0, providerID: cleanupProviderID, leavesDevice: false
                    )
                }
            },
        analyzeSpeech: analyzeSpeech,
        readPrecedingContext: readPrecedingContext,
        preserveFailedAudio: preserveFailedAudio,
        prewarmCleanup: prewarm,
        deliverer: deliverer,
        store: store,
        config: config,
        profileResolution: profileResolution ?? { (profile, .app, "com.example.pressapp") },
        now: { fixedNow }
    )
    return Harness(
        session: DictationSession(dependencies: dependencies),
        engine: engine,
        deliverer: deliverer,
        store: store,
        captureLog: captureLog
    )
}

private func phaseLabel(_ phase: DictationSession.Phase) -> String {
    switch phase {
    case .idle: "idle"
    case .arming: "arming"
    case .recording: "recording"
    case .transcribing: "transcribing"
    case .cleaning: "cleaning"
    case .delivering: "delivering"
    case .cancelled: "cancelled"
    }
}

/// Collects the buffered phase labels from a subscription, stopping at the
/// first return to idle after the initial snapshot.
private func drainPhases(_ stream: AsyncStream<DictationSession.Phase>) async -> [String] {
    var labels: [String] = []
    for await phase in stream {
        labels.append(phaseLabel(phase))
        if labels.count > 1, phase == .idle { break }
    }
    return labels
}

struct DictationSessionTests {

    @Test func happyPathDeliversFormattedTextAndSavesRecord() async throws {
        let harness = makeHarness()
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        // Stage 1 capitalizes and adds the terminal period; stages 2/4 are
        // no-ops here (no entries, fresh insertion point).
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])

        let contexts = await harness.deliverer.contexts
        #expect(contexts.first?.pressTimeAppBundleID == "com.example.pressapp")
        #expect(contexts.first?.isLockMode == false)

        let records = await harness.store.records
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.source == .dictation)
        #expect(record.language == .english)
        #expect(record.rawText == "let's meet on saturday")
        #expect(record.deliveredText == "Let's meet on saturday.")
        #expect(record.durationSeconds == 2.0)
        #expect(record.profileName == "Default")
        #expect(record.routeKind == .app)
        #expect(record.targetAppBundleID == "com.example.notes")
        #expect(record.createdAt == fixedNow)
        #expect(record.cleanup == .skipped(reason: .masterSwitchOff))
        #expect(record.timings.captureSeconds >= 0)
        #expect(record.timings.transcriptionSeconds >= 0)
        #expect(record.timings.dictionarySeconds >= 0)
        #expect(record.timings.cleanupSeconds == 0)
        #expect(record.timings.deliverySeconds >= 0)

        let phase = await harness.session.phase
        #expect(phase == .idle)
    }

    @Test func phasesStreamObservesFullLifecycle() async {
        let harness = makeHarness()
        let stream = await harness.session.phases
        await harness.session.pressBegan()
        await harness.session.finishPress(isLockMode: false, heldDurationOverride: .seconds(1))

        let labels = await drainPhases(stream)
        #expect(labels == ["idle", "arming", "recording", "transcribing", "delivering", "idle"])
    }

    @Test func accidentalTapDeliversNothingAndSavesNothing() async {
        let harness = makeHarness(audioSeconds: 0.2)
        await harness.session.pressBegan()
        await harness.session.finishPress(
            isLockMode: false, heldDurationOverride: .milliseconds(200)
        )
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.isEmpty)
        let records = await harness.store.records
        #expect(records.isEmpty)
        let transcribeCount = await harness.engine.transcribeCount
        #expect(transcribeCount == 0)
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }

    @Test func shortHoldWithLongAudioStillTranscribes() async {
        // FR-1.5's "unless speech was detected" branch, via the v1 duration proxy.
        let harness = makeHarness(audioSeconds: 2.0)
        await harness.session.pressBegan()
        await harness.session.finishPress(
            isLockMode: false, heldDurationOverride: .milliseconds(200)
        )
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])
    }

    @Test func cancelSavesNothingAndReturnsToIdle() async {
        let harness = makeHarness()
        let stream = await harness.session.phases
        await harness.session.pressBegan()
        await harness.session.cancel()

        let cancelCount = await harness.captureLog.cancelCount
        #expect(cancelCount == 1)
        let finishCount = await harness.captureLog.finishCount
        #expect(finishCount == 0)
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.isEmpty)
        let records = await harness.store.records
        #expect(records.isEmpty)

        let labels = await drainPhases(stream)
        #expect(labels == ["idle", "arming", "recording", "cancelled", "idle"])

        // A release after cancel is a no-op.
        await harness.session.pressEnded()
        let recordsAfter = await harness.store.records
        #expect(recordsAfter.isEmpty)
    }

    @Test func engineFailureSavesNothingAndExposesLastError() async {
        let harness = makeHarness(engineFailure: .modelNotInstalled)
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.isEmpty)
        let records = await harness.store.records
        #expect(records.isEmpty)
        let lastError = await harness.session.lastError
        #expect(lastError == .modelNotInstalled)
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }

    @Test func cleanupAppliedDeliversCleanedTextAndFiresPrewarm() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            // The TASK prompt keeps the step-20 skip heuristic out of this
            // test's way: with instructions in effect, stage 3 always runs.
            profile: Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider),
            prewarm: { await provider.prewarm() }
        )
        let stream = await harness.session.phases
        await harness.session.pressBegan()
        if let task = await harness.session.prewarmTask {
            await task.value
        }
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let prewarmCount = await provider.prewarmCount
        #expect(prewarmCount == 1)
        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 1)

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["MEET ON SATURDAY."])

        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.deliveredText == "MEET ON SATURDAY.")
        #expect(record.rawText == "meet on saturday")
        #expect(record.cleanup == .applied(provider: .ollama(model: "qwen2.5"), model: "scripted-upper"))
        #expect(record.timings.cleanupSeconds >= 0)

        let labels = await drainPhases(stream)
        #expect(
            labels == ["idle", "arming", "recording", "transcribing", "cleaning", "delivering", "idle"]
        )
    }

    // MARK: - Per-take provider selection (docs/11 G3, G15)

    @Test func cleanupProviderIsSelectedPerTakeFromThePinnedProfile() async throws {
        // The selector runs once per take and sees the take's profile, so a
        // profile override picks the provider (G3) and a settings change
        // applies on the next dictation instead of the next launch (G15).
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let seen = ProfileRecorder()
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(
                name: "Notes",
                cleanupEnabled: true,
                promptText: "Tidy this.",
                providerOverride: .ollama(model: "sailor2:8b")
            ),
            config: StaticConfig(masterSwitch: true),
            selectCleanup: { profile in
                await seen.record(profile)
                // What the Mac app does: build from the profile's override,
                // falling back to the global model when it names none.
                guard case .ollama(let model)? = profile.providerOverride else {
                    return DictationSession.CleanupSelection(
                        pipeline: CleanupPipeline(provider: provider),
                        providerID: .ollama(model: "global-default"),
                        leavesDevice: false
                    )
                }
                return DictationSession.CleanupSelection(
                    pipeline: CleanupPipeline(provider: provider),
                    providerID: .ollama(model: model),
                    leavesDevice: false
                )
            }
        )

        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let profiles = await seen.profiles
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Notes")
        // History records the overridden provider, not a launch-time default.
        let record = try #require(await harness.store.records.first)
        #expect(
            record.cleanup
                == .applied(provider: .ollama(model: "sailor2:8b"), model: "scripted-upper")
        )
    }

    @Test func theSelectorIsNotConsultedWhenCleanupIsGatedOff() async throws {
        // Master switch off: no provider is built at all, so a take costs
        // nothing even when the endpoint is misconfigured.
        let seen = ProfileRecorder()
        let harness = makeHarness(
            profile: Profile(name: "Notes", cleanupEnabled: true),
            config: StaticConfig(masterSwitch: false),
            selectCleanup: { profile in
                await seen.record(profile)
                return nil
            }
        )

        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        #expect(await seen.profiles.isEmpty)
        let record = try #require(await harness.store.records.first)
        #expect(record.cleanup == .skipped(reason: .masterSwitchOff))
    }

    @Test func aNilSelectionRecordsProviderUnavailableAndStillDelivers() async throws {
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."),
            config: StaticConfig(masterSwitch: true),
            selectCleanup: { _ in nil }
        )

        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let record = try #require(await harness.store.records.first)
        #expect(record.cleanup == .skipped(reason: .providerUnavailable))
        // A missing provider is never a reason to lose the take (FR-7.3).
        #expect(await harness.deliverer.deliveredTexts == ["Meet on saturday."])
    }

    @Test func validatorRejectionFallsBackToStage2Text() async throws {
        // "Here is…" trips the output validator's meta-text rule, so the
        // session must deliver the stage-2 text (FR-7.3) and log the rejection.
        let provider = ScriptedCleanupProvider(
            script: .fixed("Here is your cleaned text: Meet on saturday.")
        )
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Meet on saturday."])

        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(
            record.cleanup
                == .rejectedByValidator(provider: .ollama(model: "qwen2.5"), rule: "meta-text")
        )
    }

    @Test func masterSwitchOffNeverCallsProvider() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true),
            config: StaticConfig(masterSwitch: false),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 0)

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Meet on saturday."])

        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.cleanup == .skipped(reason: .masterSwitchOff))
    }

    @Test func profileDisabledSkipsCleanup() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(name: "Terminal", cleanupEnabled: false),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 0)

        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.cleanup == .skipped(reason: .profileDisabled))
    }

    @Test func aCleanTakeSkipsTheModelEntirely() async throws {
        // docs/15 step 20: no fillers, no correction cues, punctuation sane,
        // no instructions — the model would round-trip the text unchanged,
        // so the session never even builds a provider.
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 0)
        let record = try #require(await harness.store.records.first)
        #expect(record.cleanup == .skipped(reason: .notNeeded))
        // The deterministic stages still ran.
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Meet on saturday."])
    }

    /// A misheard word ("rose your ideas") looks clean to every deterministic
    /// check, so users who opt into context repair must reach the model.
    @Test func aCleanTakeRunsTheModelWhenContextRepairIsOn() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        var config = StaticConfig(masterSwitch: true)
        config.runsOnCleanTakes = true
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "rose your ideas", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true),
            config: config,
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 1)
    }

    @Test func theCleanupBudgetGrowsWithTheTakeAndStaysBounded() {
        let base = Duration.seconds(6)
        #expect(DictationSession.cleanupBudget(base: base, characterCount: 0) == base)
        #expect(DictationSession.cleanupBudget(base: base, characterCount: 500) == .seconds(11))
        #expect(DictationSession.cleanupBudget(base: base, characterCount: 50_000) == .seconds(20))
        #expect(DictationSession.cleanupBudget(base: .zero, characterCount: 500) == .zero)
    }

    @Test func aFillerBearingTakeStillRunsTheModel() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(
                // "um" no longer counts: stage 1 removes it deterministically
                // before the heuristic looks. Hedges stay with the model.
                text: "basically meet on saturday", detectedLanguage: .english
            ),
            profile: Profile(name: "Notes", cleanupEnabled: true),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 1)
    }

    // MARK: - Failed-take audio preservation (docs/15 step 35)

    @Test func aTranscriptionFailurePreservesTheAudio() async throws {
        let preserved = LockedStrings()
        let harness = makeHarness(
            engineFailure: .engineUnavailable("model missing"),
            preserveFailedAudio: { audio in
                preserved.append("\(audio.samples.count)")
            }
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        // The 2 s take's exact samples reached the preservation seam.
        #expect(preserved.snapshot() == ["\(2 * PCMChunk.sampleRate)"])
        let error = await harness.session.lastError
        #expect(error != nil)
    }

    @Test func aSuccessfulTakePreservesNothing() async throws {
        let preserved = LockedStrings()
        let harness = makeHarness(
            preserveFailedAudio: { _ in preserved.append("called") }
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        #expect(preserved.snapshot().isEmpty)
    }

    // MARK: - Preceding context (docs/15 step 29, FR-3.3)

    @Test func smartSpacingFormatsAgainstTheReadContext() async throws {
        // The platform can see "Done." before the caret: the new sentence
        // arrives space-prefixed instead of gluing onto the period.
        let harness = makeHarness(readPrecedingContext: { "Done." })
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == [" Let's meet on saturday."])
    }

    @Test func theLastInsertRecordStandsInWhenAXCannotSee() async throws {
        // Same app, seconds apart, AX blind: the session's own record of what
        // it just inserted provides the context. The delivery target must
        // match the next press's frontmost app for the record to apply.
        let harness = makeHarness(
            deliveryOutcome: .inserted(method: .paste, appBundleID: "com.example.pressapp"),
            readPrecedingContext: { nil }
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.count == 2)
        #expect(delivered.first == "Let's meet on saturday.")
        #expect(delivered.last == " Let's meet on saturday.")
    }

    @Test func noContextSeamMeansFreshInsertionFormatting() async throws {
        // Platforms that provide no reader (iOS today, every existing test)
        // keep the exact old behavior.
        let harness = makeHarness()
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday.", "Let's meet on saturday."])
    }

    // MARK: - Streaming preview (docs/15 step 22)

    @Test func streamingPreviewCommitsThePrefixAcrossHypotheses() async throws {
        // The preview loop consumes the live chunk stream, re-decodes once at
        // least a second of new audio exists, and displays a prefix-committed
        // line — while the take's own batch path stays untouched.
        let feed = ChunkFeed()
        let partials = LockedStrings()
        let script = ScriptedHypotheses(["hello there", "hello there friend"])

        let deliverer = RecordingTextDeliverer()
        let store = InMemoryStore()
        let session = DictationSession(
            dependencies: DictationSession.Dependencies(
                audio: StreamingAudioCapturing(
                    finishChunk: PCMChunk(
                        samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)
                    ),
                    feed: feed
                ),
                engine: FakeTranscriptionEngine(
                    result: TranscriptionResult(
                        text: "hello there friend", detectedLanguage: .english
                    )
                ),
                previewTranscribe: { _ in await script.nextResult() },
                onPartial: { partials.append($0) },
                previewInterval: .milliseconds(10),
                deliverer: deliverer,
                store: store,
                config: StaticConfig(),
                profileResolution: { (Profile(name: "Default"), .app, "com.example.pressapp") },
                now: { fixedNow }
            )
        )

        await session.pressBegan()
        let second = PCMChunk(samples: [Float](repeating: 0, count: PCMChunk.sampleRate))
        await feed.push(second)
        try await waitUntil("first partial") { partials.snapshot().count >= 1 }
        await feed.push(second)
        try await waitUntil("second partial") { partials.snapshot().count >= 2 }

        await session.pressEnded()
        if let task = await session.pipelineTask { await task.value }
        if let task = await session.persistenceTask { await task.value }

        let seen = partials.snapshot()
        // First hypothesis: nothing agreed yet, all tail. Second: the shared
        // prefix committed, the new word rides as tail.
        #expect(seen.first == "hello there")
        #expect(seen.contains("hello there friend"))
        // The batch path delivered normally, independent of the preview.
        let delivered = await deliverer.deliveredTexts
        #expect(delivered == ["Hello there friend."])
    }

    @Test func previewStopsWhenCaptureEnds() async throws {
        let feed = ChunkFeed()
        let partials = LockedStrings()
        let script = ScriptedHypotheses(["hello"])
        let session = DictationSession(
            dependencies: DictationSession.Dependencies(
                audio: StreamingAudioCapturing(
                    finishChunk: PCMChunk(
                        samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)
                    ),
                    feed: feed
                ),
                engine: FakeTranscriptionEngine(
                    result: TranscriptionResult(text: "hello", detectedLanguage: .english)
                ),
                previewTranscribe: { _ in await script.nextResult() },
                onPartial: { partials.append($0) },
                previewInterval: .milliseconds(10),
                deliverer: RecordingTextDeliverer(),
                store: InMemoryStore(),
                config: StaticConfig(),
                profileResolution: { (Profile(name: "Default"), .app, "com.example.pressapp") },
                now: { fixedNow }
            )
        )

        await session.pressBegan()
        await session.pressEnded()
        if let task = await session.pipelineTask { await task.value }
        // Push audio after the take ended: the loop is cancelled, so no
        // partial may surface for it.
        await feed.push(PCMChunk(samples: [Float](repeating: 0, count: PCMChunk.sampleRate)))
        try await Task.sleep(for: .milliseconds(60))
        #expect(partials.snapshot().isEmpty)
    }

    @Test func previewDecodesATrailingWindowNotTheWholeTake() async throws {
        // docs/17 G2.3: a long take must not re-decode everything said so
        // far. With a 3 s window that keeps 1 s, every decode stays near the
        // window size however long the take runs, and the frozen words stay
        // on screen ahead of the window.
        let feed = ChunkFeed()
        let partials = LockedStrings()
        let decodedLengths = DecodedLengths()

        var dependencies = DictationSession.Dependencies(
            audio: StreamingAudioCapturing(
                finishChunk: PCMChunk(
                    samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)
                ),
                feed: feed
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "done", detectedLanguage: .english)
            ),
            previewTranscribe: { chunk in
                await decodedLengths.record(chunk.samples.count)
                // A word every half second, all agreeing, with timings
                // relative to the chunk like a real engine reports them.
                let count = Int(chunk.durationSeconds / 0.5)
                let words = (0..<count).map {
                    TranscriptionResult.TimedSegment(
                        text: "word", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4
                    )
                }
                return TranscriptionResult(
                    text: words.map(\.text).joined(separator: " "),
                    detectedLanguage: .english,
                    segments: words
                )
            },
            onPartial: { partials.append($0) },
            previewInterval: .milliseconds(5),
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(),
            profileResolution: { (Profile(name: "Default"), .app, "com.example.pressapp") },
            now: { fixedNow }
        )
        dependencies.previewWindow = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        let session = DictationSession(dependencies: dependencies)

        await session.pressBegan()
        let second = PCMChunk(samples: [Float](repeating: 0, count: PCMChunk.sampleRate))
        let seconds = 12
        for pushed in 1...seconds {
            await feed.push(second)
            try await waitUntil("partial for second \(pushed)") {
                partials.snapshot().count >= pushed
            }
        }
        await session.pressEnded()
        if let task = await session.pipelineTask { await task.value }

        let lengths = await decodedLengths.values
        #expect(lengths.count == seconds)
        // Never more than the window plus the second that arrived since.
        #expect(lengths.allSatisfy { $0 <= 4 * PCMChunk.sampleRate })
        #expect((lengths.last ?? .max) < seconds * PCMChunk.sampleRate)
        // Frozen words stay on screen: the line holds more words than any
        // single window could.
        let lastLine = partials.snapshot().last ?? ""
        let shownWords = lastLine.split(separator: " ").count
        #expect(shownWords > 8)
    }

    // MARK: - VAD gate + trim (docs/15 step 16)

    @Test func aSilentTakeDeliversAndSavesNothing() async throws {
        // FR-1.5's real has-speech answer: the analyzer found no speech, so
        // the engine never runs — transcribing silence can only hallucinate.
        let harness = makeHarness(analyzeSpeech: { _ in nil })
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let transcribeCount = await harness.engine.transcribeCount
        #expect(transcribeCount == 0)
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.isEmpty)
        let records = await harness.store.records
        #expect(records.isEmpty)
        // Not an error: nothing was said, so nothing happening is correct.
        let error = await harness.session.lastError
        #expect(error == nil)
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }

    @Test func theEngineOnlyHearsTheSpeechSpan() async throws {
        // 2 s take, speech span covering the middle half: the engine's input
        // shrinks, the delivered text and history are untouched, and history
        // still records the full take's duration.
        let totalSamples = 2 * PCMChunk.sampleRate
        let span = (totalSamples / 4)..<(3 * totalSamples / 4)
        let harness = makeHarness(analyzeSpeech: { _ in span })
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let heard = await harness.engine.lastAudioSampleCount
        #expect(heard == span.count)
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])
        let record = try #require(await harness.store.records.first)
        #expect(abs(record.durationSeconds - 2.0) < 0.01)
    }

    @Test func anUnavailableAnalyzerFallsBackToTheFullTake() async throws {
        // The analyzer's "cannot run" contract is the full range — the take
        // must be transcribed whole, never dropped.
        let harness = makeHarness(analyzeSpeech: { audio in audio.samples.indices })
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let heard = await harness.engine.lastAudioSampleCount
        #expect(heard == 2 * PCMChunk.sampleRate)
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])
    }

    @Test func dictionaryEntryAppearsInDeliveredText() async {
        let entry = DictionaryEntry(spoken: "cloud code", written: "Claude Code")
        let harness = makeHarness(
            engineResult: TranscriptionResult(
                text: "use cloud code to review", detectedLanguage: .english
            ),
            config: StaticConfig(entries: [entry])
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Use Claude Code to review."])

        // Written forms also flow to the engine as biasing terms.
        let terms = await harness.engine.lastDictionaryTerms
        #expect(terms == ["Claude Code"])
    }

    /// docs/17 F5: a whole-take snippet delivers its written form verbatim —
    /// no cleanup call, no stage-4 reshaping — and never biases the engine.
    @Test func wholeTakeSnippetDeliversVerbatimAndSkipsCleanup() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let snippet = DictionaryEntry(spoken: "sign off", written: "Best,\nJoseph")
        let fix = DictionaryEntry(spoken: "cloud code", written: "Claude Code")
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "Sign off.", detectedLanguage: .english),
            profile: Profile(name: "Email", cleanupEnabled: true, promptText: "Tidy this."),
            config: StaticConfig(masterSwitch: true, entries: [snippet, fix]),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Best,\nJoseph"])
        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 0)
        let terms = await harness.engine.lastDictionaryTerms
        #expect(terms == ["Claude Code"])
        let record = try #require(await harness.store.records.first)
        #expect(record.cleanup == .skipped(reason: .notNeeded))
    }

    /// docs/17 §11: the clipboard a snippet pastes is delivered but never
    /// written to History — it is often a password copied a moment ago.
    @Test func aClipboardSnippetKeepsTheClipboardOutOfHistory() async throws {
        let snippet = DictionaryEntry(spoken: "paste it", written: "Token: {clipboard}", snippet: true)
        let deliverer = RecordingTextDeliverer()
        let store = InMemoryStore()
        var dependencies = DictationSession.Dependencies(
            audio: ScriptedAudioCapturing(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate))
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "Paste it.", detectedLanguage: .english)
            ),
            deliverer: deliverer,
            store: store,
            config: StaticConfig(entries: [snippet]),
            profileResolution: { (Profile(name: "Default"), .app, "com.example.notes") },
            now: { fixedNow }
        )
        dependencies.readClipboard = { "hunter2-PASSWORD" }
        let session = DictationSession(dependencies: dependencies)
        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }
        if let persistence = await session.persistenceTask { await persistence.value }

        #expect(await deliverer.deliveredTexts == ["Token: hunter2-PASSWORD"])
        let record = try #require(await store.records.first)
        #expect(record.deliveredText == "Token: [clipboard]")
        #expect(!record.deliveredText.contains("hunter2"))
    }

    /// docs/17 §11: the context reader is told which app the take was spoken
    /// in, so a queued take never reads whatever app is frontmost later.
    @Test func surroundingTextIsReadForThePressTimeApp() async throws {
        let provider = CapturingCleanupProvider()
        let apps = LockedStrings()
        var dependencies = DictationSession.Dependencies(
            audio: ScriptedAudioCapturing(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate))
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "and she said yes", detectedLanguage: .english)
            ),
            selectCleanup: { _ in
                DictationSession.CleanupSelection(
                    pipeline: CleanupPipeline(provider: provider),
                    providerID: .ollama(model: "local"),
                    leavesDevice: false
                )
            },
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(masterSwitch: true, usesSurroundingText: true),
            profileResolution: {
                (Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."), .app, "com.example.notes")
            },
            now: { fixedNow }
        )
        dependencies.readSurroundingContext = { app in
            apps.append(app ?? "nil")
            return nil
        }
        let session = DictationSession(dependencies: dependencies)
        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }
        #expect(apps.snapshot() == ["com.example.notes"])
    }

    @Test func snippetPhraseInsideASentenceStaysProse() async {
        let snippet = DictionaryEntry(spoken: "sign off", written: "Best,\nJoseph")
        let harness = makeHarness(
            engineResult: TranscriptionResult(
                text: "please sign off on the budget", detectedLanguage: .english
            ),
            config: StaticConfig(entries: [snippet])
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Please sign off on the budget."])
    }

    // MARK: - docs/17 §5 styles and G3.2 context

    @Test func rawStyleDeliversTheRecognizerTextAndSkipsCleanup() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "um so the the plan works", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."),
            config: StaticConfig(masterSwitch: true, style: .raw),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        // Verbatim: no filler removal, no capital, no full stop, no model.
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["um so the the plan works"])
        let calls = await provider.cleanupCallCount
        #expect(calls == 0)
        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.cleanup == .skipped(reason: .rawStyle))
    }

    @Test func lowercaseStyleRestylesTheDeliveredText() async {
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "Sounds good to me", detectedLanguage: .english),
            config: StaticConfig(style: .lowercase)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["sounds good to me"])
    }

    @Test func profilesThatIgnoreTheGlobalStyleAreUntouched() async {
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "git status", detectedLanguage: .english),
            profile: Profile(name: "Terminal", formatting: .verbatim, ignoresGlobalStyle: true),
            config: StaticConfig(style: .lowercase)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["git status"])
    }

    @Test(arguments: [false, true])
    func surroundingTextIsReadOnlyWhenTheUserOptedIn(optedIn: Bool) async throws {
        let provider = CapturingCleanupProvider()
        let counter = ReadCounter()
        var dependencies = DictationSession.Dependencies(
            audio: ScriptedAudioCapturing(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
                log: CaptureLog()
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "and she said yes", detectedLanguage: .english)
            ),
            selectCleanup: { _ in
                DictationSession.CleanupSelection(
                    pipeline: CleanupPipeline(provider: provider),
                    providerID: .ollama(model: "local"),
                    leavesDevice: false
                )
            },
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(masterSwitch: true, usesSurroundingText: optedIn),
            profileResolution: {
                (Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."), .app, "com.example.notes")
            },
            now: { fixedNow }
        )
        dependencies.readSurroundingContext = { _ in await counter.read() }
        let session = DictationSession(dependencies: dependencies)

        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask {
            await pipeline.value
        }

        let reads = await counter.count
        #expect(reads == (optedIn ? 1 : 0))
        let requests = await provider.requests
        let request = try #require(requests.first)
        #expect(request.context == (optedIn ? "We met Siobhan yesterday" + CleanupRequest.cursorMarker : ""))
    }

    // MARK: - docs/17 G4 command mode

    @Test func aCommandKeyTakeGoesToTheHandlerWithThePressTimeSelection() async throws {
        let sink = CommandSink()
        let deliverer = RecordingTextDeliverer()
        let store = InMemoryStore()
        let session = makeCommandSession(
            transcript: "make this shorter", wakeWord: false, sink: sink, deliverer: deliverer, store: store
        )
        await session.pressBegan(kind: .command)
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }

        let commands = await sink.commands
        let command = try #require(commands.first)
        #expect(command.instruction == "Make this shorter.")
        #expect(command.selectedText == "The meeting moved to Friday.")
        #expect(command.pressTimeBundleID == "com.example.mail")
        #expect(!command.viaWakeWord)
        // Nothing typed, nothing saved — the preview owns the result.
        let delivered = await deliverer.deliveredTexts
        #expect(delivered.isEmpty)
        let records = await store.records
        #expect(records.isEmpty)
    }

    @Test(arguments: [true, false])
    func theWakeWordTurnsADictationIntoACommandOnlyWhenEnabled(enabled: Bool) async {
        let sink = CommandSink()
        let deliverer = RecordingTextDeliverer()
        let session = makeCommandSession(
            transcript: "Vocal, make this shorter.", wakeWord: enabled, sink: sink, deliverer: deliverer
        )
        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }

        let commands = await sink.commands
        let delivered = await deliverer.deliveredTexts
        if enabled {
            #expect(commands.map(\.instruction) == ["Make this shorter."])
            #expect(commands.first?.viaWakeWord == true)
            #expect(delivered.isEmpty)
        } else {
            #expect(commands.isEmpty)
            #expect(delivered == ["Vocal, make this shorter."])
        }
    }

    @Test func anOrdinaryDictationIsTypedEvenWithTheWakeWordOn() async {
        let sink = CommandSink()
        let deliverer = RecordingTextDeliverer()
        let session = makeCommandSession(
            transcript: "Vocal cords need rest", wakeWord: true, sink: sink, deliverer: deliverer
        )
        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }
        let commands = await sink.commands
        #expect(commands.isEmpty)
        let delivered = await deliverer.deliveredTexts
        #expect(delivered == ["Vocal cords need rest."])
    }

    /// docs/17 review #1: the opt-in context never goes to a provider that
    /// sends text off the device, even with the setting on.
    @Test func surroundingTextIsNeverReadForARemoteProvider() async throws {
        let provider = CapturingCleanupProvider()
        let counter = ReadCounter()
        var dependencies = DictationSession.Dependencies(
            audio: ScriptedAudioCapturing(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
                log: CaptureLog()
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "and she said yes", detectedLanguage: .english)
            ),
            selectCleanup: { _ in
                DictationSession.CleanupSelection(
                    pipeline: CleanupPipeline(provider: provider),
                    providerID: .openAICompatible(name: "remote.example.com"),
                    leavesDevice: true
                )
            },
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(masterSwitch: true, usesSurroundingText: true),
            profileResolution: {
                (Profile(name: "Notes", cleanupEnabled: true, promptText: "Tidy this."), .app, "com.example.notes")
            },
            now: { fixedNow }
        )
        dependencies.readSurroundingContext = { _ in await counter.read() }
        let session = DictationSession(dependencies: dependencies)
        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }

        let reads = await counter.count
        #expect(reads == 0)
        let requests = await provider.requests
        #expect(requests.first?.context == "")
    }

    /// docs/17 §11: a *cancelled* command — Escape, sleep, a chord — deletes
    /// its recording instead of leaving it for "Recover"; a cancelled
    /// dictation keeps it (FR-1.6).
    @Test func aCancelledCommandDiscardsItsRecordingButADictationKeepsIt() async {
        let log = CaptureLog()
        var dependencies = DictationSession.Dependencies(
            audio: ScriptedAudioCapturing(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
                log: log
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "x", detectedLanguage: .english)
            ),
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(),
            profileResolution: { (Profile(name: "Default"), .app, "com.example.notes") },
            now: { fixedNow }
        )
        dependencies.handleCommand = { _ in }
        let session = DictationSession(dependencies: dependencies)
        await session.pressBegan(kind: .command)
        await session.cancel()
        #expect(await log.discardCount == 1)
        #expect(await log.cancelCount == 0)

        await session.pressBegan()
        await session.cancel()
        #expect(await log.discardCount == 1)
        #expect(await log.cancelCount == 1)
    }

    /// docs/17 §11: an older take's pipeline starting late must not erase a
    /// newer press's own failure before the platform has shown it.
    @Test func anOlderPipelineDoesNotEraseANewerPressFailure() async throws {
        let release = CaptureGate()
        var dependencies = DictationSession.Dependencies(
            audio: FailingThirdStartAudio(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate))
            ),
            engine: GatedEngine(gate: release),
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(),
            profileResolution: { (Profile(name: "Default"), .app, "com.example.notes") },
            now: { fixedNow }
        )
        dependencies.handleCommand = nil
        let session = DictationSession(dependencies: dependencies)
        // Take Z: recorded, its transcription held at the gate. Take A:
        // recorded and queued behind Z, its pipeline not yet started.
        await session.pressBegan()
        await session.pressEnded()
        await session.pressBegan()
        await session.pressEnded()
        // Press B: the microphone will not open.
        await session.pressBegan()
        #expect(await session.lastError != nil)
        await release.open()
        if let pipeline = await session.pipelineTask { await pipeline.value }
        #expect(await session.lastError != nil, "A's pipeline erased B's failure")
    }

    /// docs/17 review #6: a failed command is not kept for "Recover", which
    /// would re-run it as dictation and type the spoken instruction.
    @Test func aFailedCommandTakeIsNotPreservedForRecovery() async {
        let preserved = LockedStrings()
        var dependencies = DictationSession.Dependencies(
            audio: ScriptedAudioCapturing(
                chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
                log: CaptureLog()
            ),
            engine: FakeTranscriptionEngine(
                result: TranscriptionResult(text: "x", detectedLanguage: .english),
                failure: .engineUnavailable("down")
            ),
            preserveFailedAudio: { _ in preserved.append("kept") },
            deliverer: RecordingTextDeliverer(),
            store: InMemoryStore(),
            config: StaticConfig(),
            profileResolution: { (Profile(name: "Default"), .app, "com.example.notes") },
            now: { fixedNow }
        )
        dependencies.handleCommand = { _ in }
        let session = DictationSession(dependencies: dependencies)
        await session.pressBegan(kind: .command)
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }
        #expect(preserved.snapshot().isEmpty)

        // A failed dictation still is.
        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask { await pipeline.value }
        #expect(preserved.snapshot() == ["kept"])
    }

    /// Regression: profile resolution must never gate the microphone. On macOS
    /// it shells out to osascript for the frontmost browser's tab URL (up to
    /// 1.5 s), and every millisecond before capture opens is speech the user
    /// already spoke. Here resolution refuses to finish until capture is live,
    /// so the pre-fix serial order (resolve → start) cannot pass.
    @Test func captureStartsWithoutWaitingForProfileResolution() async throws {
        let gate = CaptureGate()
        let captureLog = CaptureLog()
        let audio = ScriptedAudioCapturing(
            chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
            log: captureLog,
            onStart: { await gate.open() }
        )
        let deliverer = RecordingTextDeliverer()
        let store = InMemoryStore()
        let session = DictationSession(
            dependencies: DictationSession.Dependencies(
                audio: audio,
                engine: FakeTranscriptionEngine(
                    result: TranscriptionResult(text: "hello there", detectedLanguage: .english)
                ),
                deliverer: deliverer,
                store: store,
                config: StaticConfig(),
                profileResolution: {
                    // Bounded so a regression fails the assertion instead of
                    // hanging the suite forever.
                    let sawCaptureStart = await withTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await gate.waitForOpen()
                            return true
                        }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(5))
                            return false
                        }
                        let first = await group.next() ?? false
                        group.cancelAll()
                        return first
                    }
                    return (
                        Profile(name: sawCaptureStart ? "Concurrent" : "Serialized"),
                        .app,
                        "com.example.pressapp"
                    )
                },
                now: { fixedNow }
            )
        )

        await session.pressBegan()
        await session.pressEnded()
        if let pipeline = await session.pipelineTask {
            await pipeline.value
        }
        if let persistence = await session.persistenceTask {
            await persistence.value
        }

        // "Serialized" would mean the press awaited resolution before opening
        // the mic — the leading-speech-loss bug.
        let records = await store.records
        let record = try #require(records.first)
        #expect(record.profileName == "Concurrent")

        // The resolution is still the pinned press-time one (FR-3.6).
        let contexts = await deliverer.contexts
        #expect(contexts.first?.pressTimeAppBundleID == "com.example.pressapp")
        #expect(record.routeKind == .app)
        let finishCount = await captureLog.finishCount
        #expect(finishCount == 1)
    }

    /// docs/17 §4.4 #13: an earlier take that fails while the next one is
    /// recording must not leave its error behind for the next take's idle.
    @Test func aFailedEarlierTakeDoesNotBlameTheNextOne() async {
        let engine = GatedFailFirstEngine(
            result: TranscriptionResult(text: "second take works", detectedLanguage: .english)
        )
        let deliverer = RecordingTextDeliverer()
        let session = DictationSession(
            dependencies: DictationSession.Dependencies(
                audio: ScriptedAudioCapturing(
                    chunk: PCMChunk(samples: [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)),
                    log: CaptureLog()
                ),
                engine: engine,
                selectCleanup: { _ in nil },
                deliverer: deliverer,
                store: InMemoryStore(),
                config: StaticConfig(),
                profileResolution: { (Profile(name: "Default"), .app, "com.example.pressapp") },
                now: { fixedNow }
            )
        )

        await session.pressBegan()
        await session.pressEnded()
        let firstPipeline = await session.pipelineTask
        // Take 2 starts recording while take 1 is still transcribing.
        await session.pressBegan()
        await engine.release()
        await firstPipeline?.value
        let errorWhileRecording = await session.lastError
        #expect(errorWhileRecording != nil)

        await session.pressEnded()
        if let pipeline = await session.pipelineTask {
            await pipeline.value
        }
        let delivered = await deliverer.deliveredTexts
        #expect(delivered == ["Second take works."])
        let errorAfterSuccess = await session.lastError
        #expect(errorAfterSuccess == nil)
    }

    @Test func secureFieldBlockPersistsNothing() async {
        let harness = makeHarness(
            deliveryOutcome: .blockedSecureField(culpritApp: "com.example.password")
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        // The deliverer ran (and blocked), and per FR-3.2 nothing is persisted.
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])
        let records = await harness.store.records
        #expect(records.isEmpty)
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }

    @Test func microphoneStartsBeforeProfileResolutionCompletes() async throws {
        // W1 regression: a hung browser AppleScript (up to 1.5 s inside
        // profile resolution) must never delay audio start. The gate keeps
        // resolution suspended; recording must begin anyway.
        let gate = Gate()
        let profile = Profile(name: "Default")
        let harness = makeHarness(profileResolution: {
            await gate.wait()
            return (profile, .app, "com.example.pressapp")
        })

        await harness.session.pressBegan()
        guard case .recording = await harness.session.phase else {
            Issue.record("expected recording while resolution is still blocked")
            return
        }

        // Release with resolution still pending: capture stops, the pipeline
        // waits on the resolution instead of the microphone having waited.
        await harness.session.pressEnded()
        await gate.open()
        await harness.drainPipeline()

        let deliveredTexts = await harness.deliverer.deliveredTexts
        #expect(deliveredTexts == ["Let's meet on saturday."])
        let records = await harness.store.records
        #expect(records.first?.profileName == "Default")
    }

    @Test func provisionalTapWithSpeechDeliversOnlyAfterCommit() async {
        // W10/FR-1.5: a short tap with real audio ends provisionally — held
        // through the double-tap window, delivered only on commit.
        let harness = makeHarness(audioSeconds: 2.0)
        await harness.session.pressBegan()
        await harness.session.finishPress(
            isLockMode: false, heldDurationOverride: .milliseconds(200), provisional: true
        )
        await harness.drainPipeline()

        let heldBack = await harness.deliverer.deliveredTexts
        #expect(heldBack.isEmpty)

        await harness.session.commitProvisionalTake()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }

    @Test func provisionalTapDiscardedByLockGestureDeliversNothing() async {
        // W10 regression: the first tap of a double-tap must never paste —
        // the lock gesture discards the held take.
        let harness = makeHarness(audioSeconds: 2.0)
        await harness.session.pressBegan()
        await harness.session.finishPress(
            isLockMode: false, heldDurationOverride: .milliseconds(200), provisional: true
        )
        await harness.session.discardProvisionalTake()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.isEmpty)
        let records = await harness.store.records
        #expect(records.isEmpty)
        let phase = await harness.session.phase
        #expect(phase == .idle)

        // A late commit after the discard is a no-op.
        await harness.session.commitProvisionalTake()
        await harness.drainPipeline()
        let deliveredAfter = await harness.deliverer.deliveredTexts
        #expect(deliveredAfter.isEmpty)
    }

    @Test func newPressAcceptedWhilePreviousTakeStillProcessing() async {
        // W3 regression: rapid-fire dictation — the second press must start
        // recording while the first take's pipeline (slowed engine) is still
        // transcribing, and both takes must deliver.
        let harness = makeHarness(engineDelay: .milliseconds(300))

        await harness.session.pressBegan()
        await harness.session.finishPress(isLockMode: false, heldDurationOverride: .seconds(1))

        // Pipeline 1 is in flight; the next press is accepted immediately.
        await harness.session.pressBegan()
        guard case .recording = await harness.session.phase else {
            Issue.record("expected recording while the first take is processing")
            return
        }
        await harness.session.finishPress(isLockMode: false, heldDurationOverride: .seconds(1))
        await harness.drainPipeline()

        let deliveredTexts = await harness.deliverer.deliveredTexts
        #expect(deliveredTexts.count == 2)
        let records = await harness.store.records
        #expect(records.count == 2)
        let transcribeCount = await harness.engine.transcribeCount
        #expect(transcribeCount == 2)
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }
}

// MARK: - Burmese (v1.1)

/// Cleanup that damages a transcript is worse than no cleanup: small local
/// models corrupt Burmese rather than tidy it (docs/04 Appendix A).
struct BurmeseCleanupGateTests {

    @Test func autoDetectedBurmeseSkipsCleanup() async throws {
        let provider = ScriptedCleanupProvider(script: .uppercase)
        let harness = makeHarness(
            engineResult: TranscriptionResult(
                text: "ဒီနေ့ရာသီဥတုကောင်းတယ်", detectedLanguage: .burmese
            ),
            profile: Profile(name: "Default", cleanupEnabled: true),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let calls = await provider.cleanupCallCount
        #expect(calls == 0)
        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.cleanup == .skipped(reason: .languageOptOut))
        // The deterministic stages still ran, so the text is still improved.
        #expect(record.deliveredText.hasSuffix("။"))
    }

    /// Pinning Burmese on a profile is the deliberate opt-in.
    @Test func aProfilePinnedToBurmeseMayUseCleanup() async throws {
        let provider = ScriptedCleanupProvider(
            script: .fixed("ဒီနေ့ ရာသီဥတု ကောင်းတယ်။")
        )
        let harness = makeHarness(
            engineResult: TranscriptionResult(
                text: "ဒီနေ့ရာသီဥတုကောင်းတယ်", detectedLanguage: .burmese
            ),
            profile: Profile(
                name: "Burmese notes",
                cleanupEnabled: true,
                promptText: "Tidy this.",
                languageOverride: .pinned(.burmese)
            ),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let calls = await provider.cleanupCallCount
        #expect(calls == 1)
        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.deliveredText == "ဒီနေ့ ရာသီဥတု ကောင်းတယ်။")
    }

    @Test func englishAndChineseAreUnaffectedByTheGate() {
        #expect(
            DictationSession.cleanupAllowed(for: .english, profile: Profile(name: "Default"))
        )
        #expect(
            DictationSession.cleanupAllowed(for: .chinese, profile: Profile(name: "Default"))
        )
        #expect(
            !DictationSession.cleanupAllowed(for: .burmese, profile: Profile(name: "Default"))
        )
    }

    /// A Burmese dictation still runs the deterministic Burmese stages end to
    /// end — that is the part of v1.1 that is genuinely complete.
    @Test func burmeseGoesThroughTheBurmesePipeline() async throws {
        let harness = makeHarness(
            engineResult: TranscriptionResult(
                text: "ဒီနေ့ ရာသီဥတု ကောင်းတယ်", detectedLanguage: .burmese
            ),
            profile: Profile(
                name: "Burmese",
                formatting: FormattingOptions(myanmarDigits: .western)
            )
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        await harness.drainPipeline()

        let delivered = await harness.deliverer.deliveredTexts
        // The terminal ။ was appended — no English capitalization or period.
        #expect(delivered == ["ဒီနေ့ ရာသီဥတု ကောင်းတယ်။"])
        let records = await harness.store.records
        #expect(records.first?.language == .burmese)
    }
}

/// Recovering a take the user cancelled with Escape (FR-1.6, docs/11 G9).
struct CancelledTakeRecoveryTests {

    private static func recoverableAudio(seconds: Double = 2.0) -> PCMChunk {
        PCMChunk(
            samples: [Float](repeating: 0.1, count: Int(seconds * Double(PCMChunk.sampleRate)))
        )
    }

    @Test func recoveringACancelledTakeRunsTheWholePipeline() async throws {
        let harness = makeHarness()

        let consumed = await harness.session.recover(audio: Self.recoverableAudio())
        #expect(consumed)
        await harness.drainPipeline()

        // Identical to a take that was never cancelled: same normalization,
        // same delivery, same history row.
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])

        let records = await harness.store.records
        let record = try #require(records.first)
        // The one thing that differs, so history can tell the story.
        #expect(record.source == .recovered)
        #expect(record.language == .english)
        #expect(record.profileName == "Default")
        #expect(abs(record.durationSeconds - 2.0) < 0.01)
    }

    @Test func recoveryResolvesTheProfileNowRatherThanAtCancelTime() async throws {
        // Recovery delivers into whatever is frontmost at the moment the user
        // asks for it, so it must ask the resolver then — not replay a pinned
        // context captured minutes ago.
        let harness = makeHarness()
        _ = await harness.session.recover(audio: Self.recoverableAudio())

        let contexts = await harness.deliverer.contexts
        #expect(contexts.first?.pressTimeAppBundleID == "com.example.pressapp")
        // Recovery is never a locked take: it has no press to hold open.
        #expect(contexts.first?.isLockMode == false)
    }

    @Test func aFailedRecoveryKeepsTheTakeRecoverable() async throws {
        // The whole promise of recovery is a second chance. Reporting the audio
        // consumed after the engine failed would let the caller delete the only
        // copy of a take that produced nothing.
        let harness = makeHarness(engineFailure: .engineUnavailable("model missing"))

        let consumed = await harness.session.recover(audio: Self.recoverableAudio())
        #expect(!consumed)

        let records = await harness.store.records
        #expect(records.isEmpty)
        let error = await harness.session.lastError
        #expect(error != nil)
    }

    @Test func aSecureFieldConsumesTheRecoveredTake() async throws {
        // FR-3.2: that take leaves no trace. Holding its raw audio back for
        // another attempt would undo the rule that just fired.
        let harness = makeHarness(
            deliveryOutcome: .blockedSecureField(culpritApp: "1Password")
        )

        let consumed = await harness.session.recover(audio: Self.recoverableAudio())
        #expect(consumed)

        let records = await harness.store.records
        #expect(records.isEmpty)
    }

    @Test func recoveryIsRefusedWhileATakeIsInFlight() async throws {
        let harness = makeHarness()
        await harness.session.pressBegan()

        let consumed = await harness.session.recover(audio: Self.recoverableAudio())
        #expect(!consumed)

        // The live take is untouched and still completes normally.
        await harness.session.pressEnded()
        await harness.drainPipeline()
        let records = await harness.store.records
        #expect(records.count == 1)
        #expect(records.first?.source == .dictation)
    }

    @Test func recoveringSilenceIsANoOp() async throws {
        let harness = makeHarness()
        let consumed = await harness.session.recover(audio: PCMChunk(samples: []))
        #expect(!consumed)
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered.isEmpty)
    }

    @Test func aRetriedRecoveryClearsTheEarlierFailuresError() async throws {
        // The HUD reads `lastError` when the session returns to idle, so a
        // stale error from the attempt that failed would be shown over the
        // retry that worked — and the user would think recovery was broken.
        let deliverer = RecordingTextDeliverer()
        let store = InMemoryStore()
        let session = DictationSession(
            dependencies: DictationSession.Dependencies(
                audio: ScriptedAudioCapturing(chunk: PCMChunk(samples: []), log: CaptureLog()),
                engine: FailThenSucceedEngine(
                    result: TranscriptionResult(text: "second time lucky", detectedLanguage: .english)
                ),
                selectCleanup: { _ in nil },
                deliverer: deliverer,
                store: store,
                config: StaticConfig(),
                profileResolution: { (Profile(name: "Default"), .app, "com.example.pressapp") },
                now: { fixedNow }
            )
        )

        let audio = Self.recoverableAudio()
        let firstAttempt = await session.recover(audio: audio)
        #expect(!firstAttempt)
        let errorAfterFailure = await session.lastError
        #expect(errorAfterFailure != nil)

        // The caller kept the recording precisely because the first attempt
        // reported it unconsumed, so the same audio comes back.
        let secondAttempt = await session.recover(audio: audio)
        #expect(secondAttempt)
        if let persistence = await session.persistenceTask {
            await persistence.value
        }
        let errorAfterSuccess = await session.lastError
        #expect(errorAfterSuccess == nil)

        let delivered = await deliverer.deliveredTexts
        #expect(delivered == ["Second time lucky."])
        let records = await store.records
        #expect(records.count == 1)
        #expect(records.first?.source == .recovered)
    }
}

struct EmptyTranscriptTests {
    @Test(arguments: ["[BLANK_AUDIO]", "Um.", "<|nospeech|>"])
    func emptyAfterNormalizationDeliversAndSavesNothing(raw: String) async {
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: raw, detectedLanguage: .english)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()
        #expect(await harness.deliverer.deliveredTexts.isEmpty)
        #expect(await harness.store.records.isEmpty)
    }
}

/// Starts twice, then fails every later start — a microphone that went away.
private actor StartCounter {
    var starts = 0
    func next() -> Int {
        starts += 1
        return starts
    }
}

private struct FailingThirdStartAudio: AudioCapturing {
    let chunk: PCMChunk
    private let counter = StartCounter()

    init(chunk: PCMChunk) { self.chunk = chunk }

    func start() async throws -> CaptureSession {
        guard await counter.next() <= 2 else { throw CancellationError() }
        let chunk = chunk
        return CaptureSession(
            chunks: AsyncStream { $0.finish() },
            finish: { chunk },
            cancel: {}
        )
    }
}

/// Transcribes only once the test opens the gate.
private struct GatedEngine: TranscriptionEngine {
    let gate: CaptureGate
    var id: String { "gated" }
    var displayName: String { "Gated" }
    func availability(for language: Language) async -> EngineAvailability { .ready }
    func prepare(languageMode: LanguageMode) async throws {}
    func unload() async {}
    func transcribe(
        _ audio: PCMChunk, languageMode: LanguageMode, dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        await gate.waitForOpen()
        return TranscriptionResult(text: "take a works", detectedLanguage: .english)
    }
    func transcribeStream(
        _ audio: AsyncStream<PCMChunk>, languageMode: LanguageMode, dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
