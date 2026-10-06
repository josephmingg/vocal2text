import CoreModels
import Foundation

/// One spoken command for the local model (docs/17 G4, after Glaido's
/// Commands): an instruction, applied to the text that was selected at the
/// press, or — with nothing selected — a short piece of text to write.
public struct VoiceCommandRequest: Sendable, Hashable {
    public var instruction: String
    /// The selection captured when the command key went down; nil or empty
    /// means "write new text".
    public var selectedText: String?
    public var language: Language

    public init(instruction: String, selectedText: String?, language: Language) {
        self.instruction = instruction
        self.selectedText = selectedText
        self.language = language
    }

    public var hasSelection: Bool {
        !(selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A provider that can run a free-form instruction (as opposed to the
/// dictation cleanup transform). Ollama and Apple's on-device model both do.
public protocol CommandRunning: Sendable {
    func runCommand(
        system: String, user: String, maxTokens: Int, timeout: Duration
    ) async throws -> CleanupResponse
}

/// Prompt and output handling for command mode. Unlike dictation cleanup,
/// a command is *supposed* to change the words — so none of the cleanup
/// validator's anti-rewrite rules apply; the result is shown in a preview the
/// user accepts with Enter, which is the safety net instead.
public enum VoiceCommandPrompt {

    public static func system(for request: VoiceCommandRequest) -> String {
        let task: String
        if request.hasSelection {
            task = """
                The user selected some text and spoke an instruction about it. Apply the \
                instruction to the text inside <SELECTED_TEXT> and output the result. If the \
                instruction asks a question about that text, answer it in one or two sentences.
                """
        } else {
            task = """
                The user spoke an instruction with no text selected. Write exactly the text it \
                asks for — a reply, a sentence, a short list — or, for a question, a short \
                direct answer.
                """
        }
        return """
            You are the command tool inside a dictation app. Your output is inserted into the \
            user's document, so it must be the finished text and nothing else.

            \(task)

            RULES
            1. Output only the resulting text: no preamble ("Here is…", "Sure"), no explanation, \
            no surrounding quotes, no markdown code fences unless the text itself is code.
            2. Keep the selected text's language unless the instruction asks for a translation.
            3. Keep names, numbers, links, code, and technical terms exactly as written unless \
            the instruction says to change them.
            4. Keep it as short as the instruction allows. Never add facts that were not given.
            """
    }

    public static func user(for request: VoiceCommandRequest) -> String {
        let instruction = "<INSTRUCTION>\n\(request.instruction)\n</INSTRUCTION>"
        guard request.hasSelection, let selected = request.selectedText else { return instruction }
        return "<SELECTED_TEXT>\n\(selected)\n</SELECTED_TEXT>\n" + instruction
    }

    /// Strips what small local models wrap around an answer — reasoning
    /// blocks, a one-line preamble ending in a colon, echoed tags, a single
    /// pair of wrapping quotes or a whole-output code fence — and returns nil
    /// for an empty result.
    public static func sanitized(_ output: String, request: VoiceCommandRequest) -> String? {
        var text = OutputValidator.strippingThinkBlocks(output)
        for tag in ["<selected_text>", "</selected_text>", "<instruction>", "</instruction>"] {
            text = text.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Here's the shorter version:\n…" / "Sure! Here it is:\n…"
        if let newline = text.firstIndex(of: "\n") {
            let firstLine = text[..<newline].trimmingCharacters(in: .whitespaces)
            let lowered = firstLine.lowercased()
            let preambleStarts = ["here", "sure", "certainly", "okay", "ok", "of course", "absolutely"]
            if firstLine.hasSuffix(":"), preambleStarts.contains(where: { lowered.hasPrefix($0) }) {
                text = String(text[text.index(after: newline)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // A fence around the whole output, when the selection was not code.
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6,
            !(request.selectedText ?? "").contains("```") {
            var inner = String(text.dropFirst(3).dropLast(3))
            if let newline = inner.firstIndex(of: "\n"),
                !inner[..<newline].contains(" ") {
                // Drop a language tag line ("```swift").
                inner = String(inner[inner.index(after: newline)...])
            }
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let selectedStartsQuoted = (request.selectedText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).first.map { "\"“".contains($0) } ?? false
        for (open, close) in [("\"", "\""), ("“", "”")] where !selectedStartsQuoted {
            if text.count >= 2, text.hasPrefix(open), text.hasSuffix(close) {
                let inner = text.dropFirst().dropLast()
                if !inner.contains(open), !inner.contains(close) {
                    text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return text.isEmpty ? nil : text
    }

    /// Generous: commands may expand text ("write a polite reply").
    public static func maxTokens(for request: VoiceCommandRequest) -> Int {
        max(512, 4 * ((request.selectedText ?? "").count + request.instruction.count))
    }
}
