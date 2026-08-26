import BenchKit
import CoreModels
import Foundation
import Testing

@Suite struct UsageStatsTests {
    // Deterministic day boundaries regardless of the CI host's locale.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func record(
        daysAgo: Int,
        text: String = "one two three",
        language: Language = .english,
        seconds: Double = 6,
        source: TranscriptSource = .dictation,
        cancelled: Bool = false,
        postRelease: Double = 0
    ) -> TranscriptRecord {
        TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400),
            source: source,
            language: language,
            rawText: text,
            deliveredText: text,
            durationSeconds: seconds,
            profileName: "Default",
            routeKind: .defaultRoute,
            cleanup: .skipped(reason: .masterSwitchOff),
            timings: TimingBreakdown(transcriptionSeconds: postRelease),
            isCancelled: cancelled
        )
    }

    @Test func emptyHistoryIsAllZeros() {
        #expect(UsageStats.compute(records: [], calendar: Self.utc) == UsageStats())
    }

    @Test func countsWordsSecondsAndWPM() {
        let stats = UsageStats.compute(
            records: [
                Self.record(daysAgo: 0, text: "hello brave new world", seconds: 12),
                Self.record(daysAgo: 0, text: "two words", seconds: 18),
            ],
            calendar: Self.utc
        )
        #expect(stats.takeCount == 2)
        #expect(stats.wordCount == 6)
        #expect(stats.speakingSeconds == 30)
        #expect(stats.wordsPerMinute == 12) // 6 words in half a minute
    }

    @Test func importsAndCancelledTakesAreExcluded() {
        let stats = UsageStats.compute(
            records: [
                Self.record(daysAgo: 0),
                Self.record(daysAgo: 0, source: .fileImport),
                Self.record(daysAgo: 0, cancelled: true),
            ],
            calendar: Self.utc
        )
        #expect(stats.takeCount == 1)
        #expect(stats.wordCount == 3)
    }

    @Test func recoveredTakesCountAsSpoken() {
        let stats = UsageStats.compute(
            records: [Self.record(daysAgo: 0, source: .recovered)],
            calendar: Self.utc
        )
        #expect(stats.takeCount == 1)
    }

    @Test func unspacedScriptsCountCharactersNotWhitespaceTokens() {
        #expect(UsageStats.words(in: "你好 世界", language: .chinese) == 4)
        #expect(UsageStats.words(in: "hello world", language: .english) == 2)
        // One Burmese phrase, no spaces — must not count as a single word.
        #expect(UsageStats.words(in: "မင်္ဂလာပါ", language: .burmese) > 1)
    }

    @Test func streakCountsBackFromLatestTakeDay() {
        let stats = UsageStats.compute(
            records: [
                Self.record(daysAgo: 0),
                Self.record(daysAgo: 1),
                Self.record(daysAgo: 2),
                // Gap at 3 days ago ends the streak.
                Self.record(daysAgo: 4),
            ],
            calendar: Self.utc
        )
        #expect(stats.streakDays == 3)
    }

    @Test func multipleTakesOnOneDayCountOnce() {
        let stats = UsageStats.compute(
            records: [Self.record(daysAgo: 0), Self.record(daysAgo: 0)],
            calendar: Self.utc
        )
        #expect(stats.streakDays == 1)
    }

    @Test func medianLatencyIgnoresTakesWithoutTimings() {
        let stats = UsageStats.compute(
            records: [
                Self.record(daysAgo: 0, postRelease: 0), // pre-timing row
                Self.record(daysAgo: 0, postRelease: 1.0),
                Self.record(daysAgo: 0, postRelease: 3.0),
                Self.record(daysAgo: 0, postRelease: 5.0),
            ],
            calendar: Self.utc
        )
        #expect(stats.medianFeltLatencySeconds == 3.0)
    }
}
