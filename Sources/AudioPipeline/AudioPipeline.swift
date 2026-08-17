import ASRKit
import Foundation

/// Hygiene for the crash-recovery sidecars `MicrophoneCapture` writes while
/// recording (FR-11.3). Pure Foundation and outside the AVFoundation guard, so
/// it compiles — and is tested — on every platform.
public enum RecoveryFileReaper {
    public static let recoveryFilePrefix = "vocal-capture-"

    /// How long a cancelled take's raw audio stays recoverable (FR-1.6).
    public static let recoveryRetention: TimeInterval = 24 * 60 * 60

    /// Deletes recovery sidecars older than the FR-1.6 window.
    ///
    /// `cancelCapture` deliberately keeps its file so a cancelled take stays
    /// recoverable, and a crash mid-take leaves one behind too. Without this
    /// sweep those files are never removed by anything: each is an
    /// unencrypted recording of the user's voice accumulating in the temp
    /// directory for the lifetime of the install. Running it at capture start
    /// keeps the guarantee ("recoverable for 24 h") while bounding the
    /// residue to that same window.
    public static func reapExpiredRecoveryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(recoveryFilePrefix)
            && entry.pathExtension == "pcmf32"
        {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // An unreadable timestamp is treated as expired: the file is
            // orphaned raw audio either way.
            guard let modified else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            if now.timeIntervalSince(modified) > recoveryRetention {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

/// Reads back the crash/cancel sidecars `MicrophoneCapture` writes (FR-1.6,
/// FR-11.3): raw 16 kHz mono Float32, no header. The reaper writes the
/// retention policy; this reads what is still inside it.
public enum RecoveryStore {
    /// One recoverable take: its file and when it was written.
    public struct Candidate: Sendable, Hashable {
        public var url: URL
        public var modified: Date
        /// Seconds of audio, from the file size — 4 bytes per sample at
        /// 16 kHz, so no decode is needed to describe the take to the user.
        public var durationSeconds: Double

        public init(url: URL, modified: Date, durationSeconds: Double) {
            self.url = url
            self.modified = modified
            self.durationSeconds = durationSeconds
        }
    }

    /// The newest sidecar still inside the 24 h window, if any.
    ///
    /// Only takes worth recovering are offered: a file under half a second is
    /// the tail of an accidental tap, and offering it back as "your cancelled
    /// recording" would be a worse answer than offering nothing.
    public static func latestRecoverable(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minimumSeconds: Double = 0.5
    ) -> Candidate? {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }

        var best: Candidate?
        for entry in entries
        where entry.lastPathComponent.hasPrefix(RecoveryFileReaper.recoveryFilePrefix)
            && entry.pathExtension == "pcmf32"
        {
            let values = try? entry.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey,
            ])
            guard
                let modified = values?.contentModificationDate,
                let size = values?.fileSize,
                now.timeIntervalSince(modified) <= RecoveryFileReaper.recoveryRetention
            else { continue }
            let seconds = Double(size / MemoryLayout<Float>.size) / Double(PCMChunk.sampleRate)
            guard seconds >= minimumSeconds else { continue }
            let candidate = Candidate(url: entry, modified: modified, durationSeconds: seconds)
            if best == nil || modified > best!.modified {
                best = candidate
            }
        }
        return best
    }

    /// Decodes a sidecar back into samples. Returns nil rather than a partial
    /// take when the file is truncated to nothing or unreadable.
    public static func samples(at url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        // The sidecar is written in host byte order by the same machine that
        // reads it, so a straight reinterpretation is correct — and a
        // trailing partial sample (a crash mid-write) is dropped by `count`.
        return data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer.prefix(count))
        }
    }

    /// Removes a sidecar once its take has been recovered, so the same
    /// recording is never offered twice.
    public static func discard(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Converts captured audio into the 0…1 levels the HUD waveform draws
/// (FR-4.1). Pure and tested on every platform; the capture actor feeds it.
public enum AudioLevelMeter {
    /// Quietest level the meter shows. Speech in Float PCM sits around -30 to
    /// -12 dBFS, so a -60 dB floor keeps a soft voice clearly visible while
    /// room tone stays near the baseline.
    public static let floorDecibels: Float = -60

    /// Normalized display level for one chunk of 16 kHz mono Float samples.
    ///
    /// RMS on a decibel scale rather than raw amplitude: linear amplitude puts
    /// ordinary speech in the bottom tenth of the bar, which reads as "the mic
    /// is dead" — the exact question the waveform exists to answer.
    public static func level(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(rms)
        guard decibels.isFinite else { return 0 }
        let normalized = (decibels - floorDecibels) / -floorDecibels
        return min(max(normalized, 0), 1)
    }
}

/// How long a take's audio is kept (FR-5.1, docs/11 G9). Encodes the meaning
/// of Settings → History & Privacy → "Keep audio", which is stored as a day
/// count with two sentinels. Pure, so the rules are tested rather than
/// re-derived at each call site.
public enum AudioRetentionPolicy {
    /// "Never" — the take's audio is not written at all.
    public static let never = 0
    /// "Forever" — kept until the transcript is deleted.
    public static let forever = -1

    public static func keepsAudio(retentionDays: Int) -> Bool {
        retentionDays != never
    }

    /// Whether a file recorded at `createdAt` has outlived the window.
    /// "Forever" never expires; a nil date is treated as expired, since an
    /// unreadable timestamp is indistinguishable from an orphan.
    public static func isExpired(
        createdAt: Date?,
        retentionDays: Int,
        now: Date = Date()
    ) -> Bool {
        guard retentionDays != forever else { return false }
        guard retentionDays != never else { return true }
        guard let createdAt else { return true }
        return now.timeIntervalSince(createdAt) > Double(retentionDays) * 24 * 60 * 60
    }
}

/// FR-1.3 low-disk guard (docs/11 G4): a recording must not fill the disk.
/// A take is refused at start, or finished early mid-take, when the volume
/// holding the recovery sidecars drops below `minimumFreeBytes`. The decision
/// logic is pure and Linux-tested; the stat itself is Darwin-only.
public enum DiskSpaceGuard {
    /// FR-1.3: stop recording below 1 GB free.
    public static let minimumFreeBytes: Int64 = 1_000_000_000
    /// Ingested chunks between free-space stats — the check is a filesystem
    /// stat, cheap but not free, and chunks arrive ~12×/second.
    public static let checkInterval = 50

    /// An unknown capacity (the stat failed) is NOT critical: refusing to
    /// record because a stat failed would fail takes on healthy disks.
    public static func isCritical(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes < minimumFreeBytes
    }

    #if canImport(Darwin)
    /// Free bytes on the volume containing `url`, by the "important usage"
    /// capacity — purgeable space counts as free, matching what the system
    /// would actually grant the recording.
    public static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }
    #endif
}

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
    /// FR-1.3: below the `DiskSpaceGuard` floor — recording refused rather
    /// than started on a disk it could fill.
    case insufficientDiskSpace
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

/// Stores and reaps the retained audio of delivered takes (FR-5.1, docs/11
/// G9). One flat directory of `<transcript-uuid>.m4a`, so a transcript's
/// recording is found by id alone and an orphaned file is obvious.
public enum AudioArchive {
    public static let fileExtension = "m4a"

    public static func fileURL(forTranscript id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(fileExtension)
    }

    /// Encodes a finished take to AAC beside its transcript, returning the
    /// path to record — nil when the audio could not be written, which must
    /// never cost the user the transcript itself.
    ///
    /// AAC at 24 kbps mono: about 3 KB per second of speech, so even years of
    /// daily dictation stay smaller than the speech model that produced it.
    @discardableResult
    public static func write(
        _ samples: [Float],
        forTranscript id: UUID,
        in directory: URL
    ) -> String? {
        guard !samples.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        let url = fileURL(forTranscript: id, in: directory)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(PCMChunk.sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            // Written in the file's own processing format; AVAudioFile handles
            // the float→AAC conversion on the way out.
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ),
                let channel = buffer.floatChannelData
            else { return nil }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for index in samples.indices {
                channel[0][index] = samples[index]
            }
            try file.write(from: buffer)
            return url.path
        } catch {
            // A failed encode leaves no half-written file behind.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Deletes one transcript's recording, if it has one.
    public static func delete(forTranscript id: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(forTranscript: id, in: directory))
    }

    /// Deletes every recording — the audio half of "Delete All History".
    public static func deleteAll(in directory: URL) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        else { return }
        for entry in entries where entry.pathExtension == fileExtension {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Applies the retention window, returning how many recordings were
    /// removed. Run at launch: the setting is a promise about what is on disk,
    /// not merely about what is written.
    @discardableResult
    public static func sweep(
        directory: URL,
        retentionDays: Int,
        now: Date = Date()
    ) -> Int {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        var removed = 0
        for entry in entries where entry.pathExtension == fileExtension {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard
                AudioRetentionPolicy.isExpired(
                    createdAt: modified, retentionDays: retentionDays, now: now
                )
            else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
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
    /// FR-1.3 (docs/11 G4): invoked at most once per take when free space
    /// drops below the `DiskSpaceGuard` floor mid-recording. The composition
    /// root wires this to "finish the take normally" — the audio captured so
    /// far is delivered, not lost.
    private var lowDiskHandler: (@Sendable () -> Void)?
    private var ingestsSinceDiskCheck = 0
    private var lowDiskTripped = false
    /// Per-chunk microphone level for the HUD waveform (FR-4.1), ~12×/second.
    private var levelHandler: (@Sendable (Float) -> Void)?

    public init() {}

    /// Installs the low-disk callback (see `lowDiskHandler`).
    public func setLowDiskHandler(_ handler: @escaping @Sendable () -> Void) {
        lowDiskHandler = handler
    }

    /// Installs the live-level callback (see `levelHandler`).
    public func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        levelHandler = handler
    }

    /// Begin capturing. The returned session's `chunks` yields converted audio
    /// as it arrives; call `finish` to stop and receive the concatenated take.
    public func start() async throws -> MicrophoneSession {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }
        // FR-1.3: refuse to start a recording the disk cannot hold.
        if DiskSpaceGuard.isCritical(
            availableBytes: DiskSpaceGuard.availableBytes(
                at: FileManager.default.temporaryDirectory
            )
        ) {
            throw CaptureError.insufficientDiskSpace
        }
        ingestsSinceDiskCheck = 0
        lowDiskTripped = false

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

        // Fire-and-forget. Sweeping the temp directory means listing it and
        // stat-ing every entry, and this runs between the hotkey press and
        // the microphone opening — exactly where work does not belong, since
        // every millisecond here is speech the user already spoke. Nothing
        // downstream waits on the result.
        Task.detached(priority: .utility) {
            RecoveryFileReaper.reapExpiredRecoveryFiles()
        }

        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(RecoveryFileReaper.recoveryFilePrefix + UUID().uuidString + ".pcmf32")
        _ = FileManager.default.createFile(atPath: recoveryURL.path, contents: Data())
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: recoveryURL)
        } catch {
            // Do not leave the just-created empty file behind.
            try? FileManager.default.removeItem(at: recoveryURL)
            throw error
        }

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
        levelHandler?(AudioLevelMeter.level(for: converted))
        let data = converted.withUnsafeBufferPointer { Data(buffer: $0) }
        try? recoveryHandle?.write(contentsOf: data)

        // FR-1.3 mid-take guard (docs/11 G4): a long (locked) take must not
        // record until the disk fills. Fires the handler once; the app
        // finishes the take through the normal stop path, so the audio
        // captured so far is transcribed and delivered.
        ingestsSinceDiskCheck += 1
        if ingestsSinceDiskCheck >= DiskSpaceGuard.checkInterval {
            ingestsSinceDiskCheck = 0
            if !lowDiskTripped,
                DiskSpaceGuard.isCritical(
                    availableBytes: DiskSpaceGuard.availableBytes(
                        at: FileManager.default.temporaryDirectory
                    )
                )
            {
                lowDiskTripped = true
                lowDiskHandler?()
            }
        }
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
