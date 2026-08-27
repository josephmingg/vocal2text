import CoreModels
import Foundation

/// Pure span math behind the docs/15 step 16 VAD gate: a detector reports
/// where speech sits inside a finished take; this reduces those segments to
/// the one padded range worth transcribing. Less audio into the engine is a
/// faster decode and fewer hallucinations — Whisper invents text for silence,
/// and trailing room tone is where most of it comes from.
///
/// Pure and platform-free so the trim rules are tested on Linux; the
/// Silero-backed detector (ASREngineSherpaOnnx) only supplies segments.
public enum SpeechTrim {

    /// One detected speech segment, in sample offsets from the take's start.
    public struct Segment: Sendable, Equatable {
        public var start: Int
        public var count: Int

        public init(start: Int, count: Int) {
            self.start = start
            self.count = count
        }
    }

    /// The single range covering all detected speech, padded on both sides,
    /// clamped to the take. Returns nil when no valid segment exists — the
    /// take is silence and transcribing it can only hallucinate.
    ///
    /// One padded envelope rather than per-segment extraction: cutting the
    /// pauses *between* phrases out of the audio would splice unrelated
    /// sounds together and change what the engine hears. Only the leading
    /// and trailing silence are trimmed; everything between first and last
    /// speech is kept verbatim.
    public static func paddedSpan(
        segments: [Segment],
        totalSamples: Int,
        paddingSamples: Int
    ) -> Range<Int>? {
        guard totalSamples > 0, paddingSamples >= 0 else { return nil }
        let valid = segments.filter { $0.count > 0 && $0.start >= 0 && $0.start < totalSamples }
        guard
            let first = valid.map(\.start).min(),
            let last = valid.map({ min($0.start + $0.count, totalSamples) }).max()
        else { return nil }
        let lower = max(0, first - paddingSamples)
        let upper = min(totalSamples, last + paddingSamples)
        guard lower < upper else { return nil }
        return lower..<upper
    }
}
