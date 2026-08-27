import CoreModels
import Foundation

/// Lifetime usage aggregated from history rows (docs/15 step 54, the modest
/// cut: no charts, no "hours saved" guesswork — numbers the data actually
/// supports). Pure so it tests on Linux; the About pane feeds it
/// `allTranscripts()` and renders what comes back.
///
/// Only spoken takes count (`source == .dictation` or `.recovered`, not
/// cancelled): a file import is not the user speaking, and folding it in
/// would inflate every number here.
public struct UsageStats: Equatable, Sendable {
    public var takeCount: Int
    public var wordCount: Int
    public var speakingSeconds: Double
    /// Delivered words per minute of speech; 0 until something was spoken.
    public var wordsPerMinute: Double
    /// Consecutive calendar days with at least one take, counting back from
    /// the most recent take's day (not from "today": the stat describes the
    /// history, and a pure function cannot know the current date anyway).
    public var streakDays: Int
    /// Median release→text wait across takes that recorded timings — the
    /// number the user feels, so the one worth showing outside vocal-bench.
    public var medianFeltLatencySeconds: Double

    public init(
        takeCount: Int = 0,
        wordCount: Int = 0,
        speakingSeconds: Double = 0,
        wordsPerMinute: Double = 0,
        streakDays: Int = 0,
        medianFeltLatencySeconds: Double = 0
    ) {
        self.takeCount = takeCount
        self.wordCount = wordCount
        self.speakingSeconds = speakingSeconds
        self.wordsPerMinute = wordsPerMinute
        self.streakDays = streakDays
        self.medianFeltLatencySeconds = medianFeltLatencySeconds
    }

    public static func compute(
        records: [TranscriptRecord],
        calendar: Calendar = .current
    ) -> UsageStats {
        let takes = records.filter { $0.source != .fileImport && !$0.isCancelled }
        guard !takes.isEmpty else { return UsageStats() }

        let words = takes.reduce(0) { $0 + Self.words(in: $1.deliveredText, language: $1.language) }
        let seconds = takes.reduce(0) { $0 + max(0, $1.durationSeconds) }

        let latencies = takes
            .map(\.timings.totalPostReleaseSeconds)
            .filter { $0 > 0 }
            .sorted()

        return UsageStats(
            takeCount: takes.count,
            wordCount: words,
            speakingSeconds: seconds,
            wordsPerMinute: seconds > 0 ? Double(words) / (seconds / 60) : 0,
            streakDays: streak(of: takes.map(\.createdAt), calendar: calendar),
            medianFeltLatencySeconds: Percentile.value(latencies, 50)
        )
    }

    /// English: whitespace-separated tokens. Chinese and Burmese write without
    /// word delimiters, so one grapheme counts as one "word" — the same
    /// per-character convention `WordErrorRate` switches to for Han text;
    /// splitting on whitespace would count a whole Burmese phrase as one word.
    static func words(in text: String, language: Language) -> Int {
        switch language {
        case .chinese, .burmese:
            return text.filter { !$0.isWhitespace }.count
        case .english:
            return text.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// Longest run of consecutive calendar days ending at the latest take.
    static func streak(of dates: [Date], calendar: Calendar) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        guard var day = days.max() else { return 0 }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
