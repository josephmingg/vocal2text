import CoreModels
import Foundation
import Testing
import TextPipeline

/// Stress test (docs/17 §10): real-life English dictations, written the way
/// Whisper actually emits them, through stage 1 → stage 4 → style for every
/// style. The invariants are the ones a user would notice breaking: nothing
/// they said disappears (fillers aside), numbers / emails / URLs survive,
/// running the pipeline twice changes nothing, and no stray spacing.
private let corpus: [String] = [
    // Email and docs
    "Hi Sarah, thanks for the update. I'll review the draft by Friday and send comments.",
    "Um, could you send me the Q3 report? I need it before the 2 p.m. meeting.",
    "Please find attached the invoice for $1,250.00, due on March 15th, 2027.",
    "The meeting moved to Room 4B on the 3rd floor.",
    "Best regards, Joseph.",
    "We grew revenue 23% year over year, to $4.2 million.",
    "Let's check in in five minutes.",
    "I need to log in in the morning before standup.",
    "What it was was a misunderstanding.",
    "Can you turn it on on Monday?",
    // Chat
    "Sounds good to me",
    "lol that's hilarious",
    "Running 10 minutes late, sorry!",
    "Are you free for lunch tomorrow?",
    "Wait... are you serious?",
    "Thanks!!",
    // Numbers, IDs, contact details
    "My number is 555-0142 and my PIN is 1212121212.",
    "The order ID is 100000000, not 10000000.",
    "Email me at joseph.ming@example.com or ping @joseph on Slack.",
    "The docs are at https://developer.apple.com/documentation/swift.",
    "Version 2.10.3 fixed the crash in iOS 17.4.",
    "Set the timeout to 0.5 seconds and the retries to 3.",
    "Call extension 0000 0000 for support.",
    // Code and tech talk
    "Run git status, then git commit -m \"fix the build\".",
    "The useState hook re-renders the component when the state changes.",
    "Install it with npm install --save-dev typescript.",
    "Open the config at ~/.zshrc and add export PATH.",
    "The API returns a 404 when the JWT expires.",
    "Rename userId to accountId in the GraphQL schema.",
    "Use Kubernetes with Helm charts on AWS EKS.",
    "A divider like ======== separates the sections.",
    // Disfluency
    "Um, I think, uh, we should go with the second option.",
    "I I think the the plan works.",
    "So, uh, the build is green now.",
    "Hmm, let me check the numbers again.",
    "She's in the ER right now.",
    "Uh oh, the deploy failed.",
    // Names, acronyms, mixed case
    "Ask Siobhan and Nguyen about the McKinsey deck.",
    "The iPhone and the MacBook Pro both use Apple Silicon.",
    "NASA and the ESA launched it from Cape Canaveral.",
    "I met O'Brien at the U.S. embassy.",
    // Quotes, parentheses, lists
    "She said \"ship it\" and left (for real this time).",
    "First, open the app. Second, sign in. Third, tap sync.",
    "The options are: red, green, or blue.",
    // Long-form
    "Okay so the plan for next week is to finish the onboarding flow, fix the three bugs QA found, and write the release notes before Thursday.",
    "I wanted to follow up on our conversation yesterday about the budget. We agreed on 15% for marketing, but finance flagged that the number assumed last year's headcount.",
]

private let fillers: Set<String> = ["um", "uh", "er", "erm", "hmm", "umm", "uhh"]

private func styledPipeline(_ text: String, _ style: DictationStyle) -> String {
    var formatting = FormattingOptions()
    if style == .raw {
        formatting = .verbatim
        formatting.smartSpacing = true
    }
    let stage1 = Stage1Normalizer.normalize(text, language: .english, formatting: formatting)
    let stage4 = Stage4Formatter.format(stage1, language: .english, formatting: formatting, precedingContext: nil)
    return StyleFormatter.apply(stage4, style: style, language: .english, protectedTerms: [])
}

private func contentWords(_ text: String) -> Set<String> {
    Set(
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
            .filter { !fillers.contains($0) }
    )
}

/// Digit runs, emails and URLs — what must arrive byte-for-byte.
private func exactTokens(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).compactMap { raw in
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:\"()"))
        if token.contains("@") || token.contains("://") || token.contains(where: \.isNumber) {
            return token
        }
        return nil
    }
}

@Test(arguments: DictationStyle.allCases)
func realLifeDictationsSurviveEveryStyle(style: DictationStyle) {
    for input in corpus {
        let output = styledPipeline(input, style)
        let context = "[\(style.rawValue)] \(input) → \(output)"

        #expect(!output.isEmpty, "emptied: \(context)")
        #expect(styledPipeline(output, style) == output, "not idempotent: \(context)")
        #expect(!output.contains("  "), "double space: \(context)")
        for mark in [" ,", " .", " !", " ?"] where !input.contains(mark) {
            #expect(!output.contains(mark), "space before punctuation: \(context)")
        }
        // Numbers, emails and URLs arrive exactly (case aside for lowercase).
        let outputTokens = Set(exactTokens(output).map { $0.lowercased() })
        for token in exactTokens(input) {
            #expect(outputTokens.contains(token.lowercased()), "lost \(token): \(context)")
        }
        // Nothing the speaker said disappears, except fillers and the
        // stutters the cleanup exists to collapse (which keep one copy).
        let missing = contentWords(input).subtracting(contentWords(output))
        #expect(missing.isEmpty, "lost words \(missing): \(context)")
        if style == .raw {
            #expect(output == input, "raw changed the text: \(context)")
        }
    }
}

/// Evidence of what the pipeline actually does to a few hard cases (the
/// expectations pin the behaviour the docs/17 fixes promise).
@Test func representativeTransformations() {
    #expect(styledPipeline("Um, I think, uh, we should go with the second option.", .standard)
        == "I think we should go with the second option.")
    #expect(styledPipeline("I I think the the plan works.", .standard) == "I think the plan works.")
    #expect(styledPipeline("Let's check in in five minutes.", .standard) == "Let's check in in five minutes.")
    #expect(styledPipeline("The order ID is 100000000, not 10000000.", .standard)
        == "The order ID is 100000000, not 10000000.")
    #expect(styledPipeline("Wait... are you serious?", .standard) == "Wait. Are you serious?")
    #expect(styledPipeline("Sounds good to me", .casual) == "Sounds good to me")
    #expect(styledPipeline("Running 10 minutes late, sorry!", .lowercase) == "running 10 minutes late, sorry!")
    #expect(styledPipeline("The API returns a 404 when the JWT expires.", .lowercase)
        == "the API returns a 404 when the JWT expires")
}
