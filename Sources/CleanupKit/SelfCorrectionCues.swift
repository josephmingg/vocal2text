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
    public static func contentAfterLastCue(in input: String) -> String? {
        let lowered = input.lowercased()
        var bestEnd: String.Index?
        for cue in all {
            guard let range = lowered.range(of: cue, options: [.backwards]) else { continue }
            if bestEnd == nil || range.upperBound > bestEnd! {
                bestEnd = range.upperBound
            }
        }
        guard let bestEnd else { return nil }
        let tail = input[bestEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}
