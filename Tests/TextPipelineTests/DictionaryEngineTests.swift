import CoreModels
import Foundation
import Testing
import TextPipeline

private func makeEntry(
    _ spoken: String,
    _ written: String,
    mode: DictionaryEntry.MatchMode? = nil,
    languages: Set<Language>? = nil,
    isEnabled: Bool = true
) -> DictionaryEntry {
    DictionaryEntry(
        spoken: spoken,
        written: written,
        matchMode: mode,
        languages: languages,
        isEnabled: isEnabled
    )
}

struct DictionaryEngineTests {

    @Test func spokenFormMatchesCaseInsensitively() {
        let e = makeEntry("cloud code", "Claude Code")
        for variant in ["cloud code", "Cloud Code", "CLOUD CODE", "cLoUd CoDe"] {
            let result = DictionaryEngine.apply(
                "I use \(variant) daily", entries: [e], language: .english
            )
            #expect(result.text == "I use Claude Code daily")
            #expect(result.appliedEntryIDs == [e.id])
        }
    }

    @Test func wordModeRespectsUnicodeBoundaries() {
        let e = makeEntry("cat", "Katt")

        let unchanged = DictionaryEngine.apply(
            "filed under category twelve", entries: [e], language: .english
        )
        #expect(unchanged.text == "filed under category twelve")
        #expect(unchanged.appliedEntryIDs.isEmpty)

        #expect(
            DictionaryEngine.apply("concat the files", entries: [e], language: .english).text
                == "concat the files"
        )
        #expect(
            DictionaryEngine.apply("the cat sat", entries: [e], language: .english).text
                == "the Katt sat"
        )
        #expect(DictionaryEngine.apply("cat.", entries: [e], language: .english).text == "Katt.")
        #expect(DictionaryEngine.apply("cat", entries: [e], language: .english).text == "Katt")
    }

    @Test func hanEntriesDefaultToPhraseAndMatchInsideUnspacedChineseText() {
        let e = makeEntry("维信", "微信", languages: [.chinese])
        #expect(e.matchMode == .phrase)

        let result = DictionaryEngine.apply(
            "我在维信上给你发消息", entries: [e], language: .chinese
        )
        #expect(result.text == "我在微信上给你发消息")
        #expect(result.appliedEntryIDs == [e.id])

        let wrongLanguage = DictionaryEngine.apply(
            "我在维信上给你发消息", entries: [e], language: .english
        )
        #expect(wrongLanguage.text == "我在维信上给你发消息")
        #expect(wrongLanguage.appliedEntryIDs.isEmpty)
    }

    @Test func multiWordSpokenMatchesAnyWhitespaceRun() {
        let e = makeEntry("cloud code", "Claude Code")
        #expect(
            DictionaryEngine.apply("open cloud  code now", entries: [e], language: .english).text
                == "open Claude Code now"
        )
        #expect(
            DictionaryEngine.apply("open cloud\tcode now", entries: [e], language: .english).text
                == "open Claude Code now"
        )
    }

    @Test func longestSpokenFormWinsWhenEntriesOverlap() {
        let short = makeEntry("cloud", "Claude")
        let long = makeEntry("cloud code", "Claude Code")

        // Shorter entry listed first: ordering must come from length, not input order.
        let result = DictionaryEngine.apply(
            "open cloud code from cloud", entries: [short, long], language: .english
        )
        #expect(result.text == "open Claude Code from Claude")
        #expect(result.appliedEntryIDs == [long.id, short.id])
    }

    @Test func writtenFormsAreTerminalOnReapplication() {
        let e = makeEntry("jim", "Jim Halpert")

        let once = DictionaryEngine.apply("tell jim the plan", entries: [e], language: .english)
        #expect(once.text == "tell Jim Halpert the plan")
        #expect(once.appliedEntryIDs == [e.id])

        let twice = DictionaryEngine.apply(once.text, entries: [e], language: .english)
        #expect(twice.text == once.text)
        #expect(twice.appliedEntryIDs.isEmpty)
    }

    @Test func noCascadeBetweenEntries() {
        let aToB = makeEntry("a", "b")
        let bToC = makeEntry("b", "c")

        let result = DictionaryEngine.apply("a", entries: [aToB, bToC], language: .english)
        #expect(result.text == "b")
        #expect(result.appliedEntryIDs == [aToB.id])

        // The organic "b" in the input sits inside an occurrence of aToB's
        // written form, so it is terminal and bToC must not rewrite it.
        let both = DictionaryEngine.apply("a b", entries: [aToB, bToC], language: .english)
        #expect(both.text == "b b")
        #expect(both.appliedEntryIDs == [aToB.id])
    }

    @Test func writtenFormCasingIsAuthoritativeAtSentenceStart() {
        let lowercasing = makeEntry("iphone", "iPhone")
        #expect(
            DictionaryEngine.apply("iphone is great", entries: [lowercasing], language: .english)
                .text == "iPhone is great"
        )

        let decapitalizing = makeEntry("Bob", "bob")
        #expect(
            DictionaryEngine.apply("Bob called twice", entries: [decapitalizing], language: .english)
                .text == "bob called twice"
        )
    }

    @Test func disabledAndLanguageFilteredEntriesDoNotApply() {
        let disabled = makeEntry("cat", "Katt", isEnabled: false)
        #expect(
            DictionaryEngine.apply("the cat sat", entries: [disabled], language: .english).text
                == "the cat sat"
        )

        let zhOnly = makeEntry("cat", "Katt", languages: [.chinese])
        #expect(
            DictionaryEngine.apply("the cat sat", entries: [zhOnly], language: .english).text
                == "the cat sat"
        )
        #expect(
            DictionaryEngine.apply("the cat sat", entries: [zhOnly], language: .chinese).text
                == "the Katt sat"
        )
    }

    @Test func appliedEntryIDsListOneElementPerReplacementInTextOrder() {
        let e = makeEntry("cat", "Katt")
        let result = DictionaryEngine.apply("cat and cat", entries: [e], language: .english)
        #expect(result.text == "Katt and Katt")
        #expect(result.appliedEntryIDs == [e.id, e.id])
    }

    @Test(arguments: [
        "",
        "cloud code and CLOUD  CODE",
        "tell jim that jim called",
        "the cat category concat cat",
        "iphone party time 🎉",
        "party party party",
        "a b c a",
        "mixed 中文 and cloud code here",
    ])
    func englishReapplicationIsANoOp(input: String) {
        let entries = [
            makeEntry("cloud code", "Claude Code"),
            makeEntry("cloud", "Claude"),
            makeEntry("jim", "Jim Halpert"),
            makeEntry("cat", "Katt"),
            makeEntry("iphone", "iPhone"),
            makeEntry("party", "🎉 party"),
            makeEntry("a", "b"),
            makeEntry("b", "c"),
        ]
        let once = DictionaryEngine.apply(input, entries: entries, language: .english)
        let twice = DictionaryEngine.apply(once.text, entries: entries, language: .english)
        #expect(twice.text == once.text)
        #expect(twice.appliedEntryIDs.isEmpty)
    }

    @Test(arguments: [
        "",
        "我在维信上给你发消息",
        "微信维信混在一起维信",
        "全是微信",
        "维信和 iphone 夹杂使用",
    ])
    func chineseReapplicationIsANoOp(input: String) {
        let entries = [
            makeEntry("维信", "微信"),
            makeEntry("微信", "WeChat"),
            makeEntry("iphone", "iPhone"),
        ]
        let once = DictionaryEngine.apply(input, entries: entries, language: .chinese)
        let twice = DictionaryEngine.apply(once.text, entries: entries, language: .chinese)
        #expect(twice.text == once.text)
        #expect(twice.appliedEntryIDs.isEmpty)
    }
}
