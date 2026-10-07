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
    /// Set by a slide: the next hypothesis starts in a new window and is
    /// lined up with the words carried over before it is ingested.
    private var needsAlignment = false
    /// End times, relative to the new window, of the committed words the
    /// last slide carried into it (nil where the hypothesis had no timing).
    private var carriedEnds: [Double?] = []
    private let maxWindowSamples: Int
    private let keepSamples: Int

    /// A word-to-word gap at least this long marks a pause: the preferred
    /// place to restart the window, so no word straddles the cut.
    private static let pauseSeconds = 0.08

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
        var timed = words.isEmpty
            ? text.split(whereSeparator: \.isWhitespace).map {
                TranscriptionResult.TimedSegment(text: String($0), start: 0, end: 0)
            }
            : words.compactMap { word -> TranscriptionResult.TimedSegment? in
                let trimmed = word.text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty
                    ? nil : TranscriptionResult.TimedSegment(text: trimmed, start: word.start, end: word.end)
            }
        if needsAlignment {
            needsAlignment = false
            timed = alignedAfterSlide(timed, hasTimings: !words.isEmpty)
        }
        let windowLine = committer.ingest(timed.map(\.text).joined(separator: " "))
        let display = Self.join(frozenText, windowLine)
        slideIfNeeded(timed: words.isEmpty ? [] : timed, text: text, windowSampleCount: windowSampleCount)
        return display
    }

    /// The first hypothesis after a slide is decoded from audio that starts
    /// at the cut. At a cut without a pause, it can repeat the last frozen
    /// word or drop the first carried-over one; line it up so the screen
    /// shows each word once.
    private func alignedAfterSlide(
        _ timed: [TranscriptionResult.TimedSegment], hasTimings: Bool
    ) -> [TranscriptionResult.TimedSegment] {
        let carried = committer.committedWordList
        guard let first = timed.first else { return timed }
        guard !carried.isEmpty else {
            // A clipped tail of the last frozen word at the very start.
            if hasTimings, let last = frozenWords.last, first.start < 0.3,
                PrefixCommitter.sameWord(first.text, last) {
                return Array(timed.dropFirst())
            }
            return timed
        }
        if PrefixCommitter.sameWord(first.text, carried[0]) { return timed }
        // An extra word ahead of the carried ones: the edge of a frozen word.
        if timed.count > 1, PrefixCommitter.sameWord(timed[1].text, carried[0]) {
            return Array(timed.dropFirst())
        }
        // Carried words the new window did not hear: by text (the
        // hypothesis starts at the second carried word) or by time (they
        // ended before the hypothesis's first word starts).
        var missing = 0
        if carried.count > 1, PrefixCommitter.sameWord(first.text, carried[1]) {
            missing = 1
        }
        if hasTimings {
            while missing < carried.count, missing < carriedEnds.count,
                let end = carriedEnds[missing], end <= first.start + 0.05 {
                missing += 1
            }
        }
        guard missing > 0 else { return timed }
        let restored = carried.prefix(missing).map {
            TranscriptionResult.TimedSegment(text: $0, start: 0, end: 0)
        }
        return restored + timed
    }

    private mutating func slideIfNeeded(
        timed: [TranscriptionResult.TimedSegment],
        text: String,
        windowSampleCount: Int
    ) {
        guard windowSampleCount > maxWindowSamples else { return }
        let rate = Double(PCMChunk.sampleRate)
        let cutSeconds = Double(windowSampleCount - keepSamples) / rate

        guard !timed.isEmpty else {
            // Nothing heard in the whole window: drop the silence. Words
            // already committed stay on screen, frozen, since their audio is
            // gone. Text without timings cannot be cut safely, so that
            // window grows.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                windowStart += windowSampleCount - keepSamples
                frozenWords += committer.committedWordList
                committer = PrefixCommitter()
                carriedEnds = []
                needsAlignment = true
            }
            return
        }

        // Freezable: the committed words the hypothesis agrees with that
        // end before the cut.
        let committed = committer.committedWordList
        var agreed = 0
        while agreed < committed.count, agreed < timed.count,
            PrefixCommitter.sameWord(timed[agreed].text, committed[agreed]),
            timed[agreed].end <= cutSeconds {
            agreed += 1
        }
        var freezeCount = agreed
        if freezeCount == 0 {
            // No agreement for a long stretch (a mumbled or churning start).
            // Past twice the window, cost wins: cut by the latest
            // hypothesis's timings, but show the committed words where they
            // exist, so nothing already on screen changes.
            guard windowSampleCount > 2 * maxWindowSamples else { return }
            freezeCount = timed.prefix { $0.end <= cutSeconds }.count
            guard freezeCount > 0 else { return }
        } else {
            // Prefer to cut at a pause, so no word straddles the boundary.
            if let pause = (1...freezeCount).last(where: { count in
                count == timed.count
                    || timed[count].start - timed[count - 1].end >= Self.pauseSeconds
            }) {
                freezeCount = pause
            }
        }

        let shown = (0..<freezeCount).map { index in
            index < committed.count ? committed[index] : timed[index].text
        }
        frozenWords += shown
        let lastFrozenEnd = timed[freezeCount - 1].end
        let boundarySeconds = freezeCount < timed.count
            ? max(lastFrozenEnd, (lastFrozenEnd + timed[freezeCount].start) / 2)
            : lastFrozenEnd
        let advance = min(max(0, Int(boundarySeconds * rate)), windowSampleCount - 1)
        windowStart += advance
        let carried = Array(committed.dropFirst(freezeCount))
        carriedEnds = carried.indices.map { offset in
            let index = freezeCount + offset
            guard index < timed.count,
                PrefixCommitter.sameWord(timed[index].text, carried[offset])
            else { return nil }
            return timed[index].end - Double(advance) / rate
        }
        committer = PrefixCommitter(committedWords: carried)
        needsAlignment = true
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
