import Foundation
import Testing
@testable import TextPipeline

/// docs/15 step 51: deterministic spoken-number formatting. Skipping a
/// conversion is always acceptable; converting the wrong thing never is —
/// so the negative cases here matter as much as the positive ones.
struct SpokenNumberFormatterTests {

    // MARK: - Times

    @Test(
        "times with minutes and a meridiem convert",
        arguments: [
            ("let's meet at three thirty pm", "let's meet at 3:30 pm"),
            ("the call is at eleven fifteen am", "the call is at 11:15 am"),
            ("three oh five pm works", "3:05 pm works"),
            ("nine forty five p.m. at the latest", "9:45 p.m. at the latest"),
            ("twelve twenty pm sharp", "12:20 pm sharp"),
        ]
    )
    func timesWithMinutesConvert(input: String, expected: String) {
        #expect(SpokenNumberFormatter.apply(input) == expected)
    }

    @Test func hourOnlyTimesNeedAPreposition() {
        #expect(
            SpokenNumberFormatter.apply("see you at three pm") == "see you at 3 pm"
        )
        // "one am" inside ordinary prose must never become "1 am".
        #expect(
            SpokenNumberFormatter.apply("which one am I supposed to take")
                == "which one am I supposed to take"
        )
    }

    // MARK: - Years

    @Test(
        "two-part years convert",
        arguments: [
            ("the plan ships in twenty twenty six", "the plan ships in 2026"),
            ("back in twenty sixteen we tried", "back in 2016 we tried"),
            ("since nineteen ninety five", "since 1995"),
            ("in two thousand and five it changed", "in 2005 it changed"),
            ("by two thousand thirty", "by 2030"),
            ("in twenty twenty it started", "in 2020 it started"),
        ]
    )
    func yearsConvert(input: String, expected: String) {
        #expect(SpokenNumberFormatter.apply(input) == expected)
    }

    @Test(
        "year look-alikes stay words",
        arguments: [
            "she has twenty twenty vision",
            "hindsight is twenty twenty",
            "the benefit of twenty twenty vision",
            "twenty one people came",
            "two thousand five hundred units",
            "two thousand people attended",
        ]
    )
    func yearLookAlikesStayWords(input: String) {
        #expect(SpokenNumberFormatter.apply(input) == input)
    }

    // MARK: - Percent

    @Test(
        "percentages convert",
        arguments: [
            ("fifty percent of users", "50% of users"),
            ("twenty five percent more", "25% more"),
            ("a hundred percent sure", "100% sure"),
            ("one hundred percent done", "100% done"),
            ("zero percent interest", "0% interest"),
        ]
    )
    func percentagesConvert(input: String, expected: String) {
        #expect(SpokenNumberFormatter.apply(input) == expected)
    }

    // MARK: - Stage-4 gating

    @Test func verbatimProfilesKeepTheSpokenWords() {
        let out = Stage4Formatter.format(
            "meet at three thirty pm",
            language: .english,
            formatting: .verbatim,
            precedingContext: nil
        )
        #expect(out == "meet at three thirty pm")
    }

    @Test func defaultFormattingAppliesInStage4() {
        let out = Stage4Formatter.format(
            "meet at three thirty pm",
            language: .english,
            formatting: .init(),
            precedingContext: nil
        )
        #expect(out == "meet at 3:30 pm")
    }
}
