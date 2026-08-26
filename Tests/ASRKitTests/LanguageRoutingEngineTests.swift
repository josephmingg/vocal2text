import CoreModels
import Foundation
import Testing
@testable import ASRKit

/// The rule that decides which *engine* a dictation runs on (docs/04 §1):
/// pinned Burmese must reach the Burmese engine, and — the v1 contract —
/// auto mode must always stay on the primary engine, because language
/// detection happens by decoding and by then the primary has already done
/// the work.
@Suite struct LanguageRoutingEngineTests {

    private static func fake(
        _ text: String,
        language: Language = .english,
        availability: EngineAvailability = .ready
    ) -> FakeTranscriptionEngine {
        FakeTranscriptionEngine(
            result: TranscriptionResult(text: text, detectedLanguage: language),
            availability: availability
        )
    }

    private static let audio = PCMChunk(samples: [Float](repeating: 0, count: 1_600))

    @Test func pinnedBurmeseRoutesToOverrideEngine() async throws {
        let primary = Self.fake("primary")
        let burmese = Self.fake("မြန်မာ", language: .burmese)
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        let result = try await router.transcribe(
            Self.audio, languageMode: .pinned(.burmese), dictionaryTerms: []
        )

        #expect(result.text == "မြန်မာ")
        #expect(await burmese.transcribeCount == 1)
        #expect(await primary.transcribeCount == 0)
    }

    @Test func autoModeStaysOnPrimaryEvenWithBurmeseOverride() async throws {
        // The v1 contract: no pin, no reroute — even though a Burmese
        // override exists (see LanguageRoutingEngine's doc comment for why).
        let primary = Self.fake("primary")
        let burmese = Self.fake("မြန်မာ", language: .burmese)
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        let result = try await router.transcribe(Self.audio, languageMode: .auto, dictionaryTerms: [])

        #expect(result.text == "primary")
        #expect(await primary.transcribeCount == 1)
        #expect(await burmese.transcribeCount == 0)
    }

    @Test func pinnedLanguageWithoutOverrideUsesPrimary() async throws {
        let primary = Self.fake("primary", language: .chinese)
        let burmese = Self.fake("မြန်မာ", language: .burmese)
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        let result = try await router.transcribe(
            Self.audio, languageMode: .pinned(.chinese), dictionaryTerms: []
        )

        #expect(result.text == "primary")
        #expect(await primary.transcribeCount == 1)
        #expect(await burmese.transcribeCount == 0)
    }

    @Test func availabilityComesFromTheRoutedEngine() async {
        let primary = Self.fake("primary")
        let burmese = Self.fake("မြန်မာ", availability: .needsDownload(bytes: 786_400_000))
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        #expect(await router.availability(for: .burmese) == .needsDownload(bytes: 786_400_000))
        #expect(await router.availability(for: .english) == .ready)
    }

    @Test func prepareRoutesByModeAndNeverWarmsTheOtherEngine() async throws {
        // Warming up in auto/EN must not touch the Burmese engine: prepare
        // there can trigger a multi-hundred-MB download.
        let primary = Self.fake("primary")
        let burmese = Self.fake("မြန်မာ")
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        try await router.prepare(languageMode: .auto)
        #expect(await primary.prepareCount == 1)
        #expect(await burmese.prepareCount == 0)

        try await router.prepare(languageMode: .pinned(.burmese))
        #expect(await primary.prepareCount == 1)
        #expect(await burmese.prepareCount == 1)
    }

    @Test func streamRoutesByPin() async throws {
        let primary = Self.fake("primary")
        let burmese = Self.fake("မြန်မာ", language: .burmese)
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        let (audio, continuation) = AsyncStream<PCMChunk>.makeStream()
        continuation.finish()
        var finalText: String?
        for try await update in router.transcribeStream(
            audio, languageMode: .pinned(.burmese), dictionaryTerms: []
        ) where update.kind == .final {
            finalText = update.text
        }

        #expect(finalText == "မြန်မာ")
        #expect(await burmese.streamCount == 1)
        #expect(await primary.streamCount == 0)
    }

    @Test func unloadReleasesEveryEngine() async {
        let primary = Self.fake("primary")
        let burmese = Self.fake("မြန်မာ")
        let router = LanguageRoutingEngine(primary: primary, overrides: [.burmese: burmese])

        await router.unload()

        #expect(await primary.unloadCount == 1)
        #expect(await burmese.unloadCount == 1)
    }
}
