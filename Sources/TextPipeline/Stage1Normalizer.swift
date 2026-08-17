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
        guard let first = text.first else { return text }
        let upper = String(first).uppercased()
        guard upper != String(first) else { return text }
        return upper + text.dropFirst()
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
    /// kept — "very very very good" is legitimate speech. The text is rebuilt
    /// with single spaces only when a loop was actually found.
    private static func collapseRepeatedTokenLoops(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return text }
        var runs: [(token: Substring, count: Int)] = []
        for token in tokens {
            if let last = runs.last, last.token == token {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((token: token, count: 1))
            }
        }
        guard runs.contains(where: { $0.count >= repeatedTokenThreshold }) else { return text }
        var collapsed: [Substring] = []
        for run in runs {
            let keep = run.count >= repeatedTokenThreshold ? 1 : run.count
            for _ in 0..<keep {
                collapsed.append(run.token)
            }
        }
        return collapsed.joined(separator: " ")
    }

    /// Collapses an *unspaced* phrase repeated 4+ times consecutively — the
    /// canonical Whisper zh decoding loop has no spaces, so the token-based
    /// collapse never sees it. Repeated units of 2–20 characters shrink to one
    /// occurrence; shorter runs stay (可以可以 is legitimate speech).
    private static func collapseUnspacedRepetitionLoops(_ text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: "(.{2,20}?)\\1{3,}",
                options: [.dotMatchesLineSeparators]
            )
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
