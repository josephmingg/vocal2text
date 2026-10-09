import Foundation

/// Detects Vocal's opt-in wake word at the start of a dictation (docs/17
/// G4.4, after Glaido's "Hey Glaido"): "Vocal, make this shorter" or
/// "Hey Vocal, what's 15% of 240" turn the take into a command.
///
/// Deliberately narrow, because a false trigger swallows a dictation: only
/// the very start of the take counts, and "Vocal" (bare or after "hey" /
/// "ok") must be followed by a command verb — after the vocative comma a
/// wider set, with no punctuation a strict one — so "Vocal cords need
/// rest", "Vocal, guitar and bass are mixed", "Vocal fix is in the mix" and
/// "Okay vocal warmups first" stay ordinary prose.
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

    /// What may follow "Vocal" with no punctuation between ("Vocal make
    /// this shorter"): verbs and question openers that do not read as a noun
    /// or adjective after "vocal". "Vocal fix is in the mix", "vocal change",
    /// "vocal polish", "vocal correct pitch", "vocal list" stay prose.
    static let strictOpeners = [
        "make", "rewrite", "rephrase", "shorten", "lengthen", "summarize", "summarise",
        "translate", "convert", "simplify", "calculate", "compute", "explain",
        "what's", "whats", "what is", "how much", "how many",
    ]

    /// What may follow the vocative punctuation ("Vocal, fix the grammar").
    /// A command still has to start with one of these: "Vocal, guitar and
    /// bass are mixed" and "OK vocal, levels are fine" are a musician's
    /// dictation, not a command — the wake word is too easy to say by
    /// accident to treat anything after a comma as an instruction.
    static let punctuatedOpeners = strictOpeners + [
        "fix", "correct", "change", "polish", "tidy", "clean up", "expand", "reply",
        "respond", "write", "draft", "format", "turn", "please", "can you", "could you",
    ]

    private static func group(_ openers: [String]) -> String {
        "(?:" + openers.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|") + ")(?=\\s)"
    }

    private static let patterns: [String] = [
        // "Hey Vocal, fix …", "OK Vocal: what's …", "Hey Vocal summarize …"
        "^\\s*(?:hey|ok|okay)[\\s,]+vocal(?:\\s*[,.:!—-]+\\s*(" + group(punctuatedOpeners)
            + ".+)|\\s+(" + group(strictOpeners) + ".+))$",
        // "Vocal, fix …" / "Vocal: translate …" / "Vocal! what's …"
        "^\\s*vocal\\s*[,:!—-]\\s*(" + group(punctuatedOpeners) + ".+)$",
        // "Vocal make this shorter"
        "^\\s*vocal\\s+(" + group(strictOpeners) + ".+)$",
    ]

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
