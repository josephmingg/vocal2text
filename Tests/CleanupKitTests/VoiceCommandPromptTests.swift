import CleanupKit
import CoreModels
import Testing

/// docs/17 G4: command prompts and output cleanup.
struct VoiceCommandPromptTests {
    private let edit = VoiceCommandRequest(
        instruction: "Make this shorter", selectedText: "We would like to inform you that the meeting moved.",
        language: .english
    )
    private let compose = VoiceCommandRequest(
        instruction: "Write a polite reply declining the meeting", selectedText: nil, language: .english
    )

    @Test func selectionRidesInItsOwnFence() {
        #expect(
            VoiceCommandPrompt.user(for: edit)
                == "<SELECTED_TEXT>\nWe would like to inform you that the meeting moved.\n</SELECTED_TEXT>\n<INSTRUCTION>\nMake this shorter\n</INSTRUCTION>"
        )
        #expect(VoiceCommandPrompt.system(for: edit).contains("<SELECTED_TEXT>"))
    }

    @Test func noSelectionMeansWriteNewText() {
        #expect(VoiceCommandPrompt.user(for: compose) == "<INSTRUCTION>\nWrite a polite reply declining the meeting\n</INSTRUCTION>")
        #expect(VoiceCommandPrompt.system(for: compose).contains("no text selected"))
        let blank = VoiceCommandRequest(instruction: "x", selectedText: "  \n", language: .english)
        #expect(!blank.hasSelection)
    }

    @Test(arguments: [
        ("Here's the shorter version:\nThe meeting moved.", "The meeting moved."),
        ("Sure! Here it is:\nThe meeting moved.", "The meeting moved."),
        ("\"The meeting moved.\"", "The meeting moved."),
        ("<think>hmm</think>The meeting moved.", "The meeting moved."),
        ("```\nThe meeting moved.\n```", "The meeting moved."),
        ("<INSTRUCTION>The meeting moved.", "The meeting moved."),
        ("Here is why: it moved.", "Here is why: it moved."),
    ])
    func packagingIsStripped(output: String, expected: String) {
        #expect(VoiceCommandPrompt.sanitized(output, request: edit) == expected)
    }

    @Test func emptyOutputIsNil() {
        #expect(VoiceCommandPrompt.sanitized("  <think>x</think> ", request: edit) == nil)
    }

    /// docs/17 §11: a heading is content, not a model preamble — when it is
    /// the user's own line, or starts with a word that merely begins with
    /// "ok" / "here".
    @Test func realFirstLinesSurvive() {
        let steps = VoiceCommandRequest(
            instruction: "Fix the grammar",
            selectedText: "Here are the steps:\n1. open the app\n2. click save",
            language: .english
        )
        #expect(
            VoiceCommandPrompt.sanitized("Here are the steps:\n1. Open the app.\n2. Click Save.", request: steps)
                == "Here are the steps:\n1. Open the app.\n2. Click Save."
        )
        #expect(
            VoiceCommandPrompt.sanitized("Okinawa trip:\nDay one: beach.", request: compose)
                == "Okinawa trip:\nDay one: beach."
        )
        #expect(
            VoiceCommandPrompt.sanitized("Hereford notes:\nCattle.", request: compose)
                == "Hereford notes:\nCattle."
        )
        // The model's own preamble still goes.
        #expect(
            VoiceCommandPrompt.sanitized("Here's the fixed version:\nHere are the steps:\n1. Open.", request: steps)
                == "Here are the steps:\n1. Open."
        )
    }

    @Test func quotesStayWhenTheSelectionWasQuoted() {
        let quoted = VoiceCommandRequest(instruction: "Fix it", selectedText: "\"hello\"", language: .english)
        #expect(VoiceCommandPrompt.sanitized("\"Hello.\"", request: quoted) == "\"Hello.\"")
    }
}
