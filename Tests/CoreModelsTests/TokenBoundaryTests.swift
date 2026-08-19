import CoreModels
import Foundation
import Testing

// MARK: - Latin word boundaries

@Test func latinWordBoundaryRejectsAMatchInsideALongerWord() {
    #expect("unfortunately that is factually correct"
        .range(ofToken: "actually", boundary: .latinWord) == nil)
    #expect("let's review the corrections"
        .range(ofToken: "correction", boundary: .latinWord) == nil)
    #expect("the AI meant well".range(ofToken: "i mean", boundary: .latinWord) == nil)
}

@Test func latinWordBoundaryAcceptsAStandaloneMatch() throws {
    let text = "ship it on the tenth, I mean the twelfth"
    let range = try #require(text.range(ofToken: "i mean", boundary: .latinWord,
                                        options: [.caseInsensitive]))
    #expect(text[range.upperBound...] == " the twelfth")
}

/// The subtle half of a backwards search: the *last* occurrence can be the
/// embedded one, and giving up there would report "no cue" for a sentence that
/// plainly has one.
@Test func backwardsSearchWalksPastARejectedCandidate() throws {
    let text = "actually, that is factually true"
    let range = try #require(text.range(ofToken: "actually", boundary: .latinWord,
                                        options: [.backwards]))
    #expect(range.lowerBound == text.startIndex)
}

/// Overlapping candidates must not spin the walk forever in either direction:
/// every rejected match has to shrink the remaining range, not merely move.
@Test func anUnboundedNeedleTerminatesTheWalk() {
    #expect("aaaa".range(ofToken: "aa", boundary: .latinWord) == nil)
    #expect("aaaa".range(ofToken: "aa", boundary: .latinWord, options: [.backwards]) == nil)
}

// MARK: - Leading break (scripts with no word edges)

@Test func leadingBreakRejectsACueContinuingAWord() {
    // 「不对」 here means "is wrong" — it is what the speaker is saying, not a
    // marker that they are replacing something.
    #expect("这个数字不对，改一下".range(ofToken: "不对", boundary: .leadingBreak) == nil)
}

@Test func leadingBreakAcceptsACueAfterAPause() throws {
    let text = "发给张伟，不对，发给李明"
    let range = try #require(text.range(ofToken: "不对", boundary: .leadingBreak))
    #expect(text[range.upperBound...] == "，发给李明")
}

@Test func leadingBreakAcceptsACueAtTheStart() {
    #expect("不对，这个数字对不上".range(ofToken: "不对", boundary: .leadingBreak) != nil)
}

// MARK: - Passthrough and edges

@Test func noBoundaryIsPlainContainment() {
    #expect("album".range(ofToken: "um", boundary: .none) != nil)
    #expect("album".range(ofToken: "um", boundary: .latinWord) == nil)
}

@Test func anEmptyNeedleMatchesNothing() {
    #expect("anything".range(ofToken: "", boundary: .latinWord) == nil)
    #expect("anything".range(ofToken: "", boundary: .none) == nil)
}

@Test func hanAndMyanmarLettersDoNotExtendALatinToken() {
    // 「我们先review一下」 — `review` is bounded by 先 and 一, not continued by them.
    #expect("我们先review一下".range(ofToken: "review", boundary: .latinWord) != nil)
    #expect(Character("先").continuesLatinWord == false)
    #expect(Character("မ").continuesLatinWord == false)
    #expect(Character("r").continuesLatinWord)
    #expect(Character("’").continuesLatinWord)
}

@Test func latinEdgesAreDetectedPerScript() {
    #expect("sorry".hasLatinWordEdges)
    #expect("scratch that".hasLatinWordEdges)
    #expect("不对".hasLatinWordEdges == false)
    #expect("".hasLatinWordEdges == false)
}
