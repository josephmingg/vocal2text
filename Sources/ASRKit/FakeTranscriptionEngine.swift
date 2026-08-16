import CoreModels
import Foundation

/// Fully scripted `TranscriptionEngine` for tests and previews: returns a fixed
/// result (or throws a fixed failure) after an optional delay, never inspects
/// the audio, and counts lifecycle calls. Counts are actor state, so read them
/// with `await` (e.g. `await engine.prepareCount`).
public actor FakeTranscriptionEngine: TranscriptionEngine {
    public nonisolated let id: String = "fake"
    public nonisolated let displayName: String = "Fake Engine"

    private nonisolated let result: TranscriptionResult
    private nonisolated let partials: [String]
    private nonisolated let delay: Duration
    private nonisolated let failure: TranscriptionError?

    public private(set) var prepareCount = 0
    public private(set) var unloadCount = 0
    public private(set) var transcribeCount = 0
    public private(set) var streamCount = 0
    /// The biasing terms passed to the most recent `transcribe` call.
    public private(set) var lastDictionaryTerms: [String]?

    public init(
        result: TranscriptionResult,
        partials: [String] = [],
        delay: Duration = .zero,
        failure: TranscriptionError? = nil
    ) {
        self.result = result
        self.partials = partials
        self.delay = delay
        self.failure = failure
    }

    public func availability(for language: Language) async -> EngineAvailability {
        .ready
    }

    public func prepare(languageMode: LanguageMode) async throws {
        prepareCount += 1
    }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        transcribeCount += 1
        lastDictionaryTerms = dictionaryTerms
        do {
            try await waitIfNeeded()
        } catch {
            throw TranscriptionError.cancelled
        }
        if let failure {
            throw failure
        }
        return result
    }

    /// Ignores the audio stream entirely (draining it could hang on a stream
    /// the caller never finishes); yields the scripted partials, then the
    /// scripted result as the final update — or finishes throwing `failure`.
    public nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
        let task = Task {
            await self.recordStreamStart()
            do {
                try await self.waitIfNeeded()
            } catch {
                continuation.finish(throwing: TranscriptionError.cancelled)
                return
            }
            if let failure = self.failure {
                continuation.finish(throwing: failure)
                return
            }
            for partial in self.partials {
                continuation.yield(
                    TranscriptionUpdate(
                        kind: .partial,
                        text: partial,
                        detectedLanguage: self.result.detectedLanguage
                    )
                )
            }
            continuation.yield(
                TranscriptionUpdate(
                    kind: .final,
                    text: self.result.text,
                    detectedLanguage: self.result.detectedLanguage
                )
            )
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func unload() async {
        unloadCount += 1
    }

    private func recordStreamStart() {
        streamCount += 1
    }

    private nonisolated func waitIfNeeded() async throws {
        guard delay > .zero else { return }
        try await Task.sleep(for: delay)
    }
}
