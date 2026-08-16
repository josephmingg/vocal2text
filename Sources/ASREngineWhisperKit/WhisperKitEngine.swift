import ASRKit
import CoreModels
import Foundation

#if canImport(WhisperKit)
import WhisperKit

/// Primary EN/ZH engine (docs/04 §1): Whisper large-v3-turbo via WhisperKit.
/// One model covers both languages including mid-sentence code-switching.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let id = "whisperkit"
    public nonisolated let displayName = "WhisperKit (Whisper large-v3-turbo)"

    private let modelName: String
    private let modelFolder: URL?
    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    public init(modelName: String = "openai_whisper-large-v3-v20240930_turbo", modelFolder: URL? = nil) {
        self.modelName = modelName
        self.modelFolder = modelFolder
    }

    public func availability(for language: Language) async -> EngineAvailability {
        // Whisper covers all our v1 languages; readiness depends on model download.
        pipe == nil ? .needsDownload(bytes: 626_000_000) : .ready
    }

    public func prepare(languageMode: LanguageMode) async throws {
        _ = try await loadedPipe()
    }

    /// Concurrent loads coalesce onto one in-flight task (docs/09 lesson).
    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }
        let name = modelName
        let folder = modelFolder
        let task = Task {
            let config = WhisperKitConfig(model: name, modelFolder: folder?.path)
            return try await WhisperKit(config)
        }
        loadTask = task
        do {
            let loaded = try await task.value
            pipe = loaded
            loadTask = nil
            return loaded
        } catch {
            loadTask = nil
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
    }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        let pipe = try await loadedPipe()
        var options = DecodingOptions()
        options.task = .transcribe
        if case .pinned(let lang) = languageMode {
            options.language = lang.rawValue
        }
        // Anti-hallucination stack per docs/04 §2.
        options.temperature = 0
        options.temperatureFallbackCount = 5
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        options.usePrefillPrompt = false

        let results = try await pipe.transcribe(audioArray: audio.samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = detectLanguage(
            reported: results.first?.language,
            text: text,
            mode: languageMode
        )
        let segments: [TranscriptionResult.TimedSegment] = results.flatMap { result in
            result.segments.map {
                .init(
                    text: $0.text.trimmingCharacters(in: .whitespaces),
                    start: Double($0.start),
                    end: Double($0.end)
                )
            }
        }
        return TranscriptionResult(text: text, detectedLanguage: detected, segments: segments)
    }

    public nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        // v1: accumulate and emit one final update; live partials for the HUD
        // arrive in a follow-up (streaming preview is display-only per FR-4.1,
        // so correctness is unaffected).
        AsyncThrowingStream { continuation in
            let task = Task {
                var samples: [Float] = []
                for await chunk in audio {
                    samples.append(contentsOf: chunk.samples)
                }
                do {
                    let result = try await self.transcribe(
                        PCMChunk(samples: samples),
                        languageMode: languageMode,
                        dictionaryTerms: dictionaryTerms
                    )
                    continuation.yield(.init(kind: .final, text: result.text, detectedLanguage: result.detectedLanguage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {
        pipe = nil
        loadTask?.cancel()
        loadTask = nil
    }

    private nonisolated func detectLanguage(reported: String?, text: String, mode: LanguageMode) -> Language {
        if case .pinned(let lang) = mode { return lang }
        if let reported, let lang = Language(rawValue: reported) { return lang }
        return text.containsHanCharacters ? .chinese : .english
    }
}
#else
/// Non-Apple platforms: the engine is unavailable; SessionKit tests use fakes.
public enum WhisperKitEngineInfo {
    public static let isSupported = false
}
#endif
