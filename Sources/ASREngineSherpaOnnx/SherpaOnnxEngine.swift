import ASRKit
import CoreModels
import Foundation
import ModelStore

/// One Omnilingual ASR CTC export this engine can run, named by the catalog
/// (docs/04 §5). The archive URLs come from the FLEURS my_mm benchmark run
/// (docs/benchmarks/burmese-asr-2026-08-17.md) and the byte counts are the
/// exact Content-Length each release asset serves — measured, not estimated.
public struct SherpaOnnxModelVariant: Sendable, Hashable {
    /// Matches the `ModelCatalog` entry id, so the store and the engine agree
    /// on the install directory: `<root>/sherpa-onnx/<id>/`.
    public var catalogID: String
    public var displayName: String
    /// The release archive (tar.bz2) containing `model.int8.onnx` + `tokens.txt`.
    public var archiveURL: URL
    /// Download size — what `availability` reports before install.
    public var archiveBytes: Int64
    /// The single directory the archive extracts to.
    public var extractedDirectoryName: String

    /// Mac tier (docs/11 G13 decision): 10.78% CER, RTF 0.51 on CPU.
    public static let omnilingual1B = SherpaOnnxModelVariant(
        catalogID: "omni-asr-ctc-1b-int8",
        displayName: "Omnilingual ASR CTC 1B (int8)",
        archiveURL: URL(
            string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-int8-2025-11-12.tar.bz2"
        )!,
        archiveBytes: 786_404_815,
        extractedDirectoryName: "sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-int8-2025-11-12"
    )

    /// iPhone tier candidate (15.19% CER). Not wired into the iOS app until
    /// on-device RTF is measured (docs/11 G13).
    public static let omnilingual300M = SherpaOnnxModelVariant(
        catalogID: "omni-asr-ctc-300m-int8",
        displayName: "Omnilingual ASR CTC 300M (int8)",
        archiveURL: URL(
            string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12.tar.bz2"
        )!,
        archiveBytes: 292_571_207,
        extractedDirectoryName: "sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12"
    )

    /// Paths of the files the recognizer needs, inside the install directory.
    var modelRelativePath: String { extractedDirectoryName + "/model.int8.onnx" }
    var tokensRelativePath: String { extractedDirectoryName + "/tokens.txt" }
}

#if canImport(SherpaOnnx)
import SherpaOnnx

/// Burmese engine (docs/04 §1, docs/11 G13): Meta's Omnilingual ASR CTC int8
/// export running on sherpa-onnx. Benchmarked at 10.78% CER on FLEURS my_mm
/// (1B) versus Whisper's 80–100% WER-class output, which is why Burmese routes
/// here instead of through the primary engine.
///
/// v1 reaches this engine only via a pin (menu-bar မြန်မာ or a profile
/// language override) — `LanguageRoutingEngine` documents why auto mode
/// cannot route here after the fact.
public actor SherpaOnnxEngine: TranscriptionEngine {
    public nonisolated let id = "sherpa-onnx"
    public nonisolated let displayName: String

    private let variant: SherpaOnnxModelVariant
    private let rootDirectory: URL
    /// False lets tests (and a future settings UI) exercise the not-installed
    /// paths without this actor ever touching the network.
    private let autoDownload: Bool
    private let downloader: ModelDownloader

    // SherpaOnnxOfflineRecognizer is a non-Sendable class wrapping a C
    // pointer, so it lives inside the actor and concurrent loads coalesce
    // with a waiter queue — same shape as WhisperKitEngine.
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - variant: which export to run; `.omnilingual1B` is the Mac tier.
    ///   - rootDirectory: the ModelStore root; defaults to
    ///     `Application Support/Vocal/models`. The install directory is
    ///     `<root>/sherpa-onnx/<catalogID>/` either way.
    ///   - autoDownload: whether `prepare` may fetch the model archive on
    ///     first use (macOS only — iOS has no extraction path yet).
    public init(
        variant: SherpaOnnxModelVariant = .omnilingual1B,
        rootDirectory: URL? = nil,
        autoDownload: Bool = true
    ) {
        self.variant = variant
        self.displayName = variant.displayName
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.autoDownload = autoDownload
        self.downloader = ModelDownloader()
    }

    public func availability(for language: Language) async -> EngineAvailability {
        guard language == .burmese else {
            // Omnilingual covers EN/ZH too, but in this app those belong to
            // the primary engine; saying "unsupported" keeps any future
            // routing UI from offering a worse path for them.
            return .unsupported(reason: "\(language.displayName) runs on the primary engine")
        }
        return modelFilesPresent() ? .ready : .needsDownload(bytes: variant.archiveBytes)
    }

    public func prepare(languageMode: LanguageMode) async throws {
        _ = try await loadedRecognizer()
    }

    /// True once the model is resident — the Mac app uses this for the
    /// first-run HUD hint, mirroring `WhisperKitEngine.isModelLoaded`.
    public var isModelLoaded: Bool { recognizer != nil }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        let recognizer = try await loadedRecognizer()
        try Task.checkCancellation()
        // Synchronous C decode on the actor. At the benchmarked RTF (0.51 on
        // CPU for 1B) this blocks a cooperative thread for about half the
        // utterance's duration; acceptable for transcribe-on-release, and the
        // session's single-take design means nothing else needs this actor
        // meanwhile.
        let decoded = recognizer.decode(samples: audio.samples, sampleRate: PCMChunk.sampleRate)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // CTC greedy decode reports no language tag for omnilingual models
        // (`lang` is SenseVoice-only), so detection rides on the script.
        let detected = LanguageDetector.detect(
            reportedTag: decoded.lang.isEmpty ? nil : decoded.lang,
            text: text,
            mode: languageMode
        )
        return TranscriptionResult(text: text, detectedLanguage: detected)
    }

    public nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        // Offline CTC model: accumulate and emit one final update, the same
        // contract WhisperKitEngine ships (partials are HUD-only per FR-4.1).
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
        recognizer = nil
    }

    // MARK: - Loading

    private func loadedRecognizer() async throws -> SherpaOnnxOfflineRecognizer {
        while isLoading {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
        if let recognizer { return recognizer }
        isLoading = true
        defer {
            isLoading = false
            let waiters = loadWaiters
            loadWaiters = []
            for waiter in waiters { waiter.resume() }
        }

        if !modelFilesPresent() {
            guard autoDownload else { throw TranscriptionError.modelNotInstalled }
            try await downloadAndExtract()
        }
        // Belt and braces before handing paths to C: the sherpa-onnx Swift
        // shim `fatalError`s when the recognizer cannot be created, so a
        // missing file must be caught here as a thrown error instead.
        let model = installDirectory().appendingPathComponent(variant.modelRelativePath)
        let tokens = installDirectory().appendingPathComponent(variant.tokensRelativePath)
        guard FileManager.default.fileExists(atPath: model.path),
            FileManager.default.fileExists(atPath: tokens.path)
        else {
            throw TranscriptionError.modelNotInstalled
        }

        print("Vocal: loading \(displayName) from \(installDirectory().path)…")
        // Config structs hold `const char *` borrowed from bridged NSStrings,
        // so they are built and consumed inside this one scope — never stored
        // (upstream's own examples follow the same pattern).
        let omnilingual = sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(model: model.path)
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens.path,
            numThreads: Self.decodeThreads(),
            omnilingual: omnilingual
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        let loaded = SherpaOnnxOfflineRecognizer(config: &config)
        print("Vocal: \(displayName) ready")
        recognizer = loaded
        return loaded
    }

    /// CPU decode benefits from a few threads; leave headroom for the app.
    private static func decodeThreads() -> Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    // MARK: - Install

    private nonisolated func installDirectory() -> URL {
        rootDirectory
            .appendingPathComponent("sherpa-onnx", isDirectory: true)
            .appendingPathComponent(variant.catalogID, isDirectory: true)
    }

    private nonisolated func modelFilesPresent() -> Bool {
        let directory = installDirectory()
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(variant.modelRelativePath).path
        )
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(variant.tokensRelativePath).path
            )
    }

    private func downloadAndExtract() async throws {
        #if os(macOS)
        let directory = installDirectory()
        let archive = directory.appendingPathComponent(variant.archiveURL.lastPathComponent)
        let spec = ModelFileSpec(
            relativePath: archive.lastPathComponent,
            url: variant.archiveURL,
            bytes: variant.archiveBytes
        )
        print("Vocal: downloading \(displayName) (~\(variant.archiveBytes / 1_000_000) MB)…")
        do {
            // ModelDownloader resumes interrupted downloads from the .partial
            // file, so a failed first attempt does not restart from zero.
            try await downloader.download(file: spec, to: archive) { _ in }
            try await Self.extractTarBz2(archive, into: directory)
        } catch {
            print("Vocal: \(displayName) install FAILED: \(error)")
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
        // The archive is dead weight once extracted (≈0.8 GB for 1B).
        try? FileManager.default.removeItem(at: archive)
        #else
        // iOS: no Process, so no tar.bz2 extraction path yet. The 300M tier
        // ships only after on-device RTF is measured (docs/11 G13), and its
        // installer will land with it.
        throw TranscriptionError.engineUnavailable(
            "Burmese model download is not supported on this platform yet"
        )
        #endif
    }

    #if os(macOS)
    /// Extracts with the system tar (bzip2 built in), off the main actor.
    private static func extractTarBz2(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Handler installed before run(): installing it after the process
            // has already exited would never fire.
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.engineUnavailable(
                "tar exited with status \(process.terminationStatus)"
            )
        }
    }
    #endif

    private static func defaultRootDirectory() -> URL {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Vocal", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }
}
#else
/// Non-Apple platforms: the sherpa-onnx runtime is unavailable; routing tests
/// use fakes. `SherpaOnnxModelVariant` above stays real everywhere so the
/// catalog facts (URLs, sizes) are testable on Linux.
public enum SherpaOnnxEngineInfo {
    public static let isSupported = false
}
#endif
