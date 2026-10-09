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

    /// Commits a1…a6 and slides past them, leaving `carried` committed but
    /// unfrozen (they end after the cut at 3 s).
    private static func previewAfterASlide() -> TrailingWindowPreview {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        let texts = (1...7).map { "a\($0)" }
        _ = preview.ingest(text: "", words: Self.words(texts), windowSampleCount: 3 * Self.rate)
        // Words of 0.4 s every 0.5 s: a1…a6 end by 2.9 s, a7 ends at 3.4 s.
        _ = preview.ingest(text: "", words: Self.words(texts), windowSampleCount: 4 * Self.rate)
        return preview
    }

    @Test func capitalsAndPunctuationDoNotBreakAgreement() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        _ = preview.ingest(
            text: "", words: Self.words(["hello", "there", "my", "friend"]), windowSampleCount: 2 * Self.rate
        )
        // Parakeet re-decodes with a capital and a comma: still the same words.
        _ = preview.ingest(
            text: "", words: Self.words(["Hello,", "there", "my", "friend", "how", "are", "you", "today"]),
            windowSampleCount: 4 * Self.rate
        )
        // Committed words keep the spelling of the hypothesis that committed
        // them, and that is what freezes.
        #expect(preview.frozenText == "Hello, there my friend")
    }

    @Test func aWindowThatDropsTheFirstCarriedWordKeepsIt() {
        var preview = Self.previewAfterASlide()
        #expect(preview.frozenText == "a1 a2 a3 a4 a5 a6")
        // The carried word a7 is committed but not frozen. The new window
        // starts mid-a7 and does not hear it.
        let line = preview.ingest(
            text: "", words: Self.words(["a8", "a9"], from: 0.5), windowSampleCount: 2 * Self.rate
        )
        #expect(line == "a1 a2 a3 a4 a5 a6 a7 a8 a9")
    }

    @Test func aWindowThatRepeatsTheLastFrozenWordShowsItOnce() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        let texts = (1...6).map { "a\($0)" }
        _ = preview.ingest(text: "", words: Self.words(texts), windowSampleCount: 3 * Self.rate)
        _ = preview.ingest(text: "", words: Self.words(texts), windowSampleCount: 4 * Self.rate)
        #expect(preview.frozenText == texts.joined(separator: " "))
        // A cut without a pause: the new window hears the end of a6 again.
        let line = preview.ingest(
            text: "", words: Self.words(["a6", "a7"], from: 0.0), windowSampleCount: 2 * Self.rate
        )
        #expect(line == "a1 a2 a3 a4 a5 a6 a7")
    }

    @Test func theCutPrefersAPause() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        // Fluent speech: words touch, except a pause after "two".
        let words: [TranscriptionResult.TimedSegment] = [
            .init(text: "one", start: 0.0, end: 0.5),
            .init(text: "two", start: 0.5, end: 1.0),
            .init(text: "three", start: 1.5, end: 2.0),
            .init(text: "four", start: 2.0, end: 2.5),
            .init(text: "five", start: 2.5, end: 3.5),
        ]
        _ = preview.ingest(text: "", words: words, windowSampleCount: 3 * Self.rate)
        _ = preview.ingest(text: "", words: words, windowSampleCount: 4 * Self.rate)
        // "four" also ends before the cut, but only "two" is followed by a pause.
        #expect(preview.frozenText == "one two")
        #expect(preview.windowStart == Int(1.25 * Double(Self.rate)))
    }

    @Test func silenceAfterSpeechKeepsTheCommittedWords() {
        var preview = TrailingWindowPreview(maxWindowSeconds: 3, keepSeconds: 1)
        _ = preview.ingest(text: "", words: Self.words(["hi", "there"]), windowSampleCount: 2 * Self.rate)
        _ = preview.ingest(text: "", words: Self.words(["hi", "there"]), windowSampleCount: 3 * Self.rate)
        // The engine now hears nothing in the window: the words stay shown.
        let line = preview.ingest(text: "", words: [], windowSampleCount: 5 * Self.rate)
        #expect(line == "hi there")
        #expect(preview.frozenText == "hi there")
        let next = preview.ingest(text: "", words: Self.words(["again"]), windowSampleCount: 2 * Self.rate)
        #expect(next == "hi there again")
    }

    @Test func sameWordIgnoresCaseAndEdgePunctuation() {
        #expect(PrefixCommitter.sameWord("Seven,", "seven"))
        #expect(PrefixCommitter.sameWord("\"quote\"", "Quote"))
        #expect(!PrefixCommitter.sameWord("meet", "meat"))
        #expect(PrefixCommitter.sameWord("—", "—"))
        #expect(!PrefixCommitter.sameWord("—", "."))
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
