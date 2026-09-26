import CoreModels
import Foundation

/// Stage 1 of the text pipeline (docs/05 §1): a deterministic, language-aware
/// rule pass over the raw ASR transcript. Artifact stripping and whitespace
/// hygiene always run — even for verbatim profiles — while the
/// punctuation/capitalization repairs are gated by the active profile's
/// `FormattingOptions` (docs/05 §0).
public enum Stage1Normalizer: Sendable {
    /// Normalizes one raw ASR transcript before dictionary overrides (stage 2).
    public static func normalize(
        _ text: String,
        language: Language,
        formatting: FormattingOptions
    ) -> String {
        var result = text
        if language == .burmese {
            // Before anything inspects or matches characters: Myanmar text
            // arrives in inconsistent normalization, and two visually
            // identical strings that differ by composition do not compare
            // equal — which would silently break dictionary matching.
            result = MyText.normalizedToNFC(result)
        }
        result = stripTokenRemnants(result)
        result = stripNoiseTags(result)
        result = collapseRepeatedTokenLoops(result)
        result = collapseUnspacedRepetitionLoops(result)
        result = stripLeadingOrphanPunctuation(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == .english {
            result = collapseASCIISpaceRuns(result)
        }

        guard formatting.autoPunctuation, !result.isEmpty else { return result }
        switch language {
        case .english:
            // Fillers and stutters — the deterministic half of "auto clean",
            // on even when the stage-3 LLM is off or unavailable.
            result = EnglishCleanup.clean(result)
            result = stripLeadingOrphanPunctuation(result)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { return result }
            result = capitalizedFirstLetter(result)
            result = appendingTerminalPeriodIfSentenceLike(result)
        case .chinese:
            result = ZhText.removeSingleSpacesBetweenHan(result)
            result = ZhText.convertHalfWidthPunctuationBetweenHan(result)
        case .burmese:
            // Spoken marks first, so the terminal-mark check below sees them.
            if formatting.myanmarSpokenPunctuation {
                result = MyText.spokenPunctuationApplied(result)
                // A command spoken as the very first word leaves its mark at
                // position 0; the general orphan strip already ran before the
                // substitution existed, so re-run it on what it produced.
                result = stripLeadingOrphanPunctuation(result)
            }
            result = MyText.tidiedSpacing(result)
            result = MyText.appendingSectionIfSentenceLike(result)
        }
        return result
    }

    /// Uppercases the first character when it has a distinct uppercase form.
    /// Shared with stage 4's capitalize-after-sentence rule.
    static func capitalizedFirstLetter(_ text: String) -> String {
        // Skip leading whitespace so text opening a new paragraph ("\n\nnext
        // topic") still gets its sentence capital.
        guard let index = text.firstIndex(where: { !$0.isWhitespace }) else { return text }
        let first = text[index]
        let upper = String(first).uppercased()
        guard upper != String(first) else { return text }
        return String(text[..<index]) + upper + String(text[text.index(after: index)...])
    }

    // MARK: - Artifact stripping (always on)

    /// Conservative list of bracketed non-speech tags Whisper-family models emit.
    private static let squareBracketTags =
        "blank_audio|blank audio|silence|music|noise|applause|laughter|laughs|inaudible|crosstalk|音乐|掌声|笑声|静音"
    private static let parenthesisTags =
        "laughs|laughter|laughing|music|applause|coughs|coughing|sighs|silence|noise|inaudible|clears throat|speaking in foreign language|音乐|掌声|笑声|笑"

    /// Removes `<|nospeech|>` / `<|endoftext|>`-style special-token remnants.
    private static func stripTokenRemnants(_ text: String) -> String {
        PipelineRegex.replacing(pattern: "\\s*<\\|[^|<>]*\\|>", in: text)
    }

    private static func stripNoiseTags(_ text: String) -> String {
        var result = text
        result = PipelineRegex.replacing(
            pattern: "\\s*\\[\\s*(?:" + squareBracketTags + ")\\s*\\]",
            in: result
        )
        result = PipelineRegex.replacing(
            pattern: "\\s*[（(]\\s*(?:" + parenthesisTags + ")\\s*[)）]",
            in: result
        )
        return result
    }

    private static let repeatedTokenThreshold = 4

    /// Collapses a whitespace-separated token repeated 4+ times consecutively
    /// (a Whisper decoding loop) down to one occurrence. Runs of 3 or fewer are
    /// kept — "very very very good" is legitimate speech.
    ///
    /// Every separator outside a collapsed run is preserved verbatim (docs/15
    /// step 53, G6): the old implementation rebuilt the whole text with single
    /// spaces whenever a loop existed anywhere, which destroyed paragraph
    /// breaks in exactly the long imports where they matter. A separator
    /// containing a newline also *breaks* a run — a decoding loop is an
    /// intra-line artifact, and the same word legitimately ending one
    /// paragraph and starting the next must not swallow the break.
    private static func collapseRepeatedTokenLoops(_ text: String) -> String {
        // Each piece is one token plus the whitespace that precedes it.
        struct Piece {
            var separator: Substring
            var token: Substring
        }
        var pieces: [Piece] = []
        var cursor = text.startIndex
        var trailingStart = text.endIndex
        while cursor < text.endIndex {
            let separatorStart = cursor
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else {
                // Whitespace after the last token — preserved via `trailing`.
                trailingStart = separatorStart
                break
            }
            let separator = text[separatorStart..<cursor]
            let tokenStart = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            pieces.append(Piece(separator: separator, token: text[tokenStart..<cursor]))
            trailingStart = cursor
        }
        guard !pieces.isEmpty else { return text }
        let trailing = text[trailingStart...]

        // Group into runs of the identical token; a newline separator breaks
        // the run even when the token repeats across it.
        var runs: [(start: Int, count: Int)] = []
        for (index, piece) in pieces.enumerated() {
            if index > 0,
                pieces[index - 1].token == piece.token,
                !piece.separator.contains(where: \.isNewline) {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((start: index, count: 1))
            }
        }
        guard runs.contains(where: { $0.count >= repeatedTokenThreshold }) else { return text }

        var rebuilt = ""
        for run in runs {
            let keep = run.count >= repeatedTokenThreshold ? 1 : run.count
            for offset in 0..<keep {
                let piece = pieces[run.start + offset]
                rebuilt += piece.separator
                rebuilt += piece.token
            }
        }
        rebuilt += trailing
        return rebuilt
    }

    /// Collapses an *unspaced* phrase repeated 4+ times consecutively — the
    /// canonical Whisper zh decoding loop has no spaces, so the token-based
    /// collapse never sees it. Repeated units of 2–20 characters shrink to one
    /// occurrence; shorter runs stay (可以可以 is legitimate speech).
    private static func collapseUnspacedRepetitionLoops(_ text: String) -> String {
        guard
            // \S only: the unit must itself be unspaced, or this pass would
            // also collapse legitimate spaced speech ("over and over and
            // over…") and run across the newlines the token-based pass
            // carefully treats as run breaks (G6).
            let regex = try? NSRegularExpression(pattern: "(\\S{2,20}?)\\1{3,}")
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "$1"
        )
    }

    /// Punctuation that cannot legitimately start an utterance. Opening quotes,
    /// brackets, `$`, `#` etc. are deliberately absent.
    private static let orphanLeadingPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "、", "，", "。", "！", "？", "；", "：", "…",
        "\u{104A}", "\u{104B}",  // Myanmar ၊ and ။
    ]

    private static func stripLeadingOrphanPunctuation(_ text: String) -> String {
        var remainder = text[text.startIndex...]
        while let first = remainder.first,
              first.isWhitespace || orphanLeadingPunctuation.contains(first) {
            remainder = remainder.dropFirst()
        }
        return String(remainder)
    }

    // MARK: - Whitespace hygiene

    private static func collapseASCIISpaceRuns(_ text: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(text.count)
        var previousWasSpace = false
        for character in text {
            if character == " " {
                if previousWasSpace { continue }
                previousWasSpace = true
            } else {
                previousWasSpace = false
            }
            result.append(character)
        }
        return String(result)
    }

    // MARK: - Formatting-gated English repairs

    private static func appendingTerminalPeriodIfSentenceLike(_ text: String) -> String {
        guard let last = text.last, !last.isPunctuation else { return text }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 3 else { return text }
        return text + "."
    }
}
