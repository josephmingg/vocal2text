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

    // AsrManager became an actor in FluidAudio 0.15 (it was a non-Sendable
    // class in 0.9, which needed an @unchecked Sendable box here), so plain
    // actor storage is now simply correct. Take-level serialization still
    // comes from the session's chained pipeline.
    private var manager: AsrManager?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    // Vocabulary boost (docs/17 G2.2): FluidAudio's CTC keyword spotter
    // (parakeet-ctc-110m) checks the take's audio for your dictionary words
    // and replaces a misheard word only when the audio supports the term.
    // Its models load in the background on first need — never inside a take.
    private let boostEnabled: @Sendable () -> Bool
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private var isLoadingBoostModels = false
    private var boostLoadFailedAt: Date?
    /// The boosting session for the last term list; rebuilt when it changes.
    private var boost: (terms: [String], session: VocabularyBoostingSession)?

    /// - Parameter boostEnabled: Read at every take, so a Settings toggle
    ///   applies to the next dictation.
    public init(boostEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.boostEnabled = boostEnabled
    }

    // Qualified: FluidAudio 0.15 exports its own `Language` enum, which makes
    // the bare name ambiguous in this file.
    public func availability(for language: CoreModels.Language) async -> EngineAvailability {
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
        let loaded = try await loadedManager()
        try Task.checkCancellation()
        let result: ASRResult
        do {
            // Fresh decoder state per utterance: each take is an independent
            // batch decode, not a continuation of the last one.
            var decoderState = TdtDecoderState.make()
            result = try await loaded.transcribe(audio.samples, decoderState: &decoderState)
        } catch {
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenTimings = result.tokenTimings ?? []
        // Word timings, grouped from the sub-word tokens: the preview window
        // slides on word boundaries (docs/17 G2.3).
        var segments = ASRKit.TranscriptionResult.TimedSegment.words(
            fromTokens: tokenTimings.map {
                ASRKit.TranscriptionResult.TimedSegment(
                    text: $0.token,
                    start: $0.startTime,
                    end: $0.endTime
                )
            }
        )

        let boostTerms = VocabularyBoost.eligibleTerms(dictionaryTerms)
        if !boostTerms.isEmpty, boostEnabled(), !text.isEmpty,
            let session = await boostSession(for: boostTerms) {
            try Task.checkCancellation()
            // Absorbs its own failures: boosting never breaks a take.
            if let rescored = await session.rescore(
                text: result.text, tokenTimings: tokenTimings, audioSamples: audio.samples
            ) {
                let boosted = rescored.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !boosted.isEmpty, boosted != text {
                    text = boosted
                    // The timings describe the words before the swap; better
                    // none than timings that contradict the text.
                    segments = []
                }
            }
        }

        // English-only model on an English-pinned route; shared detection
        // still runs so a mixed-script transcript is labeled honestly.
        let detected = LanguageDetector.detect(reportedTag: "en", text: text, mode: languageMode)
        return ASRKit.TranscriptionResult(text: text, detectedLanguage: detected, segments: segments)
    }

    /// Loads the vocabulary boost's models in the background, so the first
    /// take that has dictionary words can use them. Safe to call often.
    public func prepareVocabularyBoost() {
        startBoostModelLoad()
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
        boost = nil
        ctcModels = nil
        ctcTokenizer = nil
    }

    // MARK: - Vocabulary boost

    /// The boosting session for `terms`, or nil when the boost models are
    /// not loaded yet (their load is started, and this take goes unboosted).
    private func boostSession(for terms: [String]) async -> VocabularyBoostingSession? {
        if let boost, boost.terms == terms { return boost.session }
        guard let models = ctcModels, let tokenizer = ctcTokenizer else {
            startBoostModelLoad()
            return nil
        }
        let vocabularyTerms = terms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = tokenizer.encode(term)
            return tokenIds.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: tokenIds)
        }
        guard !vocabularyTerms.isEmpty else { return nil }
        do {
            let session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: vocabularyTerms),
                ctcModels: models
            )
            boost = (terms, session)
            return session
        } catch {
            VocalLog.engine.error(
                "vocabulary boost setup failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func startBoostModelLoad() {
        guard ctcModels == nil, !isLoadingBoostModels else { return }
        // Offline or a failed download: retry at most every ten minutes
        // instead of on every take.
        if let failedAt = boostLoadFailedAt, Date().timeIntervalSince(failedAt) < 600 { return }
        isLoadingBoostModels = true
        Task(priority: .utility) { await self.loadBoostModels() }
    }

    private func loadBoostModels() async {
        defer { isLoadingBoostModels = false }
        do {
            VocalLog.engine.info("loading the vocabulary boost model (parakeet-ctc-110m)")
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m)
            )
            ctcModels = models
            ctcTokenizer = tokenizer
            boostLoadFailedAt = nil
            VocalLog.engine.info("vocabulary boost ready")
        } catch {
            boostLoadFailedAt = Date()
            VocalLog.engine.error(
                "vocabulary boost model load failed: \(String(describing: error), privacy: .public)"
            )
        }
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
            // 0.15 API: models ride in at init; the separate initialize(models:)
            // step no longer exists.
            let loaded = AsrManager(config: .default, models: models)
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
