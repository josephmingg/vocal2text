import ASRKit
import CoreModels
import Foundation
import Testing

@testable import SessionKit

/// Stress test (docs/17 §10): a simulated user dictating fast — takes that
/// overlap the previous take's transcription, Escape mid-take, command-key
/// takes, whole-take snippets — against the real `DictationSession`, with a
/// slow, jittery engine. Each take's audio is stamped with its press number,
/// so the test can prove every take lands exactly once, in press order.

private struct StressRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Numbers each capture: the first sample of the take's audio is its press
/// number, two seconds of audio so FR-1.5 never discards a quick take.
private actor PressCounter {
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var cancelled = 0
    func begin() -> Int {
        started += 1
        return started
    }
    func finish() { finished += 1 }
    func cancel() { cancelled += 1 }
}

private struct NumberedAudio: AudioCapturing {
    let counter: PressCounter

    func start() async throws -> CaptureSession {
        let number = await counter.begin()
        var samples = [Float](repeating: 0, count: 2 * PCMChunk.sampleRate)
        samples[0] = Float(number)
        let chunk = PCMChunk(samples: samples)
        let counter = self.counter
        return CaptureSession(
            chunks: AsyncStream { $0.finish() },
            finish: {
                await counter.finish()
                return chunk
            },
            cancel: { await counter.cancel() }
        )
    }
}

/// Reads the press number back out of the audio and answers after a jittery
/// delay, so pipelines genuinely overlap with the next recording.
private actor JitteryEngine: TranscriptionEngine {
    nonisolated let id = "jittery"
    nonisolated let displayName = "Jittery"
    let snippetTakes: Set<Int>
    let delays: [Int: Duration]

    init(snippetTakes: Set<Int>, delays: [Int: Duration]) {
        self.snippetTakes = snippetTakes
        self.delays = delays
    }

    func availability(for language: Language) async -> EngineAvailability { .ready }
    func prepare(languageMode: LanguageMode) async throws {}
    func unload() async {}

    func transcribe(
        _ audio: PCMChunk, languageMode: LanguageMode, dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        let number = Int(audio.samples.first ?? 0)
        if let delay = delays[number] {
            try? await Task.sleep(for: delay)
        }
        let text = snippetTakes.contains(number) ? "sign off" : "take \(number) works"
        return TranscriptionResult(text: text, detectedLanguage: .english)
    }

    nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>, languageMode: LanguageMode, dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor Commands {
    private(set) var received: [String] = []
    func add(_ command: VoiceCommand) { received.append(command.instruction) }
}

private enum TakeKindPlan { case dictation, cancel, command, snippet }

@Test(arguments: Array(UInt64(1)...UInt64(30)))
func aFastUserGetsEveryTakeExactlyOnceInPressOrder(seed: UInt64) async throws {
    var rng = StressRNG(state: seed &* 104_729)
    let takeCount = 10
    var plans: [TakeKindPlan] = []
    var delays: [Int: Duration] = [:]
    for _ in 0..<takeCount {
        let roll = Int.random(in: 0..<100, using: &rng)
        plans.append(roll < 55 ? .dictation : roll < 70 ? .cancel : roll < 85 ? .command : .snippet)
    }
    // Press numbers count only takes that start capture (all of them here).
    for number in 1...takeCount {
        delays[number] = .milliseconds(Int.random(in: 5...40, using: &rng))
    }
    let snippetTakes = Set(plans.enumerated().filter { $0.element == .snippet }.map { $0.offset + 1 })

    let counter = PressCounter()
    let deliverer = RecordingTextDeliverer()
    let store = InMemoryStore()
    let commands = Commands()
    var dependencies = DictationSession.Dependencies(
        audio: NumberedAudio(counter: counter),
        engine: JitteryEngine(snippetTakes: snippetTakes, delays: delays),
        deliverer: deliverer,
        store: store,
        config: StaticConfig(entries: [DictionaryEntry(spoken: "sign off", written: "Best,\nJoseph")]),
        profileResolution: { (Profile(name: "Default"), .app, "com.example.notes") },
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    dependencies.handleCommand = { await commands.add($0) }
    dependencies.captureSelection = { nil }
    let session = DictationSession(dependencies: dependencies)

    var expectedDeliveries: [String] = []
    var expectedCommands: [String] = []
    for (index, plan) in plans.enumerated() {
        let number = index + 1
        await session.pressBegan(kind: plan == .command ? .command : .dictation)
        try await Task.sleep(for: .milliseconds(Int.random(in: 0...8, using: &rng)))
        switch plan {
        case .cancel:
            await session.cancel()
        case .dictation:
            await session.pressEnded()
            expectedDeliveries.append("Take \(number) works.")
        case .snippet:
            await session.pressEnded()
            expectedDeliveries.append("Best,\nJoseph")
        case .command:
            await session.pressEnded()
            expectedCommands.append("Take \(number) works.")
        }
        // Sometimes press again at once, while the last take is still in flight.
        try await Task.sleep(for: .milliseconds(Int.random(in: 0...6, using: &rng)))
    }
    if let pipeline = await session.pipelineTask { await pipeline.value }
    if let persistence = await session.persistenceTask { await persistence.value }

    let delivered = await deliverer.deliveredTexts
    #expect(delivered == expectedDeliveries, "seed \(seed): deliveries out of order or lost")
    let received = await commands.received
    #expect(received == expectedCommands, "seed \(seed): commands out of order or lost")
    let records = await store.records
    #expect(records.map(\.deliveredText) == expectedDeliveries, "seed \(seed): history mismatch")
    // Every microphone that opened was closed exactly once.
    let started = await counter.started
    let finished = await counter.finished
    let cancelled = await counter.cancelled
    #expect(started == takeCount)
    #expect(finished + cancelled == started, "seed \(seed): a capture was left open")
    let phase = await session.phase
    #expect(phase == .idle, "seed \(seed): session did not settle")
    let error = await session.lastError
    #expect(error == nil, "seed \(seed): stale error after a clean run")
}
