import Foundation
import Testing
@testable import ASRKit

struct SpeechTrimTests {

    @Test func silenceYieldsNoSpan() {
        #expect(SpeechTrim.paddedSpan(segments: [], totalSamples: 16_000, paddingSamples: 100) == nil)
    }

    @Test func emptyTakeYieldsNoSpan() {
        #expect(
            SpeechTrim.paddedSpan(
                segments: [.init(start: 0, count: 100)], totalSamples: 0, paddingSamples: 0
            ) == nil
        )
    }

    @Test func aSingleSegmentIsPaddedAndClamped() {
        let span = SpeechTrim.paddedSpan(
            segments: [.init(start: 1_000, count: 2_000)],
            totalSamples: 16_000,
            paddingSamples: 400
        )
        #expect(span == 600..<3_400)
    }

    @Test func paddingClampsAtTheTakeEdges() {
        let span = SpeechTrim.paddedSpan(
            segments: [.init(start: 100, count: 15_800)],
            totalSamples: 16_000,
            paddingSamples: 4_000
        )
        #expect(span == 0..<16_000)
    }

    @Test func multipleSegmentsKeepEverythingBetweenFirstAndLastSpeech() {
        // The pause between phrases is NOT cut out — only the ends are.
        let span = SpeechTrim.paddedSpan(
            segments: [
                .init(start: 8_000, count: 4_000),
                .init(start: 2_000, count: 1_000),
                .init(start: 20_000, count: 2_000),
            ],
            totalSamples: 32_000,
            paddingSamples: 500
        )
        #expect(span == 1_500..<22_500)
    }

    @Test func degenerateSegmentsAreIgnored() {
        #expect(
            SpeechTrim.paddedSpan(
                segments: [
                    .init(start: -50, count: 10),
                    .init(start: 5_000, count: 0),
                    .init(start: 999_999, count: 100),
                ],
                totalSamples: 16_000,
                paddingSamples: 100
            ) == nil
        )
    }

    @Test func aSegmentRunningPastTheTakeIsClampedNotDropped() {
        // A flush() at take end can report a segment whose tail exceeds the
        // sample count by a window; the span must clamp, not index past it.
        let span = SpeechTrim.paddedSpan(
            segments: [.init(start: 15_000, count: 5_000)],
            totalSamples: 16_000,
            paddingSamples: 0
        )
        #expect(span == 15_000..<16_000)
    }
}
