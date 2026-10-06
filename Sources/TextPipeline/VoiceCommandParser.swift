import Foundation

/// Detects Vocal's opt-in wake word at the start of a dictation (docs/17
/// G4.4, after Glaido's "Hey Glaido"): "Vocal, make this shorter" or
/// "Hey Vocal, what's 15% of 240" turn the take into a command.
///
/// Deliberately narrow, because a false trigger swallows a dictation: only
/// the very start of the take counts, and "Vocal" (bare or after "hey" /
/// "ok") triggers only when followed by the recognizer's vocative comma or
/// by a command verb — so "Vocal cords need rest", "Vocal: Sarah. Drums:
/// Tom." and "Okay vocal warmups first" stay ordinary prose.
public enum VoiceCommandParser {

    /// The instruction after the wake word, or nil when the take does not
    /// start with one (or nothing follows it).
    public static func instruction(afterWakeWordIn text: String) -> String? {
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
                )
            else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }
            // Each pattern captures the instruction in exactly one of its groups.
            let captured = (1..<match.numberOfRanges).lazy
                .compactMap { Range(match.range(at: $0), in: text) }
                .first
            guard let instructionRange = captured else { continue }
            let instruction = text[instructionRange].trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-—"))
            )
            // "OK Vocal." leaves only punctuation — nothing to ask the model.
            guard instruction.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return capitalizedFirst(instruction)
        }
        return nil
    }

    /// Verbs (and question openers) that make a bare "Vocal …" a command.
    /// Words that read naturally as a noun after "vocal" ("list", "bullet")
    /// and bare "what" / "how" / "when" ("Vocal what a performance", "vocal
    /// how-to videos") are deliberately absent.
    static let commandVerbs = [
        "make", "rewrite", "rephrase", "shorten", "lengthen", "expand", "summarize",
        "summarise", "fix", "correct", "translate", "change", "convert",
        "reply", "respond", "write", "polish", "simplify", "tidy",
        "clean up", "calculate", "compute", "what's", "whats", "what is", "how much",
        "how many", "explain",
    ]

    private static var verbGroup: String {
        "(?:" + commandVerbs.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|") + ")(?=\\s)"
    }

    private static let patterns: [String] = [
        // "Hey Vocal, …", "OK Vocal: …", "Hey Vocal summarize this" — but not
        // "Okay vocal warmups first" or "Hey vocal coach, nice job".
        "^\\s*(?:hey|ok|okay)[\\s,]+vocal(?:\\s*[,.:!—-]+\\s*(.+)|\\s+(" + verbGroup + ".+))$",
        // "Vocal, …" / "Vocal! …" — the recognizer's vocative comma.
        "^\\s*vocal\\s*[,!]\\s*(.+)$",
        // "Vocal make this shorter", "Vocal: summarize this".
        "^\\s*vocal(?:\\s*[:—-]\\s*|\\s+)(" + verbGroup + ".+)$",
    ]

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
