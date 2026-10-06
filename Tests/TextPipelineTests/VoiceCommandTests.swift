import Foundation
import Testing
import TextPipeline

/// docs/17 G4: the wake word and the deterministic local tools.
struct VoiceCommandParserTests {

    @Test(arguments: [
        ("Vocal, make this shorter.", "Make this shorter."),
        ("vocal: translate this into Spanish", "Translate this into Spanish"),
        ("Hey Vocal, what's 15% of 240?", "What's 15% of 240?"),
        ("Hey vocal make it more formal", "Make it more formal"),
        ("OK Vocal, summarize this", "Summarize this"),
        ("Vocal make this a bullet list", "Make this a bullet list"),
        ("Hey, Vocal, summarize this.", "Summarize this."),
        ("Vocal what's 15% of 240?", "What's 15% of 240?"),
        ("Vocal: summarize this", "Summarize this"),
    ])
    func wakeWordStartsACommand(take: String, instruction: String) {
        #expect(VoiceCommandParser.instruction(afterWakeWordIn: take) == instruction)
    }

    @Test(arguments: [
        "Vocal cords need rest after a long talk.",
        "Vocal music is on tonight.",
        "I told Vocal, make this shorter.",
        "The vocal, as always, was great.",
        "Make this shorter.",
        "Vocal,",
        "Hey vocal",
        // docs/17 §11 round 2: ordinary sentences that used to trigger.
        "Okay vocal warmups first, then scales.",
        "Hey vocal coach, nice job today.",
        "Vocal: Sarah. Drums: Tom.",
        "Vocal - the band - played well.",
        "Vocal list for the concert is ready.",
        "Vocal what a performance that was.",
        "Vocal how-to videos are popular.",
        "OK Vocal.",
    ])
    func ordinaryProseIsNotACommand(take: String) {
        #expect(VoiceCommandParser.instruction(afterWakeWordIn: take) == nil)
    }
}

struct LocalCommandToolsTests {
    private let noon = Date(timeIntervalSince1970: 1_791_288_000)  // Tue 2026-10-06 12:00 UTC
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func answer(_ text: String) -> String? {
        LocalCommandTools.answer(text, now: noon, locale: us, timeZone: utc)
    }

    @Test(arguments: [
        ("What's 15% of 240?", "36"),
        ("15 percent of 240", "36"),
        ("What is 12 times 7?", "84"),
        ("12 x 7", "84"),
        ("250 divided by 4", "62.5"),
        ("Calculate 1,200 plus 300.", "1500"),
        ("10 minus 4", "6"),
        ("2 to the power of 8", "256"),
        ("1 divided by 3", "0.333333"),
        ("What's 1,000,000 times 3?", "3000000"),
        ("2 to the power of 64", "1.8446744073709552e+19"),
    ])
    func arithmetic(question: String, expected: String) {
        #expect(answer(question) == expected)
    }

    @Test func divisionByZeroIsLeftToTheModel() {
        #expect(answer("5 divided by 0") == nil)
    }

    @Test func dateAndDay() {
        #expect(answer("What's the date today?") == "Tuesday, October 6, 2026")
        #expect(answer("What day is it?") == "Tuesday")
        #expect(answer("What time is it?") == "12:00\u{202F}PM" || answer("What time is it?") == "12:00 PM")
        #expect(answer("What day is it today?") == "Tuesday")
        #expect(answer("What's the time right now?") == answer("What time is it?"))
    }

    /// A question about another place or day must not get the local answer
    /// (docs/17 §11 round 2).
    @Test(arguments: [
        "What time is it in Tokyo?",
        "What day is it tomorrow?",
        "What's the date next Friday?",
        "What time is it there?",
    ])
    func otherPlacesAndDaysGoToTheModel(text: String) {
        #expect(answer(text) == nil)
    }

    @Test(arguments: [
        "Make this shorter",
        "Write a polite reply declining the meeting",
        "What's the capital of France?",
        "3 and 4",
        "What's 1,2 plus 1?",
    ])
    func everythingElseGoesToTheModel(text: String) {
        #expect(answer(text) == nil)
    }
}
