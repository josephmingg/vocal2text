import Foundation
import Testing
@testable import ASRKit

struct PrefixCommitterTests {

    @Test func nothingCommitsFromASingleHypothesis() {
        var committer = PrefixCommitter()
        let display = committer.ingest("hello world")
        // First hypothesis has nothing to agree with — all of it is tail.
        #expect(display == "hello world")
        #expect(committer.committedText.isEmpty)
    }

    @Test func agreementBetweenConsecutiveHypothesesCommits() {
        var committer = PrefixCommitter()
        _ = committer.ingest("hello world")
        let display = committer.ingest("hello world how are")
        #expect(committer.committedText == "hello world")
        #expect(display == "hello world how are")
    }

    @Test func committedWordsNeverChangeEvenWhenAHypothesisDisagrees() {
        var committer = PrefixCommitter()
        _ = committer.ingest("meet me at noon")
        _ = committer.ingest("meet me at noon tomorrow")
        #expect(committer.committedText == "meet me at noon")
        // A later hypothesis rewrites the past; the committed prefix holds and
        // the disagreeing tail takes over after it.
        let display = committer.ingest("meat me at new orleans")
        #expect(committer.committedText == "meet me at noon")
        #expect(display == "meet me at noon orleans")
    }

    @Test func commitmentIsMonotonic() {
        var committer = PrefixCommitter()
        _ = committer.ingest("one two three")
        _ = committer.ingest("one two three four")
        #expect(committer.committedText == "one two three")
        _ = committer.ingest("one two three four five")
        #expect(committer.committedText == "one two three four")
        // A shorter hypothesis cannot shrink the commitment.
        _ = committer.ingest("one")
        #expect(committer.committedText == "one two three four")
    }

    @Test func twoAgreeingRevisionsCannotRewriteTheCommittedPrefix() {
        var committer = PrefixCommitter()
        _ = committer.ingest("a b")
        _ = committer.ingest("a b")
        #expect(committer.committedText == "a b")
        // The engine revises word 2 and then stabilizes on the revision: the
        // agreement between the two revised hypotheses extends past the
        // commitment, but the words already shown must not change — only the
        // stable continuation appends.
        _ = committer.ingest("a x c")
        let display = committer.ingest("a x c")
        #expect(committer.committedText == "a b c")
        #expect(display == "a b c")
    }

    @Test func emptyHypothesesAreHarmless() {
        var committer = PrefixCommitter()
        #expect(committer.ingest("") == "")
        _ = committer.ingest("hello there")
        _ = committer.ingest("hello there")
        #expect(committer.committedText == "hello there")
        // Silence from the engine mid-stream must not clear the display.
        #expect(committer.ingest("") == "hello there")
    }
}
