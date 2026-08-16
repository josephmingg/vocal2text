import ASRKit
import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Platform capability probe: true where AVFoundation-backed capture compiles.
public enum AudioPipelineInfo {
    public static let isSupported: Bool = true
}

/// Errors thrown by `MicrophoneCapture.start()`.
public enum CaptureError: Error, Sendable, Equatable {
    case alreadyCapturing
    case formatUnavailable
    case engineStartFailed(String)
}

/// One live capture: the chunk stream plus stop/cancel handles. Mirrors
/// SessionKit's `CaptureSession` shape; AudioPipeline does not depend on
/// SessionKit (Package.swift), so the app target — which imports both — wraps
/// this in a trivial `AudioCapturing` adapter.
public struct MicrophoneSession: Sendable {
    public var chunks: AsyncStream<PCMChunk>
    /// Crash-recovery sidecar: raw 16 kHz mono Float32 samples, no header,
    /// appended progressively while recording (FR-11.3).
    public var recoveryFileURL: URL
    /// Stop capturing and return the complete utterance audio.
    public var finish: @Sendable () async -> PCMChunk
    /// Abort; in-memory audio is discarded but the recovery file stays (FR-1.6).
    public var cancel: @Sendable () async -> Void

    public init(
        chunks: AsyncStream<PCMChunk>,
        recoveryFileURL: URL,
        finish: @escaping @Sendable () async -> PCMChunk,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.chunks = chunks
        self.recoveryFileURL = recoveryFileURL
        self.finish = finish
        self.cancel = cancel
    }
}

/// AVAudioEngine microphone capture (docs/03 §4): tap the input node at its
/// native hardware format (tap format requests are ignored), convert with
/// AVAudioConverter to 16 kHz mono Float32, and stream `PCMChunk`s.
///
/// v1 skeleton: no `AVAudioEngineConfigurationChange` converter rebuild yet, and
/// converter-internal tail frames (a few ms) are not flushed at finish.
public actor MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var monoInputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var accumulated: [Float] = []
    private var nativeContinuation: AsyncStream<[Float]>.Continuation?
    private var chunkContinuation: AsyncStream<PCMChunk>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var recoveryURL: URL?
    private var recoveryHandle: FileHandle?
    private var isCapturing = false

    public init() {}

    /// Begin capturing. The returned session's `chunks` yields converted audio
    /// as it arrives; call `finish` to stop and receive the concatenated take.
    public func start() async throws -> MicrophoneSession {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        // Tap extraction takes channel 0 only, so the converter's input side is
        // mono at the hardware rate — never the (possibly multichannel) native format.
        guard hardwareFormat.sampleRate > 0,
              let monoInput = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: hardwareFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let target = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(PCMChunk.sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: monoInput, to: target)
        else {
            throw CaptureError.formatUnavailable
        }

        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocal-capture-\(UUID().uuidString).pcmf32")
        _ = FileManager.default.createFile(atPath: recoveryURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: recoveryURL)

        let (nativeStream, nativeContinuation) = AsyncStream.makeStream(of: [Float].self)
        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: PCMChunk.self)

        self.engine = engine
        self.converter = converter
        self.monoInputFormat = monoInput
        self.targetFormat = target
        self.recoveryURL = recoveryURL
        self.recoveryHandle = handle
        self.nativeContinuation = nativeContinuation
        self.chunkContinuation = chunkContinuation
        self.accumulated = []
        self.isCapturing = true

        // The tap runs on an audio thread: extract a Sendable [Float] payload
        // and hand it to the actor through an ordered AsyncStream. Explicitly
        // @Sendable so the closure is valid under either SDK spelling of
        // AVAudioNodeTapBlock.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            let samples = MicrophoneCapture.monoSamples(from: buffer)
            if !samples.isEmpty {
                nativeContinuation.yield(samples)
            }
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: hardwareFormat, block: tap)

        processingTask = Task.detached { [weak self] in
            for await samples in nativeStream {
                await self?.ingest(samples)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            let reason = String(describing: error)
            await stopEngineAndDrain()
            accumulated = []
            if let url = self.recoveryURL {
                try? FileManager.default.removeItem(at: url)
            }
            clearFormats()
            throw CaptureError.engineStartFailed(reason)
        }

        return MicrophoneSession(
            chunks: chunkStream,
            recoveryFileURL: recoveryURL,
            finish: { [weak self] in
                guard let self else { return PCMChunk(samples: []) }
                return await self.finishCapture()
            },
            cancel: { [weak self] in
                await self?.cancelCapture()
            }
        )
    }

    // MARK: - Private

    private func ingest(_ nativeSamples: [Float]) {
        guard let converter,
              let inputFormat = monoInputFormat,
              let outputFormat = targetFormat,
              !nativeSamples.isEmpty
        else { return }

        let frameCount = AVAudioFrameCount(nativeSamples.count)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return
        }
        inBuffer.frameLength = frameCount
        if let channelData = inBuffer.floatChannelData {
            for index in 0..<nativeSamples.count {
                channelData[0][index] = nativeSamples[index]
            }
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(nativeSamples.count) * ratio).rounded(.up)) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error,
              outBuffer.frameLength > 0,
              let outChannels = outBuffer.floatChannelData
        else { return }

        let converted = Array(UnsafeBufferPointer(start: outChannels[0], count: Int(outBuffer.frameLength)))
        accumulated.append(contentsOf: converted)
        chunkContinuation?.yield(PCMChunk(samples: converted))
        let data = converted.withUnsafeBufferPointer { Data(buffer: $0) }
        try? recoveryHandle?.write(contentsOf: data)
    }

    /// Stop the engine, then drain the ordered native-sample stream so every
    /// tapped buffer is converted and appended before the take is read.
    private func stopEngineAndDrain() async {
        guard isCapturing else { return }
        isCapturing = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        nativeContinuation?.finish()
        nativeContinuation = nil
        if let task = processingTask {
            await task.value
        }
        processingTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        try? recoveryHandle?.close()
        recoveryHandle = nil
        engine = nil
        converter = nil
    }

    private func finishCapture() async -> PCMChunk {
        await stopEngineAndDrain()
        let samples = accumulated
        accumulated = []
        if let url = recoveryURL {
            // Take delivered in full — the crash-recovery copy is obsolete.
            try? FileManager.default.removeItem(at: url)
        }
        clearFormats()
        return PCMChunk(samples: samples)
    }

    private func cancelCapture() async {
        await stopEngineAndDrain()
        accumulated = []
        // Recovery file intentionally kept: cancelled takes stay recoverable (FR-1.6).
        clearFormats()
    }

    private func clearFormats() {
        recoveryURL = nil
        monoInputFormat = nil
        targetFormat = nil
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}

#else
/// Non-Apple platforms: capture is unavailable; SessionKit tests use scripted fakes.
public enum AudioPipelineInfo {
    public static let isSupported: Bool = false
}
#endif
