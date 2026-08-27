import Foundation
import Testing
@testable import ASRKit

struct StreamingReconcilerTests {

    @Test func identicalTextIsANoOp() {
        let plan = StreamingReconciler.plan(inserted: "hello world", final: "hello world")
        #expect(plan.isNoOp)
    }

    @Test func pureExtensionOnlyAppends() {
        let plan = StreamingReconciler.plan(inserted: "hello", final: "hello world")
        #expect(plan == .init(deleteCount: 0, append: " world"))
    }

    @Test func aRevisedTailDeletesOnlyTheDisagreement() {
        let plan = StreamingReconciler.plan(
            inserted: "meet me at noon",
            final: "meet me at New Orleans"
        )
        // The comparison is case-sensitive, so the common prefix ends at
        // "meet me at " ('n' ≠ 'N'): "noon" is deleted, the agreed prefix
        // never is.
        #expect(plan == .init(deleteCount: 4, append: "New Orleans"))
    }

    @Test func aShorterFinalDeletesTheExcess() {
        let plan = StreamingReconciler.plan(inserted: "hello world", final: "hello")
        #expect(plan == .init(deleteCount: 6, append: ""))
    }

    @Test func emptyInsertedTypesEverything() {
        let plan = StreamingReconciler.plan(inserted: "", final: "hi there")
        #expect(plan == .init(deleteCount: 0, append: "hi there"))
    }

    @Test func graphemesCountAsSingleDeletions() {
        // Emoji with a skin-tone modifier is one grapheme cluster:
        // deleteCount is in graphemes, so a backspace-driven executor
        // deletes exactly one per count.
        let plan = StreamingReconciler.plan(inserted: "ok 👍🏼", final: "ok 👍🏾")
        #expect(plan == .init(deleteCount: 1, append: "👍🏾"))
    }
}
