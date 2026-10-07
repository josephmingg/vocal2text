import Foundation
import Testing
@testable import ASRKit

struct TrailingWindowPreviewTests {

    private static let rate = PCMChunk.sampleRate

    /// Words with the given texts, one every half second from `from`.
    private static func words(
        _ texts: [String], from: Double = 0
    ) -> [TranscriptionResult.TimedSegment] {
        texts.enumerated().map {
            .init(text: $0.element, start: from + Double($0.offset) * 0.5,
                  end: from + Double($0.offset) * 0.5 + 0.4)
        }
    }

    @Test func aShortWindowBehavesLikeThePrefixCommitter() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 10, keepSeconds: 4)
        var committer = PrefixCommitter()
        for hypothesis in ["hello", "hello there", "hello there friend"] {
            let texts = hypothesis.split(separator: " ").map(String.init)
            let line = preview.ingest(
                text: hypothesis, words: Self.words(texts), windowSampleCount: 3 * Self.rate
            )
            #expect(line == committer.ingest(hypothesis))
        }
        #expect(preview.windowStart == 0)
    }

    @Test func pastTheWindowCommittedWordsBeforeTheCutFreeze() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        let texts = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        // Two agreeing hypotheses commit the first six words.
        _ = preview.ingest(
            text: "", words: Self.words(Array(texts.prefix(6))), windowSampleCount: 3 * Self.rate
        )
        let line = preview.ingest(
            text: "", words: Self.words(texts), windowSampleCount: 4 * Self.rate
        )
        #expect(line == "one two three four five six seven eight")
        // The cut is at 3 s: "one"…"six" end by 2.9 s and are committed.
        #expect(preview.frozenText == "one two three four five six")
        // The window restarts midway between "six" (ends 2.9 s) and
        // "seven" (starts 3.0 s).
        #expect(preview.windowStart > Int(2.9 * Double(Self.rate)))
        #expect(preview.windowStart < 3 * Self.rate)
    }

    @Test func aWordNotYetCommittedIsNotFrozen() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        _ = preview.ingest(
            text: "", words: Self.words(["one", "two"]), windowSampleCount: 2 * Self.rate
        )
        // "three" ends before the cut but only one hypothesis has it.
        _ = preview.ingest(
            text: "", words: Self.words(["one", "two", "three", "four", "five", "six", "seven"]),
            windowSampleCount: 4 * Self.rate
        )
        #expect(preview.frozenText == "one two")
    }

    @Test func committedWordsTheHypothesisNoLongerAgreesWithAreNotFrozen() {
        // Freezing uses the hypothesis's timings, so it may only freeze words
        // the hypothesis agrees with — otherwise "meat me"'s timings would
        // cut the audio under the committed "meet me".
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        _ = preview.ingest(text: "", words: Self.words(["meet", "me", "at"]), windowSampleCount: 2 * Self.rate)
        _ = preview.ingest(
            text: "", words: Self.words(["meet", "me", "at", "noon"]), windowSampleCount: 3 * Self.rate
        )
        let line = preview.ingest(
            text: "", words: Self.words(["meat", "me", "at", "noon", "today", "please", "now"]),
            windowSampleCount: 4 * Self.rate
        )
        #expect(line.hasPrefix("meet me at"))
        #expect(preview.frozenText.isEmpty)
        #expect(preview.windowStart == 0)
    }

    @Test func theLineStaysTheSameAcrossASlide() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        let texts = ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8"]
        _ = preview.ingest(text: "", words: Self.words(Array(texts.prefix(6))), windowSampleCount: 3 * Self.rate)
        let before = preview.ingest(text: "", words: Self.words(texts), windowSampleCount: 4 * Self.rate)
        // The next hypothesis covers only the new window: "a7", "a8" and a
        // new word, with times relative to the new window start.
        let after = preview.ingest(
            text: "", words: Self.words(["a7", "a8", "a9"], from: 0.05),
            windowSampleCount: 2 * Self.rate
        )
        #expect(before == "a1 a2 a3 a4 a5 a6 a7 a8")
        #expect(after == "a1 a2 a3 a4 a5 a6 a7 a8 a9")
    }

    @Test func silenceSlidesTheWindow() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        _ = preview.ingest(text: "", words: [], windowSampleCount: 5 * Self.rate)
        #expect(preview.windowStart == 4 * Self.rate)
        #expect(preview.frozenText.isEmpty)
    }

    @Test func textWithoutTimingsNeverSlides() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        _ = preview.ingest(text: "hello there", words: [], windowSampleCount: 5 * Self.rate)
        _ = preview.ingest(text: "hello there", words: [], windowSampleCount: 9 * Self.rate)
        #expect(preview.windowStart == 0)
    }

    @Test func withoutAgreementTheWindowStillSlidesPastTwiceItsSize() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        // Every hypothesis disagrees from the first word, so nothing commits.
        _ = preview.ingest(text: "", words: Self.words(["x", "y"]), windowSampleCount: 4 * Self.rate)
        #expect(preview.windowStart == 0)
        let many = (0..<14).map { "w\($0)" }
        _ = preview.ingest(text: "", words: Self.words(many), windowSampleCount: 7 * Self.rate)
        // Cut at 6 s: w0…w11 end by 5.9 s.
        #expect(preview.frozenText == many.prefix(12).joined(separator: " "))
        #expect(preview.windowStart > 0)
    }

    @Test func tokensGroupIntoWordsOnLeadingSpaces() {
        let tokens: [TranscriptionResult.TimedSegment] = [
            .init(text: " he", start: 0.0, end: 0.1),
            .init(text: "llo", start: 0.1, end: 0.2),
            .init(text: " world", start: 0.3, end: 0.5),
            .init(text: ".", start: 0.5, end: 0.55),
            .init(text: " ", start: 0.6, end: 0.6),
            .init(text: "again", start: 0.7, end: 0.9),
        ]
        let words = TranscriptionResult.TimedSegment.words(fromTokens: tokens)
        #expect(words.map(\.text) == ["hello", "world.", "again"])
        #expect(words[0].start == 0.0 && words[0].end == 0.2)
        #expect(words[1].end == 0.55)
    }

    @Test func aFirstTokenWithoutASpaceStillStartsAWord() {
        let tokens: [TranscriptionResult.TimedSegment] = [
            .init(text: "Hi", start: 0, end: 0.1),
            .init(text: " there", start: 0.2, end: 0.3),
        ]
        #expect(TranscriptionResult.TimedSegment.words(fromTokens: tokens).map(\.text) == ["Hi", "there"])
    }

    @Test func aSeededCommitterKeepsItsWords() {
        var committer = PrefixCommitter(committedWords: ["keep", "these"])
        #expect(committer.committedText == "keep these")
        let line = committer.ingest("keep these and more")
        #expect(line == "keep these and more")
        #expect(committer.committedText == "keep these")
    }
}

struct VocabularyBoostTests {

    @Test func keepsEnglishWordsAndDropsWhatTheSpotterCannotUse() {
        let terms = [
            "sync", "Kubernetes", "vocal2text", "Wi-Fi", "O'Brien",
            "ok",                                   // too short
            String(repeating: "a", count: 41),      // too long
            "Line one\nline two",                   // multi-line
            "北京",                                  // not English letters
            "1234",                                 // no letter
            "SYNC",                                 // duplicate in another case
        ]
        #expect(VocabularyBoost.eligibleTerms(terms) == ["sync", "Kubernetes", "vocal2text", "Wi-Fi", "O'Brien"])
    }

    @Test func theCapKeepsTheFirstTerms() {
        let terms = (0..<300).map { "term\($0)" }
        let eligible = VocabularyBoost.eligibleTerms(terms)
        #expect(eligible.count == VocabularyBoost.maxTerms)
        #expect(eligible.first == "term0")
        #expect(eligible.last == "term\(VocabularyBoost.maxTerms - 1)")
    }
}
