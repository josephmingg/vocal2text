import ASRKit
import Foundation
import Testing

// MARK: - PCMChunk

@Test func pcmChunkSampleRateIsSixteenKilohertz() {
    #expect(PCMChunk.sampleRate == 16_000)
}

@Test func emptyChunkHasZeroDuration() {
    #expect(PCMChunk(samples: []).durationSeconds == 0)
}

@Test(arguments: [
    (16_000, 1.0),
    (8_000, 0.5),
    (4_000, 0.25),
    (40_000, 2.5),
    (1_600, 0.1)
])
func chunkDurationMatchesSampleCount(count: Int, expected: Double) {
    let chunk = PCMChunk(samples: [Float](repeating: 0, count: count))
    #expect(abs(chunk.durationSeconds - expected) < 1e-12)
}

@Test func oneSampleDurationIsOneOverSampleRate() {
    let chunk = PCMChunk(samples: [0.5])
    #expect(chunk.durationSeconds == 1.0 / 16_000.0)
}

// MARK: - TranscriptionUpdate

@Test func transcriptionUpdateEquality() {
    let a = TranscriptionUpdate(kind: .partial, text: "hello", detectedLanguage: .english)
    let b = TranscriptionUpdate(kind: .partial, text: "hello", detectedLanguage: .english)
    #expect(a == b)
    #expect(a != TranscriptionUpdate(kind: .final, text: "hello", detectedLanguage: .english))
    #expect(a != TranscriptionUpdate(kind: .partial, text: "hello!", detectedLanguage: .english))
    #expect(a != TranscriptionUpdate(kind: .partial, text: "hello", detectedLanguage: .chinese))
    #expect(a != TranscriptionUpdate(kind: .partial, text: "hello"))
}

@Test func transcriptionUpdateDefaultsToNilLanguage() {
    let update = TranscriptionUpdate(kind: .final, text: "你好")
    #expect(update.detectedLanguage == nil)
    #expect(update == TranscriptionUpdate(kind: .final, text: "你好", detectedLanguage: nil))
}

// MARK: - TranscriptionResult

@Test func transcriptionResultEqualityIncludesSegments() {
    let segment = TranscriptionResult.TimedSegment(text: "你好", start: 0.0, end: 0.5)
    let a = TranscriptionResult(text: "你好", detectedLanguage: .chinese, segments: [segment])
    let b = TranscriptionResult(text: "你好", detectedLanguage: .chinese, segments: [segment])
    #expect(a == b)

    let shifted = TranscriptionResult.TimedSegment(text: "你好", start: 0.0, end: 0.75)
    #expect(a != TranscriptionResult(text: "你好", detectedLanguage: .chinese, segments: [shifted]))
    #expect(a != TranscriptionResult(text: "你好", detectedLanguage: .chinese, segments: []))
    #expect(a != TranscriptionResult(text: "你好", detectedLanguage: .english, segments: [segment]))
}

@Test func transcriptionResultSegmentsDefaultToEmpty() {
    let result = TranscriptionResult(text: "hello", detectedLanguage: .english)
    #expect(result.segments.isEmpty)
}

// MARK: - EngineAvailability

@Test func engineAvailabilityEquality() {
    #expect(EngineAvailability.ready == .ready)
    #expect(EngineAvailability.needsDownload(bytes: 626_000_000) == .needsDownload(bytes: 626_000_000))
    #expect(EngineAvailability.needsDownload(bytes: 100) != .needsDownload(bytes: 200))
    #expect(EngineAvailability.unsupported(reason: "no model") == .unsupported(reason: "no model"))
    #expect(EngineAvailability.unsupported(reason: "no model") != .unsupported(reason: "other"))
    #expect(EngineAvailability.ready != .needsDownload(bytes: 0))
}

@Test func engineAvailabilityIsHashable() {
    let set: Set<EngineAvailability> = [
        .ready,
        .ready,
        .needsDownload(bytes: 1),
        .needsDownload(bytes: 1),
        .unsupported(reason: "x")
    ]
    #expect(set.count == 3)
}

// MARK: - TranscriptionError

@Test func transcriptionErrorEquality() {
    #expect(TranscriptionError.cancelled == .cancelled)
    #expect(TranscriptionError.engineUnavailable("a") == .engineUnavailable("a"))
    #expect(TranscriptionError.engineUnavailable("a") != .engineUnavailable("b"))
    #expect(TranscriptionError.modelNotInstalled != .cancelled)
}
