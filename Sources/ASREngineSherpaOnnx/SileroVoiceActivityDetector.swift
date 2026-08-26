import ASRKit
import CoreModels
import Foundation
import ModelStore

/// The Silero VAD export sherpa-onnx runs (docs/15 step 16). The runtime
/// already ships inside the sherpa-onnx dependency pulled in for the Burmese
/// engine; only this one small model file is fetched, from the same release
/// bucket the Burmese archives come from. Facts kept outside the platform
/// guard so they are testable on Linux.
public enum SileroVADModel {
    public static let fileName = "silero_vad.onnx"
    public static let url = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
    )!
    /// Exact Content-Length the release asset serves — measured, not estimated.
    public static let bytes: Int64 = 643_854
    /// Pinned so a silently replaced asset fails the download instead of
    /// feeding an unverified model to C code.
    public static let sha256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
}

#if canImport(SherpaOnnx)
import SherpaOnnx

/// Batch speech locator for finished takes (docs/15 step 16): feeds the take
/// through Silero VAD and reduces the detected segments to one padded span
/// via `SpeechTrim`. Unavailable VAD (download failed, file missing) returns
/// the full range — losing VAD must never lose a take.
///
/// The wrapper class is not Sendable (it owns a C pointer), so it lives
/// inside the actor; one instance is kept and `reset()` between takes.
public actor SileroVoiceActivityDetector {

    /// Silero's native analysis window at 16 kHz.
    static let windowSamples = 512
    /// Kept speech is padded this much on each side so soft onsets and
    /// trailing consonants survive the trim.
    static let paddingSeconds = 0.25
    /// Below Silero's default 0.5 on purpose: dropping a genuinely spoken
    /// short word ("yes") would discard the whole take, which is the
    /// expensive direction to be wrong in.
    static let minSpeechSeconds: Float = 0.1

    private let rootDirectory: URL
    private let autoDownload: Bool
    private let downloader = ModelDownloader()
    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - rootDirectory: the ModelStore root; defaults to
    ///     `Application Support/Vocal/models`. The file installs at
    ///     `<root>/sherpa-onnx/silero-vad/silero_vad.onnx`.
    ///   - autoDownload: whether the first analysis may fetch the ~0.6 MB
    ///     model file.
    public init(rootDirectory: URL? = nil, autoDownload: Bool = true) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.autoDownload = autoDownload
    }

    /// Loads (downloading if allowed) ahead of the first take.
    public func prepare() async {
        _ = await loadedVAD()
    }

    /// The padded sample range containing the take's speech, nil when the
    /// take is silence, or the full range when VAD cannot run.
    public func analyze(_ audio: PCMChunk) async -> Range<Int>? {
        let samples = audio.samples
        guard !samples.isEmpty else { return nil }
        guard let vad = await loadedVAD() else { return samples.indices }

        vad.reset()
        var segments: [SpeechTrim.Segment] = []
        func drain() {
            while !vad.isEmpty() {
                let segment = vad.front()
                segments.append(SpeechTrim.Segment(start: segment.start, count: segment.n))
                vad.pop()
            }
        }
        var index = 0
        while index < samples.count {
            let end = min(index + Self.windowSamples, samples.count)
            vad.acceptWaveform(samples: Array(samples[index..<end]))
            // Drain finalized segments as they appear so the detector's
            // internal buffer stays small on long (locked) takes.
            drain()
            index = end
        }
        vad.flush()
        drain()
        vad.reset()

        return SpeechTrim.paddedSpan(
            segments: segments,
            totalSamples: samples.count,
            paddingSamples: Int(Self.paddingSeconds * Double(PCMChunk.sampleRate))
        )
    }

    // MARK: - Loading

    private func loadedVAD() async -> SherpaOnnxVoiceActivityDetectorWrapper? {
        while isLoading {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
        if let vad { return vad }
        isLoading = true
        defer {
            isLoading = false
            let waiters = loadWaiters
            loadWaiters = []
            for waiter in waiters { waiter.resume() }
        }

        let modelURL = modelFileURL()
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            guard autoDownload else { return nil }
            let spec = ModelFileSpec(
                relativePath: SileroVADModel.fileName,
                url: SileroVADModel.url,
                sha256: SileroVADModel.sha256,
                bytes: SileroVADModel.bytes
            )
            do {
                VocalLog.engine.info("downloading Silero VAD model (~0.6 MB)")
                try await downloader.download(file: spec, to: modelURL) { _ in }
            } catch {
                // Never fail a take over the gate that exists to save time:
                // the caller degrades to transcribing the whole take.
                VocalLog.engine.error(
                    "Silero VAD download failed — VAD disabled this launch: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        // The sherpa-onnx shim fatalErrors when creation fails, so the one
        // precondition it has — the file existing — is checked above.
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: modelURL.path,
                minSpeechDuration: Self.minSpeechSeconds,
                windowSize: Self.windowSamples
            ),
            sampleRate: Int32(PCMChunk.sampleRate),
            numThreads: 1
        )
        let loaded = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &config, buffer_size_in_seconds: 60
        )
        VocalLog.engine.info("Silero VAD ready")
        vad = loaded
        return loaded
    }

    private nonisolated func modelFileURL() -> URL {
        rootDirectory
            .appendingPathComponent("sherpa-onnx", isDirectory: true)
            .appendingPathComponent("silero-vad", isDirectory: true)
            .appendingPathComponent(SileroVADModel.fileName)
    }

    private static func defaultRootDirectory() -> URL {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Vocal", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }
}
#endif
