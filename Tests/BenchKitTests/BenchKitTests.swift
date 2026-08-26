import Foundation
import Testing
@testable import BenchKit

// MARK: - WAV decoding

/// Builds a minimal PCM WAV in memory (the same shape afconvert/ffmpeg emit).
private func makeWav(
    samples: [Int16], sampleRate: UInt32 = 16_000, channels: UInt16 = 1
) -> Data {
    var data = Data()
    func append16(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }
    func append32(_ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }
    let payloadBytes = UInt32(samples.count * 2)
    data.append(contentsOf: "RIFF".utf8)
    append32(36 + payloadBytes)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    append32(16)
    append16(1)  // PCM
    append16(channels)
    append32(sampleRate)
    append32(sampleRate * UInt32(channels) * 2)  // byte rate
    append16(channels * 2)  // block align
    append16(16)  // bits per sample
    data.append(contentsOf: "data".utf8)
    append32(payloadBytes)
    for sample in samples {
        append16(UInt16(bitPattern: sample))
    }
    return data
}

@Test func wavDecodeRoundTripsPCM16() throws {
    let wav = makeWav(samples: [0, 16_384, -16_384, 32_767, -32_768], sampleRate: 16_000)
    let contents = try WavFile.decode(wav)
    #expect(contents.sampleRate == 16_000)
    #expect(contents.samples.count == 5)
    #expect(contents.samples[0] == 0)
    #expect(abs(contents.samples[1] - 0.5) < 0.001)
    #expect(abs(contents.samples[2] + 0.5) < 0.001)
    #expect(abs(contents.samples[3] - 1.0) < 0.001)
    // Negative full-scale clamps to -1.
    #expect(contents.samples[4] == -1.0)
}

@Test func wavDecodeTakesChannelZeroOfStereo() throws {
    // Interleaved L/R frames: L = 100, R = 200.
    let wav = makeWav(samples: [100, 200, 100, 200], channels: 2)
    let contents = try WavFile.decode(wav)
    #expect(contents.samples.count == 2)
    #expect(abs(contents.samples[0] - 100.0 / 32_767.0) < 0.0001)
}

@Test func wavDecodeRejectsGarbage() {
    #expect(throws: WavFile.ReadError.notRIFF) {
        try WavFile.decode(Data("not a wav at all".utf8))
    }
}

@Test func wavDurationUsesSampleRate() throws {
    let wav = makeWav(samples: [Int16](repeating: 0, count: 16_000))
    let contents = try WavFile.decode(wav)
    #expect(abs(contents.durationSeconds - 1.0) < 0.0001)
}

// MARK: - WER / CER

@Test func perfectHypothesisScoresZero() {
    let score = WordErrorRate.score(
        reference: "Ship the benchmark harness on Friday.",
        hypothesis: "ship the benchmark harness on friday"
    )
    #expect(score.editDistance == 0)
    #expect(score.referenceCount == 6)
    #expect(score.rate == 0)
    #expect(!score.isCharacterBased)
}

@Test func substitutionsInsertionsDeletionsCount() {
    // reference: "the quick brown fox" / hypothesis: "the slow brown fox jumps"
    // = 1 substitution + 1 insertion.
    let score = WordErrorRate.score(
        reference: "the quick brown fox",
        hypothesis: "the slow brown fox jumps"
    )
    #expect(score.editDistance == 2)
    #expect(score.referenceCount == 4)
    #expect(abs(score.rate - 0.5) < 0.0001)
}

@Test func hanReferenceScoresPerCharacter() {
    let score = WordErrorRate.score(reference: "周六去爬山", hypothesis: "周日去爬山")
    #expect(score.isCharacterBased)
    #expect(score.referenceCount == 5)
    #expect(score.editDistance == 1)
    #expect(abs(score.rate - 0.2) < 0.0001)
}

@Test func punctuationNeverPenalizes() {
    let score = WordErrorRate.score(
        reference: "周六，去爬山。", hypothesis: "周六去爬山"
    )
    #expect(score.editDistance == 0)
}

@Test func emptyHypothesisIsAllDeletions() {
    let score = WordErrorRate.score(reference: "one two three", hypothesis: "")
    #expect(score.editDistance == 3)
    #expect(score.rate == 1.0)
}

// MARK: - Percentiles

@Test func percentileNearestRank() {
    let sorted: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    #expect(Percentile.value(sorted, 50) == 5)
    #expect(Percentile.value(sorted, 95) == 10)
    #expect(Percentile.value(sorted, 100) == 10)
    #expect(Percentile.value([42], 50) == 42)
    #expect(Percentile.value([], 50) == 0)
}
