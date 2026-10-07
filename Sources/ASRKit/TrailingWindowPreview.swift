import Foundation

/// The streaming preview's decode window (docs/17 F7, G2.3).
///
/// The preview used to re-decode the whole take on every tick, so a
/// five-minute hands-free take re-decoded five minutes of audio about once a
/// second, and a release landing mid-decode waited behind it. This keeps the
/// decoded audio bounded: once the window passes `maxWindowSeconds`, the
/// committed words that end before the last `keepSeconds` are frozen, and
/// the window restarts in the gap after the last frozen word. Only the
/// trailing window is decoded from then on.
///
/// Display stability is preserved: only words the `PrefixCommitter` already
/// committed are frozen, and the committed words still inside the new window
/// seed the next committer. The preview stays display-only (FR-4.1); the
/// delivered text always comes from the full-take batch pass.
public struct TrailingWindowPreview: Sendable {

    /// Absolute sample index where the next decode window starts.
    public private(set) var windowStart = 0

    private var frozenWords: [String] = []
    private var committer = PrefixCommitter()
    private let maxWindowSamples: Int
    private let keepSamples: Int

    /// - Parameters:
    ///   - maxWindowSeconds: The longest window decoded before it slides.
    ///     The default fits Parakeet's single 15 s pass.
    ///   - keepSeconds: Audio kept at the end of the window when it slides,
    ///     so the words still settling are re-decoded with context.
    public init(maxWindowSeconds: Double = 14, keepSeconds: Double = 6) {
        let rate = Double(PCMChunk.sampleRate)
        maxWindowSamples = max(1, Int(maxWindowSeconds * rate))
        keepSamples = max(0, min(Int(keepSeconds * rate), maxWindowSamples - 1))
    }

    /// Words frozen out of the window so far.
    public var frozenText: String { frozenWords.joined(separator: " ") }

    /// Ingests the hypothesis for the window that starts at `windowStart`
    /// and holds `windowSampleCount` samples, and returns the line to show.
    ///
    /// `words` are word timings in seconds from the window's first sample,
    /// as engines report them. An engine without timings passes none: the
    /// window then only slides past silence, and otherwise keeps growing
    /// like the old whole-take preview.
    public mutating func ingest(
        text: String,
        words: [TranscriptionResult.TimedSegment],
        windowSampleCount: Int
    ) -> String {
        let hypothesisWords = words.isEmpty
            ? text.split(whereSeparator: \.isWhitespace).map(String.init)
            : words.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let windowLine = committer.ingest(hypothesisWords.joined(separator: " "))
        let display = Self.join(frozenText, windowLine)
        slideIfNeeded(text: text, words: words, windowSampleCount: windowSampleCount)
        return display
    }

    private mutating func slideIfNeeded(
        text: String,
        words: [TranscriptionResult.TimedSegment],
        windowSampleCount: Int
    ) {
        guard windowSampleCount > maxWindowSamples else { return }
        let rate = Double(PCMChunk.sampleRate)
        let cutSeconds = Double(windowSampleCount - keepSamples) / rate

        guard !words.isEmpty else {
            // Nothing heard in the whole window: drop the silence. Text
            // without timings cannot be cut safely, so that window grows.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                windowStart += windowSampleCount - keepSamples
            }
            return
        }

        let timed = words.map {
            (text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end)
        }.filter { !$0.text.isEmpty }
        guard !timed.isEmpty else { return }

        // Freeze the committed words that the hypothesis agrees with and
        // that end before the cut.
        let committed = committer.committedWordList
        var frozenCount = 0
        while frozenCount < committed.count, frozenCount < timed.count,
            timed[frozenCount].text == committed[frozenCount],
            timed[frozenCount].end <= cutSeconds {
            frozenCount += 1
        }

        var remainingCommitted = Array(committed.dropFirst(frozenCount))
        if frozenCount == 0 {
            // No agreement for a long stretch (a mumbled or churning start).
            // Past twice the window, cost wins over display stability:
            // freeze what the latest hypothesis heard before the cut.
            guard windowSampleCount > 2 * maxWindowSamples else { return }
            while frozenCount < timed.count, timed[frozenCount].end <= cutSeconds {
                frozenCount += 1
            }
            guard frozenCount > 0 else { return }
            frozenWords += timed.prefix(frozenCount).map(\.text)
            remainingCommitted = []
        } else {
            frozenWords += committed.prefix(frozenCount)
        }

        // Restart in the gap after the last frozen word.
        let lastFrozenEnd = timed[frozenCount - 1].end
        let boundarySeconds = frozenCount < timed.count
            ? max(lastFrozenEnd, (lastFrozenEnd + timed[frozenCount].start) / 2)
            : lastFrozenEnd
        let advance = min(max(0, Int(boundarySeconds * rate)), windowSampleCount - 1)
        windowStart += advance
        committer = PrefixCommitter(committedWords: remainingCommitted)
    }

    private static func join(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}

extension TranscriptionResult.TimedSegment {
    /// Groups sub-word token timings into word timings. A token that starts
    /// with whitespace starts a new word (SentencePiece's `▁`, which
    /// FluidAudio reports as a leading space); any other token continues the
    /// current word, so punctuation stays attached to it.
    public static func words(fromTokens tokens: [Self]) -> [Self] {
        var words: [Self] = []
        var startsWord = true
        for token in tokens {
            let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let leadingSpace = token.text.first?.isWhitespace ?? false
            guard !trimmed.isEmpty else {
                startsWord = true
                continue
            }
            if startsWord || leadingSpace || words.isEmpty {
                words.append(Self(text: trimmed, start: token.start, end: token.end))
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = max(words[words.count - 1].end, token.end)
            }
            startsWord = false
        }
        return words
    }
}
