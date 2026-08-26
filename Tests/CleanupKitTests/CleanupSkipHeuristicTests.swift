import CoreModels
import Foundation
import Testing
@testable import CleanupKit

/// The step-20 skip heuristic (docs/15): skipping is the risky direction, so
/// these tests pin exactly which signals force the model to run — and that a
/// genuinely clean utterance is allowed to skip the round-trip.
struct CleanupSkipHeuristicTests {

    // MARK: - Skippable

    @Test(
        "clean single-clause utterances skip",
        arguments: [
            "let's meet on saturday",
            "send the invoice to accounting",
            "周五下午三点开会",
        ]
    )
    func cleanShortUtterancesSkip(text: String) {
        let language: Language = text.first.map(\.isASCII) == true ? .english : .chinese
        #expect(CleanupSkipHeuristic.canSkip(text, language: language))
    }

    @Test func aLongUtteranceWithInternalPunctuationSkips() {
        let text = "I reviewed the draft this morning, fixed the two typos in the "
            + "second section, and sent it back to the editors for another pass"
        #expect(CleanupSkipHeuristic.canSkip(text, language: .english))
    }

    @Test func emptyTextSkips() {
        #expect(CleanupSkipHeuristic.canSkip("   ", language: .english))
    }

    // MARK: - Must run

    @Test(
        "fillers force the model to run",
        arguments: [
            "um so I was thinking uh we should ship on Friday",
            "hmm right yeah I think that works for me",
            "you know it might be fine",
            "嗯，就是说，我们明天再讨论",
        ]
    )
    func fillersForceARun(text: String) {
        let language: Language = text.first.map(\.isASCII) == true ? .english : .chinese
        #expect(!CleanupSkipHeuristic.canSkip(text, language: language))
    }

    @Test(
        "correction cues force the model to run",
        arguments: [
            "let's meet Friday sorry Saturday",
            "send it to Mark no I mean Marcus",
            "the file is in downloads wait no it's on the desktop",
            "it costs about fifty dollars or rather fifteen",
        ]
    )
    func correctionCuesForceARun(text: String) {
        #expect(!CleanupSkipHeuristic.canSkip(text, language: .english))
    }

    @Test(
        "Chinese corrections force the model to run",
        arguments: [
            "周五，啊不对，周六",
            "三点开会，啊不是，四点半",
            "先部署到测试环境，我是说生产环境",
        ]
    )
    func chineseCorrectionsForceARun(text: String) {
        #expect(!CleanupSkipHeuristic.canSkip(text, language: .chinese))
    }

    @Test func aStutterForcesARun() {
        #expect(
            !CleanupSkipHeuristic.canSkip(
                "can you send me the the invoice again", language: .english
            )
        )
    }

    @Test func aLongUnpunctuatedRambleForcesARun() {
        // Adding structure to a run-on is precisely the model's job.
        let text = "so the deploy failed twice last night because the runner ran "
            + "out of disk and then the retry hit the rate limit and nobody saw "
            + "the alert until this morning when the dashboard went red"
        #expect(!CleanupSkipHeuristic.canSkip(text, language: .english))
    }

    // MARK: - Boundary safety

    @Test func fillersDoNotFireInsideWords() {
        // "um" in "album", "er" in "server" — token boundaries, not substrings.
        #expect(CleanupSkipHeuristic.canSkip("the album is on the server", language: .english))
    }
}
