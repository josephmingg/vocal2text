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
    private var boostLoadFailedAt: Date?
    /// The boosting session and the term set it was built for.
    private var boost: (key: [String], session: VocabularyBoostingSession)?
    /// The term set of the background build in flight, if any.
    private var boostBuildKey: [String]?
    /// The single in-flight load of the boost models; builds wait on it.
    private var boostModelLoad: Task<Void, Never>?
    /// Bumped by `unload`, so a build that finishes afterwards is dropped.
    private var boostGeneration = 0

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

    /// True when the Parakeet models are downloaded. The router sends a
    /// take here only then (docs/17 G2.1): until the download finishes in
    /// the background, English keeps working on Whisper.
    public static func modelsAreOnDisk() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
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
            let session = readyBoostSession(for: boostTerms) {
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

    /// Loads the vocabulary boost's models and builds its session for
    /// `terms` in the background, so a later take can use it. Safe to call
    /// often: a build for the same terms is not repeated.
    public func prepareVocabularyBoost(terms: [String]) {
        let eligible = VocabularyBoost.eligibleTerms(terms)
        guard !eligible.isEmpty else { return }
        startBoostBuild(for: eligible)
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
        boostGeneration += 1
        boostBuildKey = nil
        boost = nil
        ctcModels = nil
        ctcTokenizer = nil
    }

    // MARK: - Vocabulary boost

    /// One key per term set, whatever order the ranking gives it, so a
    /// reshuffle of use counts does not rebuild the session.
    private static func boostKey(_ terms: [String]) -> [String] {
        terms.map { $0.lowercased() }.sorted()
    }

    /// The session for `terms` if it is already built. Never builds inside a
    /// take: a missing or stale session starts a background build, and this
    /// take goes unboosted.
    private func readyBoostSession(for terms: [String]) -> VocabularyBoostingSession? {
        if let boost, boost.key == Self.boostKey(terms) { return boost.session }
        startBoostBuild(for: terms)
        return nil
    }

    private func startBoostBuild(for terms: [String]) {
        let key = Self.boostKey(terms)
        if boost?.key == key || boostBuildKey == key { return }
        // Offline or a failed download: retry at most every ten minutes
        // instead of on every take.
        if ctcModels == nil, let failedAt = boostLoadFailedAt,
            Date().timeIntervalSince(failedAt) < 600 {
            return
        }
        // A build for an older term set may still be running; it is not
        // cancelled (it may be mid-download), it just loses to this one.
        boostBuildKey = key
        let generation = boostGeneration
        Task(priority: .utility) {
            await self.buildBoost(terms: terms, key: key, generation: generation)
        }
    }

    private func buildBoost(terms: [String], key: [String], generation: Int) async {
        defer {
            if boostBuildKey == key { boostBuildKey = nil }
        }
        await loadBoostModelsOnce()
        guard generation == boostGeneration, boostBuildKey == key,
            let models = ctcModels, let tokenizer = ctcTokenizer
        else { return }
        let vocabularyTerms = terms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = tokenizer.encode(term)
            return tokenIds.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: tokenIds)
        }
        guard !vocabularyTerms.isEmpty else { return }
        do {
            let session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: vocabularyTerms),
                ctcModels: models
            )
            // A newer term set started meanwhile: its own build takes over.
            guard generation == boostGeneration, boostBuildKey == key else { return }
            boost = (key, session)
            VocalLog.engine.info("vocabulary boost ready for \(vocabularyTerms.count) terms")
        } catch {
            VocalLog.engine.error(
                "vocabulary boost setup failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Loads the CTC models and tokenizer, once: concurrent builds share the
    /// same download instead of racing on one cache directory.
    private func loadBoostModelsOnce() async {
        if ctcModels != nil, ctcTokenizer != nil { return }
        if let load = boostModelLoad {
            await load.value
            return
        }
        let generation = boostGeneration
        let load = Task(priority: .utility) {
            await self.loadBoostModels(generation: generation)
        }
        boostModelLoad = load
        await load.value
        boostModelLoad = nil
    }

    private func loadBoostModels(generation: Int) async {
        do {
            VocalLog.engine.info("loading the vocabulary boost model (parakeet-ctc-110m)")
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m)
            )
            guard generation == boostGeneration else { return }
            ctcModels = models
            ctcTokenizer = tokenizer
            boostLoadFailedAt = nil
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
