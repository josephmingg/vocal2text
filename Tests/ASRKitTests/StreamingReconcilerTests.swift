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
        // Common prefix "meet me at n" ends inside the changed word: only
        // "oon" is deleted, never the agreed prefix.
        #expect(plan == .init(deleteCount: 3, append: "ew Orleans"))
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
