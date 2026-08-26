import CoreModels
import Foundation

/// The phrases that mark a spoken self-correction (docs/05 §3.3).
///
/// The prompt tells the model to drop the false start *and* the cue; the
/// validator needs the same list to know that a large collapse was expected
/// rather than a truncation. `PromptCuesMatchValidatorCuesTests` asserts every
/// cue here also appears in the shipped prompt, so the two cannot drift.
public enum SelfCorrectionCues {

    public static let all: [String] = [
        "sorry",
        "i mean",
        "actually",
        "no wait",
        "scratch that",
        "make that",
        "correction",
        "不对",
        "啊不对",
        "我是说",
    ]

    /// The text following the last cue in `input`, or nil when there is none.
    ///
    /// A self-correction means the operative content is what comes *after* the
    /// cue, so that tail — not the whole dictation — is what a cleaned output
    /// should be measured against.
    ///
    /// Matched against `input` itself rather than a lowercased copy: an index
    /// derived from one string is not valid in another, and `lowercased()` does
    /// not preserve length (`İ` U+0130 grows to two scalars, `ẞ` shrinks to
    /// `ß`), so the old spelling could slice the wrong tail or index past the
    /// end and trap. `.caseInsensitive` does the same job safely.
    ///
    /// Boundaries are per script. An English cue must stand as its own word or
    /// "correction" matches inside "corrections", leaving a one-character tail
    /// that disables the floor entirely. Han has no word edges, so the test is
    /// whether the cue begins a new breath group: 「发给张伟，不对，发给李明」 is a
    /// correction and 「这个数字不对，改一下」 is content, and the comma is the only
    /// thing separating them.
    public static func contentAfterLastCue(in input: String) -> String? {
        var bestEnd: String.Index?
        for cue in all {
            let boundary: TokenBoundary = cue.hasLatinWordEdges ? .latinWord : .leadingBreak
            guard
                let range = input.range(
                    ofToken: cue, boundary: boundary, options: [.caseInsensitive, .backwards]
                )
            else { continue }
            if bestEnd == nil || range.upperBound > bestEnd! {
                bestEnd = range.upperBound
            }
        }
        guard let bestEnd else { return nil }
        let tail = input[bestEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}
