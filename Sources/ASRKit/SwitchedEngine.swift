import CoreModels
import Foundation

/// Delegates to one of two engines based on a live flag — how a settings
/// toggle changes an engine route without rebuilding the composition root
/// (docs/15 step 14: "use Parakeet for pinned English" flips per dictation,
/// not per relaunch, honoring the docs/11 G15 settings-take-effect rule).
///
/// The flag closure must be cheap and thread-safe (a UserDefaults read, an
/// atomic); it is consulted at every call so each take routes by the value
/// current at that moment.
public struct SwitchedEngine: TranscriptionEngine {
    public let id = "switched"
    public var displayName: String { selected().displayName }

    private let isOn: @Sendable () -> Bool
    private let onEngine: any TranscriptionEngine
    private let offEngine: any TranscriptionEngine

    public init(
        isOn: @escaping @Sendable () -> Bool,
        on onEngine: any TranscriptionEngine,
        off offEngine: any TranscriptionEngine
    ) {
        self.isOn = isOn
        self.onEngine = onEngine
        self.offEngine = offEngine
    }

    private func selected() -> any TranscriptionEngine {
        isOn() ? onEngine : offEngine
    }

    public func availability(for language: Language) async -> EngineAvailability {
        await selected().availability(for: language)
    }

    public func prepare(languageMode: LanguageMode) async throws {
        try await selected().prepare(languageMode: languageMode)
    }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        try await selected().transcribe(
            audio, languageMode: languageMode, dictionaryTerms: dictionaryTerms
        )
    }

    public func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        selected().transcribeStream(
            audio, languageMode: languageMode, dictionaryTerms: dictionaryTerms
        )
    }

    /// Unloads both sides: "release model memory" applies to whichever
    /// engine holds any, not just the currently selected one.
    public func unload() async {
        await onEngine.unload()
        await offEngine.unload()
    }
}
