import Foundation

/// The reconciliation core of type-as-you-speak insertion (docs/15 step 46).
///
/// If committed preview text were inserted live, the batch pass's final text
/// must replace it with the minimum visible disturbance: keep the prefix both
/// agree on, delete only the trailing part that differs, type the rest.
///
/// STATUS: the pure half only. Wiring it to live insertion hangs on open
/// owner decision 2 (the WER tolerance for committed-prefix decoding) and on
/// an insertion tier that can delete reliably — until both exist, nothing
/// calls this in production and the preview stays display-only per FR-4.1.
public enum StreamingReconciler {

    /// What to do to the already-inserted text to make it the final text.
    public struct Plan: Equatable, Sendable {
        /// Grapheme clusters to delete from the end of the inserted text
        /// (backspaces, or a ranged AX replacement).
        public var deleteCount: Int
        /// Text to append after the deletions.
        public var append: String

        /// Nothing to do — the live insertion already matches.
        public var isNoOp: Bool { deleteCount == 0 && append.isEmpty }

        public init(deleteCount: Int, append: String) {
            self.deleteCount = deleteCount
            self.append = append
        }
    }

    /// Grapheme-level plan turning `inserted` into `final`.
    public static func plan(inserted: String, final: String) -> Plan {
        let insertedCharacters = Array(inserted)
        let finalCharacters = Array(final)
        var common = 0
        while common < insertedCharacters.count, common < finalCharacters.count,
            insertedCharacters[common] == finalCharacters[common] {
            common += 1
        }
        return Plan(
            deleteCount: insertedCharacters.count - common,
            append: String(finalCharacters[common...])
        )
    }
}
