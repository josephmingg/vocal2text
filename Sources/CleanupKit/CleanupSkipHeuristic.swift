import CoreModels
import Foundation

/// Decides whether stage 3 (the LLM) has any work to do for a take
/// (docs/15 step 20, as amended by the second review).
///
/// The Wispr lesson is that cleanup must feel free, and the cheapest cleanup
/// call is the one that never happens: a dictation with no fillers, no
/// self-correction, and punctuation already in place comes back from a
/// well-behaved model byte-identical — after a full network round-trip. The
/// heuristic is deterministic, not length-based: it names the exact signals
/// the prompt exists to fix and skips only when none are present.
///
/// Skipping is the risky direction — a false "skip" loses a cleanup the user
/// wanted, a false "run" only costs the round-trip we pay today — so every
/// rule errs toward running the model. `CleanupSkipHeuristicTests` walks the
/// shipped eval set to keep the two from drifting: any eval case whose rules
/// require the model to *remove* something present in the input must not be
/// skippable.
public enum CleanupSkipHeuristic {

    /// Verbal static the prompt removes. Correction cues live in
    /// `SelfCorrectionCues` (checked separately); these are the fillers and
    /// hedges. Matched with the same script-aware token boundaries the cue
    /// search uses, so "um" cannot fire inside "album".
    static let fillers: [String] = [
        "um", "uh", "uhm", "umm", "uhh", "er", "erm", "hmm", "mhm",
        "you know", "i guess", "sort of", "kind of", "kinda", "basically",
        "嗯", "呃", "就是说",
    ]

    /// Correction markers the prompt handles that `SelfCorrectionCues` does
    /// not track — that list doubles as the validator's collapse-floor input,
    /// so it stays conservative; this one only decides whether to spend a
    /// model call, where a false hit merely costs what every take costs today.
    static let extraCorrectionMarkers: [String] = [
        "wait no", "or rather", "啊不是", "不是",
    ]

    /// Sentence-internal structure marks. Presence in the body of a long
    /// utterance is the evidence that punctuation already happened.
    private static let internalPunctuation = Set<Character>(
        [",", ";", ":", "—", ".", "?", "!", "，", "、", "；", "：", "。", "？", "！"]
    )

    /// Above these sizes an unpunctuated utterance probably needs the model
    /// to add structure, so length alone stops justifying a skip.
    private static let shortEnglishWordCount = 12
    private static let shortNonLatinCharacterCount = 20

    /// Whether stage 3 can be skipped for this stage-2 text.
    public static func canSkip(_ text: String, language: Language) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // A self-correction is the one edit only the model performs.
        if SelfCorrectionCues.contentAfterLastCue(in: trimmed) != nil { return false }
        if containsCorrectionMarker(trimmed) { return false }
        if containsFiller(trimmed) { return false }
        if containsImmediateWordRepeat(trimmed) { return false }
        return punctuationLooksSane(trimmed, language: language)
    }

    static func containsFiller(_ text: String) -> Bool {
        containsAnyToken(of: fillers, in: text)
    }

    static func containsCorrectionMarker(_ text: String) -> Bool {
        containsAnyToken(of: extraCorrectionMarkers, in: text)
    }

    private static func containsAnyToken(of needles: [String], in text: String) -> Bool {
        for needle in needles {
            let boundary: TokenBoundary = needle.hasLatinWordEdges ? .latinWord : .leadingBreak
            if text.range(ofToken: needle, boundary: boundary, options: [.caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// A stutter ("send me the the invoice") is a removal only the model
    /// makes. Valid doubled words exist ("that that", "had had"); treating
    /// them as stutters merely runs the cleanup we run today, which is the
    /// cheap direction to be wrong in.
    static func containsImmediateWordRepeat(_ text: String) -> Bool {
        var previous: String?
        for word in text.split(whereSeparator: \.isWhitespace) {
            let cleaned = String(word).trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard !cleaned.isEmpty, cleaned.hasLatinWordEdges else {
                previous = nil
                continue
            }
            if cleaned == previous { return true }
            previous = cleaned
        }
        return false
    }

    /// Short utterances are single clauses — stage 1/4 punctuation suffices.
    /// Long ones may skip only when sentence-internal punctuation is already
    /// present, because adding structure is exactly the model's job.
    static func punctuationLooksSane(_ text: String, language: Language) -> Bool {
        let isShort: Bool
        if language == .english {
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            isShort = wordCount <= shortEnglishWordCount
        } else {
            let characterCount = text.count { !$0.isWhitespace }
            isShort = characterCount <= shortNonLatinCharacterCount
        }
        if isShort { return true }
        // Ignore the final character so a lone terminal mark does not count
        // as internal structure.
        return text.dropLast().contains { internalPunctuation.contains($0) }
    }
}
