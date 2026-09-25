import ASRKit
import CoreModels
import Foundation

#if canImport(WhisperKit)
import CoreML
import WhisperKit

/// Primary EN/ZH engine (docs/04 §1): Whisper large-v3-turbo via WhisperKit.
/// One model covers both languages including mid-sentence code-switching.
///
/// Note: WhisperKit's own module exports a `TranscriptionResult` class, so this
/// file qualifies ours as `ASRKit.TranscriptionResult` throughout.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let id = "whisperkit"
    public nonisolated let displayName = "WhisperKit (Whisper large-v3-turbo)"

    private var modelName: String
    private let modelFolder: URL?
    private var pipe: WhisperKit?
    // WhisperKit is not Sendable, so concurrent loads coalesce with a
    // waiter queue instead of a shared Task (docs/09 lesson, adapted).
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// The shipping default (docs/04 §1). Public so the settings layer and
    /// the engine cannot disagree about what "default" means.
    public static let defaultModelName = "openai_whisper-large-v3-v20240930_turbo"

    public init(
        modelName: String = WhisperKitEngine.defaultModelName, modelFolder: URL? = nil
    ) {
        self.modelName = modelName
        self.modelFolder = modelFolder
    }

    public func availability(for language: Language) async -> EngineAvailability {
        // Download state first: Burmese is served by the same ~600 MB model,
        // so it must not skip the needs-download report on a fresh install.
        if pipe == nil {
            return .needsDownload(bytes: 626_000_000)
        }
        // Whisper accepts a `my` token, but its Burmese output is unusable —
        // 80–100% WER with hallucination loops (docs/04 Appendix A). Say so
        // rather than let the UI imply EN/ZH-grade accuracy; the fix is a
        // Burmese-capable engine (ModelCatalog lists the candidates), not a
        // different Whisper variant.
        return language == .burmese ? .readyWithCaveat(Self.burmeseCaveat) : .ready
    }

    static let burmeseCaveat = BurmeseSupportNote.shortCaveat

    public func prepare(languageMode: LanguageMode) async throws {
        _ = try await loadedPipe()
    }

    /// Switches the served model (docs/15 step 15 — Settings → Models).
    /// Applies on the next load: the resident pipe is dropped, so the next
    /// take (or preload) brings the chosen model up. A no-op for the same
    /// name, so callers can wire it straight to a settings publisher.
    public func setModel(name: String) {
        guard name != modelName else { return }
        VocalLog.engine.info("switching WhisperKit model to \(name, privacy: .public)")
        modelName = name
        pipe = nil
    }

    private func loadedPipe() async throws -> WhisperKit {
        while isLoading {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
        if let pipe { return pipe }
        isLoading = true
        defer {
            isLoading = false
            let waiters = loadWaiters
            loadWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        // Snapshot: `setModel` can land while the load below is suspended,
        // and caching the stale pipe would silently keep serving the old
        // model. The caller that asked still gets the pipe it asked for.
        let requested = modelName
        do {
            VocalLog.engine.info(
                "loading WhisperKit model \(requested, privacy: .public) — first run downloads the model and compiles for the Neural Engine"
            )
            let config = WhisperKitConfig(
                model: requested,
                modelFolder: modelFolder?.path,
                computeOptions: Self.computeOptions
            )
            let loaded = try await WhisperKit(config)
            VocalLog.engine.info("WhisperKit model ready")
            if requested == modelName {
                pipe = loaded
            }
            return loaded
        } catch {
            VocalLog.engine.error(
                "WhisperKit model load failed: \(String(describing: error), privacy: .public)"
            )
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
    }

    /// True once the model is resident — the app uses this to explain
    /// first-run latency honestly in the HUD.
    public var isModelLoaded: Bool { pipe != nil }

    /// Pinned compute units (docs/15 step 18): letting CoreML renegotiate
    /// placement per load is how the same model lands on the ANE one launch
    /// and the GPU the next, with visibly different latency. The encoder and
    /// decoder belong on the Neural Engine on every Apple Silicon target; the
    /// mel stage is tiny and runs wherever it costs least. iOS additionally
    /// must never schedule onto the GPU: a Metal-scheduled model crashes when
    /// the app is backgrounded mid-inference (docs/04).
    nonisolated static var computeOptions: ModelComputeOptions {
        #if os(iOS)
        ModelComputeOptions(
            melCompute: .cpuAndNeuralEngine,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        #else
        ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        #endif
    }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> ASRKit.TranscriptionResult {
        let pipe = try await loadedPipe()
        let promptTokens = Self.biasPromptTokens(for: dictionaryTerms, tokenizer: pipe.tokenizer)

        var results = try await pipe.transcribe(
            audioArray: audio.samples,
            decodeOptions: Self.decodingOptions(
                language: languageMode.pinnedLanguage?.rawValue, promptTokens: promptTokens
            )
        )

        // Auto mode only ever serves the app's languages. Whisper's detector
        // spans 99, and on short or accented takes it picks a neighbour
        // (English → "nl"/"cy", Mandarin → "ja"); with the prefill on, that
        // language token is then *forced*, producing translated or garbled
        // text. One re-decode pinned to the closest supported language.
        if case .auto = languageMode,
            let reported = results.first?.language,
            Language(rawValue: reported) == nil
        {
            let text = results.map(\.text).joined()
            let fallback: Language =
                Self.hanLikeLanguageTags.contains(reported) || text.containsHanCharacters
                ? .chinese : .english
            print("Vocal: Whisper detected '\(reported)'; re-decoding as \(fallback.rawValue)")
            results = try await pipe.transcribe(
                audioArray: audio.samples,
                decodeOptions: Self.decodingOptions(
                    language: fallback.rawValue, promptTokens: promptTokens
                )
            )
        }

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = Self.detectLanguage(
            reported: results.first?.language,
            text: text,
            mode: languageMode
        )
        let segments: [ASRKit.TranscriptionResult.TimedSegment] = results.flatMap { result in
            result.segments.map {
                ASRKit.TranscriptionResult.TimedSegment(
                    text: $0.text.trimmingCharacters(in: .whitespaces),
                    start: Double($0.start),
                    end: Double($0.end)
                )
            }
        }
        return ASRKit.TranscriptionResult(text: text, detectedLanguage: detected, segments: segments)
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
    }

    /// Tags whose misdetection almost always means Mandarin speech.
    private static let hanLikeLanguageTags: Set<String> = ["ja", "yue", "wuu"]

    /// Decoding options for one pass; `language` nil means detect.
    ///
    /// The prefill prompt stays ON for every take. With `usePrefillPrompt =
    /// false` WhisperKit never forces the language token — a pinned language
    /// was silently ignored on every take without dictionary terms, and the
    /// result was merely *labelled* with the pin. `DecodingOptions()` derives
    /// `detectLanguage` from the initial prefill flag, so it is set
    /// explicitly: detect in auto mode (the detect loop then re-prefills
    /// with its answer), never when pinned.
    static func decodingOptions(language: String?, promptTokens: [Int]?) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.usePrefillPrompt = true
        options.detectLanguage = language == nil
        options.promptTokens = promptTokens
        // Anti-hallucination stack per docs/04 §2.
        options.temperature = 0
        options.temperatureFallbackCount = 5
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        return options
    }

    /// docs/15 step 24: dictionary terms ride in as Whisper's initial prompt,
    /// so the model *hears* "Kubernetes" instead of stage 2 correcting it
    /// after the fact. Bias terms only: a snippet (multi-line or long written
    /// form — DictionaryCSV's definition of one) would flood Whisper's ~223
    /// prompt-token window with template text, evicting the real terms and
    /// conditioning the decoder on unrelated "context" — a known repetition
    /// trigger. WhisperKit keeps the *suffix* when trimming, so the cap also
    /// makes which terms survive deterministic. No terms → no prompt.
    static func biasPromptTokens(
        for dictionaryTerms: [String], tokenizer: (any WhisperTokenizer)?
    ) -> [Int]? {
        let biasTerms = dictionaryTerms
            .filter { !$0.contains(where: \.isNewline) && $0.count <= 40 }
            .prefix(24)
        guard !biasTerms.isEmpty, let tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + biasTerms.joined(separator: ", "))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    private nonisolated static func detectLanguage(
        reported: String?,
        text: String,
        mode: LanguageMode
    ) -> Language {
        // Shared with every other adapter so the answer cannot vary by backend.
        LanguageDetector.detect(reportedTag: reported, text: text, mode: mode)
    }
}
#else
/// Non-Apple platforms: the engine is unavailable; SessionKit tests use fakes.
public enum WhisperKitEngineInfo {
    public static let isSupported = false
}
#endif
