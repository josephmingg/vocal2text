import Foundation

/// Minimal RIFF/WAVE reader for benchmark fixtures: mono or multichannel
/// (channel 0 taken), 16-bit PCM or 32-bit float, any sample rate the fixture
/// pipeline produced (the docs prescribe 16 kHz mono, matching PCMChunk).
/// Deliberately dependency-free so it parses on Linux in tests.
public enum WavFile {

    public enum ReadError: Error, Equatable {
        case notRIFF
        case missingChunk(String)
        case unsupportedFormat(code: Int, bitsPerSample: Int)
    }

    public struct Contents: Equatable {
        public var samples: [Float]
        public var sampleRate: Int

        public init(samples: [Float], sampleRate: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
        }

        public var durationSeconds: Double {
            sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        }
    }

    public static func read(_ url: URL) throws -> Contents {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Contents {
        guard data.count >= 12,
            data[data.startIndex..<data.startIndex + 4].elementsEqual("RIFF".utf8),
            data[data.startIndex + 8..<data.startIndex + 12].elementsEqual("WAVE".utf8)
        else {
            throw ReadError.notRIFF
        }

        var offset = data.startIndex + 12
        var formatCode: Int?
        var channels = 1
        var sampleRate = 0
        var bitsPerSample = 0
        var payload: Data?

        // Walk the chunk list; chunks are word-aligned (odd sizes padded).
        while offset + 8 <= data.endIndex {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(readUInt32(data, at: offset + 4))
            let body = offset + 8
            guard body + size <= data.endIndex else { break }
            switch id {
            case "fmt ":
                guard size >= 16 else { throw ReadError.missingChunk("fmt ") }
                formatCode = Int(readUInt16(data, at: body))
                channels = max(1, Int(readUInt16(data, at: body + 2)))
                sampleRate = Int(readUInt32(data, at: body + 4))
                bitsPerSample = Int(readUInt16(data, at: body + 14))
            case "data":
                payload = data.subdata(in: body..<body + size)
            default:
                break
            }
            offset = body + size + (size % 2)
        }

        guard let formatCode else { throw ReadError.missingChunk("fmt ") }
        guard let payload else { throw ReadError.missingChunk("data") }

        let samples: [Float]
        switch (formatCode, bitsPerSample) {
        case (1, 16):
            samples = pcm16Samples(payload, channels: channels)
        case (3, 32):
            samples = float32Samples(payload, channels: channels)
        default:
            throw ReadError.unsupportedFormat(code: formatCode, bitsPerSample: bitsPerSample)
        }
        return Contents(samples: samples, sampleRate: sampleRate)
    }

    // MARK: - Sample extraction (channel 0 only, like MicrophoneCapture)

    private static func pcm16Samples(_ data: Data, channels: Int) -> [Float] {
        let frameBytes = 2 * channels
        let frames = data.count / frameBytes
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            let base = data.startIndex + frame * frameBytes
            let raw = Int16(bitPattern: readUInt16(data, at: base))
            samples.append(max(-1.0, Float(raw) / 32767.0))
        }
        return samples
    }

    private static func float32Samples(_ data: Data, channels: Int) -> [Float] {
        let frameBytes = 4 * channels
        let frames = data.count / frameBytes
        var samples = [Float]()
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            let base = data.startIndex + frame * frameBytes
            samples.append(Float(bitPattern: readUInt32(data, at: base)))
        }
        return samples
    }

    // MARK: - Little-endian reads (index-safe via the caller's bounds checks)

    private static func readUInt16(_ data: Data, at index: Data.Index) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }
}
