import CoreModels
import Foundation

/// Routes each dictation to the engine that is actually good at its language
/// (docs/04 §1): one primary engine, plus per-language overrides — today
/// Burmese → sherpa-onnx, everything else → WhisperKit.
///
/// Routing happens **only on a pin** (menu-bar toggle or a profile language
/// override). Auto mode always uses the primary engine: "which language was
/// that?" is only answered *by decoding the audio*, and by then the primary
/// engine has already produced the take's text — re-decoding on another
/// engine after the fact would double latency for every non-English take on
/// a guess. So v1's contract is explicit: Burmese-quality recognition
/// requires pinning မြန်မာ; auto-detected Burmese still reaches the Burmese
/// text pipeline (stages 2–4), just from the primary engine's transcription
/// (docs/04 Appendix A).
public struct LanguageRoutingEngine: TranscriptionEngine {
    public let id = "language-router"
    public var displayName: String { primary.displayName }

    private let primary: any TranscriptionEngine
    private let overrides: [Language: any TranscriptionEngine]

    public init(primary: any TranscriptionEngine, overrides: [Language: any TranscriptionEngine]) {
        self.primary = primary
        self.overrides = overrides
    }

    /// The engine a pin on `language` would use — how the UI asks "what would
    /// a Burmese dictation actually run on, and is it installed?".
    public func engine(for language: Language) -> any TranscriptionEngine {
        overrides[language] ?? primary
    }

    private func engine(for mode: LanguageMode) -> any TranscriptionEngine {
        guard let pinned = mode.pinnedLanguage else { return primary }
        return engine(for: pinned)
    }

    public func availability(for language: Language) async -> EngineAvailability {
        await engine(for: language).availability(for: language)
    }

    /// Prepares only the engine the current mode routes to — warming up must
    /// not trigger a Burmese model download for a user who never pins မြန်မာ.
    public func prepare(languageMode: LanguageMode) async throws {
        try await engine(for: languageMode).prepare(languageMode: languageMode)
    }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        try await engine(for: languageMode).transcribe(
            audio,
            languageMode: languageMode,
            dictionaryTerms: dictionaryTerms
        )
    }

    public func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        engine(for: languageMode).transcribeStream(
            audio,
            languageMode: languageMode,
            dictionaryTerms: dictionaryTerms
        )
    }

    /// Unloads every engine, not just the routed one — unload-after-idle
    /// means "release model memory", whichever engines hold any.
    public func unload() async {
        await primary.unload()
        for engine in overrides.values {
            await engine.unload()
        }
    }
}
