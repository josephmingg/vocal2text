import CoreModels
import Foundation
import Testing

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - DictionaryEntry

@Test func dictionaryEntryCodableRoundTrips() throws {
    let entry = DictionaryEntry(
        spoken: "cube control",
        written: "kubectl",
        matchMode: .word,
        languages: [.english],
        isEnabled: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastAppliedAt: Date(timeIntervalSince1970: 1_700_000_500),
        applyCount: 7
    )
    #expect(try roundTrip(entry) == entry)
}

@Test func hanSpokenFormDefaultsToPhraseMatching() {
    #expect(DictionaryEntry(spoken: "麦门", written: "MaiMen").matchMode == .phrase)
    #expect(DictionaryEntry(spoken: "打开GitHub", written: "打开 GitHub").matchMode == .phrase)
}

@Test func latinSpokenFormDefaultsToWordMatching() {
    #expect(DictionaryEntry(spoken: "cube control", written: "kubectl").matchMode == .word)
}

@Test func explicitMatchModeWinsOverHanDefault() {
    #expect(DictionaryEntry(spoken: "你好", written: "nihao", matchMode: .word).matchMode == .word)
    #expect(DictionaryEntry(spoken: "hello", written: "Hello", matchMode: .phrase).matchMode == .phrase)
}

@Test func hanDefaultSurvivesCodableRoundTrip() throws {
    let entry = DictionaryEntry(spoken: "微信", written: "WeChat")
    let decoded = try roundTrip(entry)
    #expect(decoded.matchMode == .phrase)
    #expect(decoded == entry)
}

// MARK: - Profile & routes

private let allRoutes: [Route] = [
    .app(bundleID: "com.apple.mail"),
    .website(hostname: "mail.google.com"),
    .defaultRoute
]

@Test(arguments: allRoutes)
func routeCodableRoundTrips(route: Route) throws {
    #expect(try roundTrip(route) == route)
}

private let allProviders: [CleanupProviderID] = [
    .appleFoundationModels,
    .localMLX(modelID: "qwen3-4b-mlx"),
    .ollama(model: "qwen3:4b"),
    .openAICompatible(name: "LM Studio")
]

@Test(arguments: allProviders)
func cleanupProviderIDCodableRoundTrips(provider: CleanupProviderID) throws {
    #expect(try roundTrip(provider) == provider)
}

@Test func profileWithEveryRouteCaseRoundTrips() throws {
    let profile = Profile(
        name: "Email",
        icon: "envelope",
        cleanupEnabled: true,
        promptText: "Rewrite as a polite email.",
        providerOverride: .openAICompatible(name: "LM Studio"),
        formatting: FormattingOptions(
            autoPunctuation: true,
            smartSpacing: false,
            structureAllowed: true,
            enforceFullWidthZhPunctuation: false,
            panguSpacing: true
        ),
        ignoresGlobalStyle: true,
        routes: allRoutes,
        priority: 10,
        languageOverride: .pinned(.chinese)
    )
    let decoded = try roundTrip(profile)
    #expect(decoded == profile)
    #expect(decoded.routes == allRoutes)
}

@Test func verbatimProfileWithDefaultsRoundTrips() throws {
    let profile = Profile(
        name: "Terminal",
        formatting: .verbatim,
        routes: [.defaultRoute],
        languageOverride: .auto
    )
    #expect(try roundTrip(profile) == profile)
}

// MARK: - TranscriptRecord

private let allOutcomes: [CleanupOutcome] = [
    .skipped(reason: .masterSwitchOff),
    .skipped(reason: .profileDisabled),
    .skipped(reason: .providerUnavailable),
    .applied(provider: .appleFoundationModels, model: "afm-on-device"),
    .applied(provider: .localMLX(modelID: "qwen3-4b-mlx"), model: "qwen3-4b"),
    .failed(provider: .ollama(model: "qwen3:4b"), reason: "timed out"),
    .rejectedByValidator(provider: .openAICompatible(name: "LM Studio"), rule: "length-ratio")
]

@Test(arguments: allOutcomes)
func transcriptRecordRoundTripsWithEveryCleanupOutcome(outcome: CleanupOutcome) throws {
    let record = TranscriptRecord(
        createdAt: Date(timeIntervalSince1970: 1_723_000_000),
        source: .dictation,
        language: .chinese,
        rawText: "周六去爬山吗",
        deliveredText: "周六去爬山吗？",
        durationSeconds: 3.5,
        targetAppBundleID: "com.tencent.xinWeChat",
        targetAppName: "WeChat",
        profileName: "Messages",
        routeKind: .app,
        cleanup: outcome,
        timings: TimingBreakdown(
            captureSeconds: 3.5,
            transcriptionSeconds: 0.75,
            dictionarySeconds: 0.125,
            cleanupSeconds: 0.5,
            deliverySeconds: 0.0625
        ),
        audioPath: "audio/take.caf",
        isCancelled: false,
        importedFilename: "meeting.m4a"
    )
    let decoded = try roundTrip(record)
    #expect(decoded == record)
    #expect(decoded.cleanup == outcome)
}

@Test func minimalTranscriptRecordRoundTrips() throws {
    let record = TranscriptRecord(
        createdAt: Date(timeIntervalSince1970: 1_723_000_001),
        source: .recovered,
        language: .english,
        rawText: "hello",
        deliveredText: "Hello.",
        durationSeconds: 0.5,
        profileName: "Default",
        routeKind: .defaultRoute,
        cleanup: .skipped(reason: .masterSwitchOff),
        isCancelled: true
    )
    #expect(try roundTrip(record) == record)
}

@Test(arguments: [TranscriptRecord.RouteKind.app, .website, .defaultRoute, .manualPin])
func routeKindRawValuesRoundTrip(kind: TranscriptRecord.RouteKind) {
    #expect(TranscriptRecord.RouteKind(rawValue: kind.rawValue) == kind)
}

// MARK: - containsHanCharacters

@Test(arguments: ["你", "罒", "舘", "㐀", "豈", "abc你def"])
func hanDetectionPositives(text: String) {
    #expect(text.containsHanCharacters)
}

@Test(arguments: ["か", "カタカナ", "한", "😀", "hello world", ""])
func hanDetectionNegatives(text: String) {
    #expect(!text.containsHanCharacters)
}

// MARK: - Burmese language layer (v1.1)

@Test func burmeseIsAnUnspacedScriptWithCleanupOffByDefault() {
    #expect(Language.burmese.rawValue == "my")
    #expect(Language.burmese.isUnspacedScript)
    #expect(Language.chinese.isUnspacedScript)
    #expect(!Language.english.isUnspacedScript)
    // Small local models corrupt Burmese more often than they tidy it
    // (docs/04 Appendix A), so it opts out of cleanup by default.
    #expect(!Language.burmese.allowsCleanupByDefault)
    #expect(Language.english.allowsCleanupByDefault)
    #expect(Language.chinese.allowsCleanupByDefault)
}

@Test func everyLanguageHasLabels() {
    for language in Language.allCases {
        #expect(!language.displayName.isEmpty)
        #expect(!language.shortLabel.isEmpty)
    }
    #expect(Language.allCases.count == 3)
}

@Test(arguments: [
    ("မင်္ဂလာပါ", true),
    ("ကျေးဇူးတင်ပါတယ်", true),
    ("Vocal ကို သုံးပါ", true),  // code-switched still counts
    ("hello there", false),
    ("你好世界", false),
    ("", false),
])
func myanmarScriptDetection(text: String, expected: Bool) {
    #expect(text.containsMyanmarCharacters == expected)
}

@Test func myanmarAndHanDetectionDoNotOverlap() {
    #expect(!"မင်္ဂလာပါ".containsHanCharacters)
    #expect(!"你好世界".containsMyanmarCharacters)
}

/// Myanmar script has no word boundaries, so entries written in it must
/// default to substring matching exactly like Han ones.
@Test func burmeseDictionaryEntriesDefaultToPhraseMatching() {
    #expect(DictionaryEntry(spoken: "မင်္ဂလာ", written: "Mingalar").matchMode == .phrase)
    #expect(DictionaryEntry(spoken: "你好", written: "Nihao").matchMode == .phrase)
    #expect(DictionaryEntry(spoken: "cube control", written: "kubectl").matchMode == .word)
    // An explicit mode still wins.
    #expect(
        DictionaryEntry(spoken: "မင်္ဂလာ", written: "Mingalar", matchMode: .word).matchMode == .word
    )
}

// MARK: - FormattingOptions forward/backward compatibility

@Test func formattingOptionsCarriesBurmeseSettings() throws {
    let options = FormattingOptions(
        autoPunctuation: true,
        myanmarDigits: .myanmar,
        myanmarSpokenPunctuation: false
    )
    #expect(try roundTrip(options) == options)
    #expect(FormattingOptions.verbatim.myanmarDigits == .asRecognized)
    #expect(!FormattingOptions.verbatim.myanmarSpokenPunctuation)
}

/// Profiles are stored as JSON documents and a decode failure makes the app
/// fall back to built-ins — silently discarding the user's customizations.
/// Adding a formatting option must therefore never break an older document.
@Test func formattingOptionsDecodesADocumentWrittenBeforeBurmeseExisted() throws {
    let legacy = """
        {
          "autoPunctuation": false,
          "smartSpacing": true,
          "structureAllowed": false,
          "enforceFullWidthZhPunctuation": true,
          "panguSpacing": false
        }
        """
    let decoded = try JSONDecoder().decode(
        FormattingOptions.self, from: Data(legacy.utf8)
    )
    #expect(!decoded.autoPunctuation)
    #expect(decoded.smartSpacing)
    // New keys take their defaults rather than failing the decode.
    #expect(decoded.myanmarDigits == .asRecognized)
    #expect(decoded.myanmarSpokenPunctuation)
}

@Test func formattingOptionsDecodesAnEmptyDocument() throws {
    let decoded = try JSONDecoder().decode(FormattingOptions.self, from: Data("{}".utf8))
    #expect(decoded == FormattingOptions())
}

@Test func profileWithBurmeseOverrideRoundTrips() throws {
    let profile = Profile(
        name: "Burmese notes",
        formatting: FormattingOptions(myanmarDigits: .western),
        languageOverride: .pinned(.burmese)
    )
    #expect(try roundTrip(profile) == profile)
}
