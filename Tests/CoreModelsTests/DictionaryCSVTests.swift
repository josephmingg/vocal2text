import Foundation
import Testing
@testable import CoreModels

struct DictionaryCSVTests {

    @Test func roundTripsSimpleEntries() {
        let entries = [
            DictionaryEntry(spoken: "cloud code", written: "Claude Code"),
            DictionaryEntry(spoken: "koo ber net ees", written: "Kubernetes", isEnabled: false),
        ]
        let parsed = DictionaryCSV.parse(DictionaryCSV.export(entries))
        #expect(parsed.map(\.spoken) == ["cloud code", "koo ber net ees"])
        #expect(parsed.map(\.written) == ["Claude Code", "Kubernetes"])
        #expect(parsed.map(\.isEnabled) == [true, false])
    }

    @Test func multiLineSnippetsSurviveTheRoundTrip() {
        // docs/15 step 26: a snippet is an entry whose written form spans
        // lines — "sign off" → a whole closing block.
        let signOff = "Best regards,\nJoseph\nVocal"
        let entries = [DictionaryEntry(spoken: "sign off", written: signOff)]
        let parsed = DictionaryCSV.parse(DictionaryCSV.export(entries))
        #expect(parsed.count == 1)
        #expect(parsed.first?.written == signOff)
    }

    @Test func commasAndQuotesAreQuotedCorrectly() {
        let written = "Hello, \"world\""
        let parsed = DictionaryCSV.parse(
            DictionaryCSV.export([DictionaryEntry(spoken: "greeting", written: written)])
        )
        #expect(parsed.first?.written == written)
    }

    @Test func headerRowAndBlankLinesAreSkipped() {
        let csv = """
        spoken,written,enabled
        cloud code,Claude Code,true

        my address,"1 Infinite Loop
        Cupertino",true
        """
        let parsed = DictionaryCSV.parse(csv)
        #expect(parsed.count == 2)
        #expect(parsed.last?.written == "1 Infinite Loop\nCupertino")
    }

    @Test func rowsMissingTheEnabledColumnDefaultToEnabled() {
        let parsed = DictionaryCSV.parse("hello,Hallo\n")
        #expect(parsed.first?.isEnabled == true)
    }

    @Test func garbageYieldsNothingRatherThanThrowing() {
        #expect(DictionaryCSV.parse("").isEmpty)
        #expect(DictionaryCSV.parse(",,,\n,,\n").isEmpty)
    }

    @Test func crlfEndingsParse() {
        let parsed = DictionaryCSV.parse("a,b\r\nc,d\r\n")
        #expect(parsed.map(\.written) == ["b", "d"])
    }

    @Test func quotedMultiLineFieldFromACRLFFileNormalizesToLF() {
        let parsed = DictionaryCSV.parse("sig,\"line one\r\nline two\"\r\n")
        #expect(parsed.map(\.written) == ["line one\nline two"])
    }
}
