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

private let fixedNow = Date(timeIntervalSince1970: 1_723_000_000)

private struct Harness {
    let session: DictationSession
    let engine: FakeTranscriptionEngine
    let deliverer: RecordingTextDeliverer
    let store: InMemoryStore
    let captureLog: CaptureLog
}

private func makeHarness(
    engineResult: TranscriptionResult = TranscriptionResult(
        text: "let's meet on saturday", detectedLanguage: .english
    ),
    engineFailure: TranscriptionError? = nil,
    audioSeconds: Double = 2.0,
    profile: Profile = Profile(name: "Default"),
    config: StaticConfig = StaticConfig(),
    cleanup: CleanupPipeline? = nil,
    cleanupProviderID: CleanupProviderID = .ollama(model: "qwen2.5"),
    prewarm: @escaping @Sendable () async -> Void = {},
    deliveryOutcome: DeliveryOutcome = .inserted(method: .paste, appBundleID: "com.example.notes")
) -> Harness {
    let captureLog = CaptureLog()
    let sampleCount = max(0, Int(audioSeconds * Double(PCMChunk.sampleRate)))
    let audio = ScriptedAudioCapturing(
        chunk: PCMChunk(samples: [Float](repeating: 0, count: sampleCount)),
        log: captureLog
    )
    let engine = FakeTranscriptionEngine(result: engineResult, failure: engineFailure)
    let deliverer = RecordingTextDeliverer(outcome: deliveryOutcome)
    let store = InMemoryStore()
    let dependencies = DictationSession.Dependencies(
        audio: audio,
        engine: engine,
        cleanup: cleanup,
        cleanupProviderID: cleanupProviderID,
        prewarmCleanup: prewarm,
        deliverer: deliverer,
        store: store,
        config: config,
        profileResolution: { (profile, .app, "com.example.pressapp") },
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
            profile: Profile(name: "Notes", cleanupEnabled: true),
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

    @Test func validatorRejectionFallsBackToStage2Text() async throws {
        // "Here is…" trips the output validator's meta-text rule, so the
        // session must deliver the stage-2 text (FR-7.3) and log the rejection.
        let provider = ScriptedCleanupProvider(
            script: .fixed("Here is your cleaned text: Meet on saturday.")
        )
        let harness = makeHarness(
            engineResult: TranscriptionResult(text: "meet on saturday", detectedLanguage: .english),
            profile: Profile(name: "Notes", cleanupEnabled: true),
            config: StaticConfig(masterSwitch: true),
            cleanup: CleanupPipeline(provider: provider)
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()

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

        let cleanupCallCount = await provider.cleanupCallCount
        #expect(cleanupCallCount == 0)

        let records = await harness.store.records
        let record = try #require(records.first)
        #expect(record.cleanup == .skipped(reason: .profileDisabled))
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

        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Use Claude Code to review."])

        // Written forms also flow to the engine as biasing terms.
        let terms = await harness.engine.lastDictionaryTerms
        #expect(terms == ["Claude Code"])
    }

    @Test func secureFieldBlockPersistsNothing() async {
        let harness = makeHarness(
            deliveryOutcome: .blockedSecureField(culpritApp: "com.example.password")
        )
        await harness.session.pressBegan()
        await harness.session.pressEnded()

        // The deliverer ran (and blocked), and per FR-3.2 nothing is persisted.
        let delivered = await harness.deliverer.deliveredTexts
        #expect(delivered == ["Let's meet on saturday."])
        let records = await harness.store.records
        #expect(records.isEmpty)
        let phase = await harness.session.phase
        #expect(phase == .idle)
    }
}
