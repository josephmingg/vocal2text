import CoreModels
import Foundation
import Testing
@testable import ASRKit

/// The live toggle behind "use Parakeet for pinned English" (docs/15 step
/// 14): each call must route by the flag's value at that moment, per the
/// settings-take-effect rule (docs/11 G15).
struct SwitchedEngineTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test func routesByTheLiveFlagPerCall() async throws {
        let fast = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "fast", detectedLanguage: .english)
        )
        let steady = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "steady", detectedLanguage: .english)
        )
        let flag = Flag()
        let engine = SwitchedEngine(isOn: { flag.get() }, on: fast, off: steady)
        let audio = PCMChunk(samples: [0.1, 0.2])

        let offResult = try await engine.transcribe(
            audio, languageMode: .pinned(.english), dictionaryTerms: []
        )
        #expect(offResult.text == "steady")

        flag.set(true)
        let onResult = try await engine.transcribe(
            audio, languageMode: .pinned(.english), dictionaryTerms: []
        )
        #expect(onResult.text == "fast")

        let fastCalls = await fast.transcribeCount
        let steadyCalls = await steady.transcribeCount
        #expect(fastCalls == 1)
        #expect(steadyCalls == 1)
    }

    @Test func aFailingOnEngineFallsBackWhenAsked() async throws {
        let broken = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "", detectedLanguage: .english),
            failure: .engineUnavailable("model missing")
        )
        let steady = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "steady", detectedLanguage: .english)
        )
        let audio = PCMChunk(samples: [0.1, 0.2])

        let fallback = SwitchedEngine(isOn: { true }, on: broken, off: steady, fallsBackOnFailure: true)
        let result = try await fallback.transcribe(audio, languageMode: .pinned(.english), dictionaryTerms: [])
        #expect(result.text == "steady")

        // Without the option the failure reaches the caller, as before.
        let strict = SwitchedEngine(isOn: { true }, on: broken, off: steady)
        await #expect(throws: TranscriptionError.engineUnavailable("model missing")) {
            try await strict.transcribe(audio, languageMode: .pinned(.english), dictionaryTerms: [])
        }
    }

    @Test func aCancelledTakeDoesNotFallBack() async throws {
        let cancelled = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "", detectedLanguage: .english),
            failure: .cancelled
        )
        let steady = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "steady", detectedLanguage: .english)
        )
        let engine = SwitchedEngine(isOn: { true }, on: cancelled, off: steady, fallsBackOnFailure: true)
        await #expect(throws: TranscriptionError.cancelled) {
            try await engine.transcribe(PCMChunk(samples: [0.1]), languageMode: .pinned(.english), dictionaryTerms: [])
        }
        #expect(await steady.transcribeCount == 0)
    }

    @Test func unloadReleasesBothSides() async {
        let fast = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "fast", detectedLanguage: .english)
        )
        let steady = FakeTranscriptionEngine(
            result: TranscriptionResult(text: "steady", detectedLanguage: .english)
        )
        let engine = SwitchedEngine(isOn: { false }, on: fast, off: steady)
        await engine.unload()
        let fastUnloads = await fast.unloadCount
        let steadyUnloads = await steady.unloadCount
        #expect(fastUnloads == 1)
        #expect(steadyUnloads == 1)
    }
}
