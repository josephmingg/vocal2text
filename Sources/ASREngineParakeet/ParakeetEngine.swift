import ASRKit
import CoreModels
import Foundation

#if canImport(FluidAudio)
import FluidAudio

/// The raw-speed engine (docs/15 step 14): NVIDIA Parakeet TDT 0.6B v2 via
/// FluidAudio's CoreML export, running on the Neural Engine at two orders of
/// magnitude past real time. English-only by design — the router sends
/// pinned-English takes here; auto mode and every other pin stay on their
/// existing engines, so code-switching accuracy is untouched.
///
/// FluidAudio downloads and caches its own models (Application Support,
/// managed by the library), the same shape as WhisperKit; ModelStore is not
/// involved.
public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let id = "parakeet"
    public nonisolated let displayName = "Parakeet TDT v2 (Neural Engine)"

    /// Rough download size for the availability report, matching the
    /// catalog's convention of honest approximations.
    static let approximateDownloadBytes: Int64 = 600_000_000

    // AsrManager is a non-Sendable class whose work methods are async, so
    // actor isolation alone cannot express its confinement (awaiting them
    // would "send" it). `unsafe` records the actual discipline: the manager
    // is created once behind the load-coalescing gate below and only touched
    // from this actor's methods; take-level serialization comes from the
    // session's chained pipeline, the same contract WhisperKitEngine relies
    // on.
    private nonisolated(unsafe) var manager: AsrManager?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func availability(for language: Language) async -> EngineAvailability {
        guard language == .english else {
            return .unsupported(reason: "Parakeet v2 is English-only; other languages use their own engines")
        }
        if manager != nil { return .ready }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        return AsrModels.modelsExist(at: cache, version: .v2)
            ? .ready
            : .needsDownload(bytes: Self.approximateDownloadBytes)
    }

    public func prepare(languageMode: LanguageMode) async throws {
        _ = try await loadedManager()
    }

    /// True once the models are resident — the first-run HUD hint reads this,
    /// mirroring the other engines.
    public var isModelLoaded: Bool { manager != nil }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> ASRKit.TranscriptionResult {
        let manager = try await loadedManager()
        try Task.checkCancellation()
        let result: ASRResult
        do {
            result = try await manager.transcribe(audio.samples, source: .microphone)
        } catch {
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // English-only model on an English-pinned route; shared detection
        // still runs so a mixed-script transcript is labeled honestly.
        let detected = LanguageDetector.detect(reportedTag: "en", text: text, mode: languageMode)
        let segments: [ASRKit.TranscriptionResult.TimedSegment] =
            (result.tokenTimings ?? []).map {
                ASRKit.TranscriptionResult.TimedSegment(
                    text: $0.token,
                    start: $0.startTime,
                    end: $0.endTime
                )
            }
        return ASRKit.TranscriptionResult(text: text, detectedLanguage: detected, segments: segments)
    }

    public nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        // Batch contract, matching the other engines: accumulate, emit one
        // final update. FluidAudio's true streaming decoder is the seam the
        // Phase 3 prefix-commit work builds on.
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
                    continuation.yield(
                        .init(kind: .final, text: result.text, detectedLanguage: result.detectedLanguage)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {
        manager = nil
    }

    // MARK: - Loading

    private func loadedManager() async throws -> AsrManager {
        while isLoading {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
        if let manager { return manager }
        isLoading = true
        defer {
            isLoading = false
            let waiters = loadWaiters
            loadWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        do {
            VocalLog.engine.info(
                "loading Parakeet TDT v2 — first run downloads ~600 MB of CoreML models"
            )
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let loaded = AsrManager(config: .default)
            try await loaded.initialize(models: models)
            VocalLog.engine.info("Parakeet TDT v2 ready")
            manager = loaded
            return loaded
        } catch {
            VocalLog.engine.error(
                "Parakeet model load failed: \(String(describing: error), privacy: .public)"
            )
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
    }
}
#else
/// Non-Apple platforms: FluidAudio is unavailable; routing tests use fakes.
public enum ParakeetEngineInfo {
    public static let isSupported = false
}
#endif
