import Foundation

/// The layout slice of command mode (docs/15 step 30, deliberately scoped):
/// "new line" and "new paragraph" become real breaks. Gated behind
/// `FormattingOptions.structureAllowed` — an opt-in profile choice — because
/// "a new line of products" is ordinary prose and the words alone cannot
/// disambiguate; the rest of the command grammar (scratch that, selections,
/// edits) stays with the cleanup model per the plan.
public enum SpokenLayoutCommands {

    public static func apply(_ text: String) -> String {
        var result = text
        // Longest phrase first so "new paragraph" never half-matches. The
        // comma the recognizer attaches to the command goes with it, but a
        // period before the command belongs to the *previous sentence* and
        // must survive; the trailing class still absorbs the punctuation the
        // command phrase itself attracted.
        result = PipelineRegex.replacing(
            pattern: "[ ,]*\\bnew paragraph\\b[ ,.]*", in: result, with: "\n\n"
        )
        result = PipelineRegex.replacing(
            pattern: "[ ,]*\\bnew line\\b[ ,.]*", in: result, with: "\n"
        )
        return result
    }
}
