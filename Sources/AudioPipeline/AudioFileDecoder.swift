import ASRKit
import Foundation

#if canImport(AVFoundation)
import AVFoundation

public enum AudioFileDecodeError: Error, Sendable, Equatable {
    case unreadable(String)
    case formatUnavailable
    case conversionFailed(String)
    case cancelled
}

/// Decodes any container AVFoundation can read — m4a voice notes, WhatsApp
/// opus, wav, mp3, the audio track of a video — into the pipeline's 16 kHz
/// mono Float32 lingua franca (docs/02 FR-i3.5, FR-i2.3).
///
/// Reads in frame-bounded passes rather than slurping the file, so a long
/// import stays inside the memory budget and can report progress and be
/// cancelled part-way (`onProgress` returning false stops the decode).
public enum AudioFileDecoder {

    /// Frames pulled per read. ~1.4 s at 48 kHz — small enough to keep peak
    /// memory flat, large enough that the per-call overhead disappears.
    private static let framesPerRead: AVAudioFrameCount = 65_536

    /// Decoded audio plus what it came from.
    public struct Decoded: Sendable {
        public var audio: PCMChunk
        /// Duration of the source file, which may exceed `audio` when the
        /// decode was capped by `maximumSeconds`.
        public var sourceDurationSeconds: Double
        public var wasTruncated: Bool
    }

    /// - Parameters:
    ///   - url: file to read.
    ///   - maximumSeconds: hard cap; a pathological file cannot exhaust memory.
    ///   - onProgress: called with 0…1 as decoding advances. Return false to
    ///     cancel — the decoder then throws `.cancelled`.
    public static func decode(
        url: URL,
        maximumSeconds: Double = 4 * 60 * 60,
        onProgress: ((Double) -> Bool)? = nil
    ) throws -> Decoded {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileDecodeError.unreadable(String(describing: error))
        }

        let inputFormat = file.processingFormat
        guard
            inputFormat.sampleRate > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(PCMChunk.sampleRate),
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw AudioFileDecodeError.formatUnavailable
        }

        let totalFrames = file.length
        let sourceDuration = Double(totalFrames) / inputFormat.sampleRate
        let maximumOutputSamples = Int(maximumSeconds * Double(PCMChunk.sampleRate))
        let ratio = target.sampleRate / inputFormat.sampleRate

        var samples: [Float] = []
        samples.reserveCapacity(
            min(maximumOutputSamples, Int(sourceDuration * Double(PCMChunk.sampleRate)) + 1)
        )
        var truncated = false

        while true {
            guard
                let inBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: framesPerRead
                )
            else { throw AudioFileDecodeError.formatUnavailable }

            do {
                try file.read(into: inBuffer, frameCount: framesPerRead)
            } catch {
                throw AudioFileDecodeError.unreadable(String(describing: error))
            }
            if inBuffer.frameLength == 0 { break }

            let capacity = AVAudioFrameCount((Double(inBuffer.frameLength) * ratio).rounded(.up))
                + 1_024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { throw AudioFileDecodeError.formatUnavailable }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                throw AudioFileDecodeError.conversionFailed(
                    conversionError.map(String.init(describing:)) ?? "unknown"
                )
            }
            if outBuffer.frameLength > 0, let channels = outBuffer.floatChannelData {
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channels[0], count: Int(outBuffer.frameLength)
                    )
                )
            }

            if samples.count >= maximumOutputSamples {
                samples.removeLast(samples.count - maximumOutputSamples)
                truncated = true
                break
            }

            if let onProgress {
                let fraction =
                    totalFrames > 0
                    ? min(1, Double(file.framePosition) / Double(totalFrames))
                    : 0
                guard onProgress(fraction) else { throw AudioFileDecodeError.cancelled }
            }
        }

        if let onProgress { _ = onProgress(1) }
        return Decoded(
            audio: PCMChunk(samples: samples),
            sourceDurationSeconds: sourceDuration,
            wasTruncated: truncated
        )
    }
}

#else

/// Non-Apple platforms have no AVFoundation decoder; imports are an iOS/macOS
/// feature and SessionKit tests use synthetic PCM.
public enum AudioFileDecodeError: Error, Sendable, Equatable {
    case unsupportedPlatform
}

#endif
