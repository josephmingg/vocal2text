import Foundation
import Testing
@testable import CoreModels

struct VocabularySuggestorTests {

    @Test func aRespellingCorrectionIsProposed() {
        let suggestion = VocabularySuggestor.suggestion(
            previousText: "use cloud code to review this",
            currentText: "use Claude Code to review this",
            gapSeconds: 8
        )
        #expect(suggestion == .init(spoken: "cloud code", written: "Claude Code"))
    }

    @Test func aCaseOnlyCorrectionIsProposed() {
        let suggestion = VocabularySuggestor.suggestion(
            previousText: "ping anthropic about it",
            currentText: "ping Anthropic about it",
            gapSeconds: 5
        )
        #expect(suggestion == .init(spoken: "anthropic", written: "Anthropic"))
    }

    @Test func trailingPunctuationDoesNotPolluteTheEntry() {
        let suggestion = VocabularySuggestor.suggestion(
            previousText: "Ask cloud.",
            currentText: "Ask Claude.",
            gapSeconds: 3
        )
        #expect(suggestion == .init(spoken: "cloud", written: "Claude"))
    }

    @Test func aContentChangeIsNotVocabulary() {
        // Swapping one lowercase word for a dissimilar one is editing what
        // was said, not fixing how it was heard.
        #expect(
            VocabularySuggestor.suggestion(
                previousText: "meet me on tuesday morning",
                currentText: "meet me on wednesday morning",
                gapSeconds: 4
            ) == nil
        )
    }

    @Test func aSlowSecondTakeIsANewThought() {
        #expect(
            VocabularySuggestor.suggestion(
                previousText: "use cloud code to review this",
                currentText: "use Claude Code to review this",
                gapSeconds: 90
            ) == nil
        )
    }

    @Test func differentShapesAreNotCorrections() {
        #expect(
            VocabularySuggestor.suggestion(
                previousText: "send the file",
                currentText: "send the file to marketing today",
                gapSeconds: 5
            ) == nil
        )
    }

    @Test func stopWordSwapsAreIgnored() {
        #expect(
            VocabularySuggestor.suggestion(
                previousText: "send a file over",
                currentText: "send the file over",
                gapSeconds: 5
            ) == nil
        )
    }

    @Test func scatteredDifferencesAreNotOneCorrection() {
        #expect(
            VocabularySuggestor.suggestion(
                previousText: "alpha two three beta",
                currentText: "gamma two three delta",
                gapSeconds: 5
            ) == nil
        )
    }
}
