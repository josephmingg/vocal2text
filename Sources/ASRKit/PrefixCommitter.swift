import Foundation

/// LocalAgreement-style prefix commit for streaming preview (docs/15 step 22).
///
/// Successive hypotheses over a growing audio window agree about the past and
/// churn at the end. Displaying each raw hypothesis makes the preview flicker
/// — words appear, mutate, and vanish. This commits the prefix that two
/// consecutive hypotheses agree on: committed words never change again on
/// screen, and only the unstable tail keeps moving.
///
/// The same machinery is the seam for the plan's full commit-the-prefix
/// decode (final accuracy pass over the tail only) once the owner sets the
/// WER tolerance (docs/15 Part 2b, open decision 2). Today its output is
/// display-only per FR-4.1 — the full-utterance batch pass remains the
/// correctness path.
///
/// Agreement is word-level, so this is for whitespace-delimited scripts; the
/// preview route is pinned-English (docs/15 step 22 wiring), which is
/// exactly that.
public struct PrefixCommitter: Sendable {

    private var committedWords: [String] = []
    private var previousWords: [String] = []

    public init() {}

    /// The words committed so far, joined — never shrinks.
    public var committedText: String {
        committedWords.joined(separator: " ")
    }

    /// Ingests the newest hypothesis and returns the line to display:
    /// committed prefix plus the hypothesis's unstable tail.
    public mutating func ingest(_ hypothesis: String) -> String {
        let words = hypothesis.split(whereSeparator: \.isWhitespace).map(String.init)

        // Extend the commitment to the longest common prefix of the last two
        // hypotheses — but never past what is already committed, and never
        // shrinking. A hypothesis that disagrees with committed words cannot
        // retract them (display stability is the whole point); its tail
        // simply takes over after the committed prefix.
        var agreed = 0
        while agreed < words.count, agreed < previousWords.count,
            words[agreed] == previousWords[agreed] {
            agreed += 1
        }
        if agreed > committedWords.count {
            committedWords = Array(words.prefix(agreed))
        }
        previousWords = words

        let tail = words.count > committedWords.count
            ? words.suffix(from: committedWords.count).joined(separator: " ")
            : ""
        if committedWords.isEmpty { return tail }
        if tail.isEmpty { return committedText }
        return committedText + " " + tail
    }
}
