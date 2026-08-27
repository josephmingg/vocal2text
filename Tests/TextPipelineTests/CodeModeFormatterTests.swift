import Foundation
import Testing
@testable import TextPipeline

struct CodeModeFormatterTests {

    @Test func snakeCaseConsumesTheIdentifierWords() {
        #expect(
            CodeModeFormatter.apply("snake case user name equals five")
                == "user_name = five"
        )
    }

    @Test func camelAndPascalAndConstantAndKebab() {
        #expect(CodeModeFormatter.apply("camel case get user name") == "getUserName")
        #expect(CodeModeFormatter.apply("pascal case http client") == "HttpClient")
        #expect(CodeModeFormatter.apply("constant case max retries") == "MAX_RETRIES")
        #expect(CodeModeFormatter.apply("kebab case main header") == "main-header")
    }

    @Test func spokenSymbolsBecomeCode() {
        #expect(
            CodeModeFormatter.apply("result arrow open paren value close paren")
                == "result -> (value)"
        )
        #expect(
            CodeModeFormatter.apply("items open bracket zero close bracket")
                == "items[zero]"
        )
    }

    @Test func dotsGlueTheirNeighbors() {
        #expect(CodeModeFormatter.apply("user dot name") == "user.name")
        #expect(
            CodeModeFormatter.apply("camel case get name open paren close paren")
                == "getName()"
        )
    }

    @Test func aCasingKeywordWithoutIdentifierWordsIsLeftAlone() {
        // "worst case" scenarios and a bare "camel case." must not vanish.
        #expect(CodeModeFormatter.apply("in the worst case we retry") == "in the worst case we retry")
    }

    @Test func ordinaryWordsPassThrough() {
        #expect(CodeModeFormatter.apply("just plain words here") == "just plain words here")
    }

    // MARK: - Layout commands (docs/15 step 30, structure-gated)

    @Test func newLineAndNewParagraphBecomeBreaks() {
        #expect(
            SpokenLayoutCommands.apply("first item new line second item")
                == "first item\nsecond item"
        )
        // The previous sentence keeps its period — only punctuation the
        // command itself attracted is absorbed.
        #expect(
            SpokenLayoutCommands.apply("Intro done. New paragraph Next topic")
                == "Intro done.\n\nNext topic"
        )
    }

    @Test func stage4GatesLayoutBehindStructureAllowed() {
        let structured = Stage4Formatter.format(
            "First point new line second point",
            language: .english,
            formatting: .init(structureAllowed: true),
            precedingContext: nil
        )
        #expect(structured == "First point\nsecond point")

        let plain = Stage4Formatter.format(
            "a new line of products",
            language: .english,
            formatting: .init(),
            precedingContext: nil
        )
        #expect(plain == "a new line of products")
    }

    @Test func stage4GatesCodeModeBehindItsFlag() {
        let code = Stage4Formatter.format(
            "snake case user name equals five",
            language: .english,
            formatting: .init(autoPunctuation: false, codeMode: true),
            precedingContext: nil
        )
        #expect(code == "user_name = five")
    }
}
