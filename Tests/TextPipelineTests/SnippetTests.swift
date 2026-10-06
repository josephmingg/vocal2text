import CoreModels
import Foundation
import Testing
import TextPipeline

/// docs/17 F5: snippets fire only as the whole dictation, never inside prose.
struct SnippetTests {

    private let address = DictionaryEntry(
        spoken: "my address",
        written: "1 Infinite Loop\nCupertino, CA 95014"
    )

    // MARK: - Classification

    @Test func multiLineOrLongWrittenFormsAreSnippetsByDefault() {
        #expect(address.isSnippet)
        #expect(
            DictionaryEntry(spoken: "sig", written: String(repeating: "x", count: 41)).isSnippet
        )
        #expect(!DictionaryEntry(spoken: "cube", written: "Kubernetes").isSnippet)
    }

    @Test func theExplicitFlagWinsBothWays() {
        #expect(DictionaryEntry(spoken: "my email", written: "me@example.com", snippet: true).isSnippet)
        #expect(!DictionaryEntry(spoken: "x", written: "line one\nline two", snippet: false).isSnippet)
    }

    @Test func vocabularyTermsLeaveSnippetsOut() {
        let entries = [address, DictionaryEntry(spoken: "cube", written: "Kubernetes")]
        #expect(entries.vocabularyTerms == ["Kubernetes"])
    }

    @Test func entriesWrittenBeforeTheFlagExistedStillDecode() throws {
        let legacy = """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","spoken":"cube","written":"Kubernetes",
             "matchMode":"word","isEnabled":true,"createdAt":0,"applyCount":0}
            """
        let entry = try JSONDecoder().decode(DictionaryEntry.self, from: Data(legacy.utf8))
        #expect(entry.snippet == nil)
        #expect(!entry.isSnippet)
    }

    // MARK: - Matching

    @Test func aSnippetNeverExpandsInsideASentence() {
        let out = DictionaryEngine.apply(
            "I changed my address last week.", entries: [address], language: .english
        )
        #expect(out.text == "I changed my address last week.")
        #expect(out.appliedEntryIDs.isEmpty)
    }

    @Test(arguments: ["My address.", "my address", "  My   address!  ", "MY ADDRESS?"])
    func aSnippetMatchesTheWholeTake(take: String) {
        let match = DictionaryEngine.snippet(matching: take, entries: [address], language: .english)
        #expect(match?.id == address.id)
    }

    @Test func aSnippetDoesNotMatchALongerTake() {
        #expect(
            DictionaryEngine.snippet(
                matching: "My address is wrong.", entries: [address], language: .english
            ) == nil
        )
    }

    @Test func disabledOrOtherLanguageSnippetsDoNotMatch() {
        var disabled = address
        disabled.isEnabled = false
        #expect(DictionaryEngine.snippet(matching: "my address", entries: [disabled], language: .english) == nil)
        var chineseOnly = address
        chineseOnly.languages = [.chinese]
        #expect(DictionaryEngine.snippet(matching: "my address", entries: [chineseOnly], language: .english) == nil)
    }

    @Test func wordFixesStillApplyInline() {
        let fix = DictionaryEntry(spoken: "cube", written: "Kubernetes")
        let out = DictionaryEngine.apply("deploy it to cube today", entries: [fix, address], language: .english)
        #expect(out.text == "deploy it to Kubernetes today")
    }

    // MARK: - Tags

    private let noon = Date(timeIntervalSince1970: 1_791_288_000)  // 2026-10-06 12:00 UTC

    @Test func dateTagExpands() {
        let out = SnippetTemplate.expand(
            "Sent {date}.", clipboard: nil, now: noon,
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(out == "Sent October 6, 2026.")
    }

    @Test func timeAndClipboardTagsExpandCaseInsensitively() {
        let out = SnippetTemplate.expand(
            "At {TIME}: {Clipboard}", clipboard: "pasted", now: noon,
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(out.hasSuffix(": pasted"))
        #expect(!out.contains("{"))
        #expect(out.contains("12"))
    }

    @Test func missingClipboardExpandsToNothing() {
        #expect(SnippetTemplate.expand("[{clipboard}]", clipboard: nil, now: noon) == "[]")
    }

    @Test func otherBracesAreLeftAlone() {
        let code = "func f() { return {x} }"
        #expect(SnippetTemplate.expand(code, clipboard: "c", now: noon) == code)
    }

    @Test func needsClipboardOnlyForTheTag() {
        #expect(SnippetTemplate.needsClipboard("Hi {clipboard}"))
        #expect(!SnippetTemplate.needsClipboard("Hi {date}"))
    }

    // MARK: - Spacing

    @Test func snippetsGetASeparatingSpaceButNoCapital() {
        #expect(
            Stage4Formatter.spacedOnly("joe@example.com", precedingContext: "Write to me.")
                == " joe@example.com"
        )
        #expect(Stage4Formatter.spacedOnly("x", precedingContext: nil) == "x")
    }
}
