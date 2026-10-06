import Foundation

/// Detects Vocal's opt-in wake word at the start of a dictation (docs/17
/// G4.4, after Glaido's "Hey Glaido"): "Vocal, make this shorter" or
/// "Hey Vocal, what's 15% of 240" turn the take into a command.
///
/// Deliberately narrow, because a false trigger swallows a dictation: only
/// the very start of the take counts; "hey vocal" / "ok vocal" always
/// trigger; a bare "Vocal" triggers only when followed by punctuation (the
/// recognizer's comma after a vocative) or by a command verb — so "Vocal
/// cords need rest" and "Vocal music tonight" stay ordinary prose.
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
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                let instructionRange = Range(match.range(at: 1), in: text)
            else { continue }
            let instruction = text[instructionRange].trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-—"))
            )
            return instruction.isEmpty ? nil : capitalizedFirst(instruction)
        }
        return nil
    }

    static let commandVerbs = [
        "make", "rewrite", "rephrase", "shorten", "lengthen", "expand", "summarize",
        "summarise", "fix", "correct", "translate", "turn", "change", "convert",
        "format", "reply", "respond", "write", "draft", "polish", "simplify", "tidy",
        "clean", "bullet", "list", "calculate", "compute", "what", "what's", "whats",
        "how", "when", "explain",
    ]

    private static let patterns: [String] = [
        // "Hey Vocal …", "OK Vocal …", "Okay, Vocal: …"
        "^\\s*(?:hey|ok|okay)[\\s,]+vocal\\b[\\s,.:!—-]*(.+)$",
        // "Vocal, …" / "Vocal: …" / "Vocal — …"
        "^\\s*vocal\\s*[,:!—-]\\s*(.+)$",
        // "Vocal make this shorter"
        "^\\s*vocal\\s+((?:" + commandVerbs.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|") + ")\\b.+)$",
    ]

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
