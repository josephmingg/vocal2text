import CoreModels
import Foundation

/// Availability of an engine for a given language.
public enum EngineAvailability: Sendable, Hashable {
    case ready
    case needsDownload(bytes: Int64)
    case unsupported(reason: String)
}

/// A partial (volatile) or final transcription update during streaming.
public struct TranscriptionUpdate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// May be revised; HUD preview only. Committed text always comes from
        /// the full-utterance final pass (docs/09 chunk-stitching lesson).
        case partial
        case final
    }

    public var kind: Kind
    public var text: String
    public var detectedLanguage: Language?

    public init(kind: Kind, text: String, detectedLanguage: Language? = nil) {
        self.kind = kind
        self.text = text
        self.detectedLanguage = detectedLanguage
    }
}

/// The finished product of transcribing one utterance or file chunk.
public struct TranscriptionResult: Sendable, Hashable {
    public var text: String
    public var detectedLanguage: Language
    /// Word/segment timestamps in seconds from utterance start, when available.
    public var segments: [TimedSegment]

    public struct TimedSegment: Sendable, Hashable, Codable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public init(text: String, detectedLanguage: Language, segments: [TimedSegment] = []) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.segments = segments
    }
}

public enum TranscriptionError: Error, Sendable, Equatable {
    case modelNotInstalled
    case engineUnavailable(String)
    case audioUnreadable(String)
    case cancelled
}

/// 16 kHz mono Float32 PCM — the pipeline's audio lingua franca.
public struct PCMChunk: Sendable {
    public var samples: [Float]
    public static let sampleRate = 16_000

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var durationSeconds: Double {
        Double(samples.count) / Double(Self.sampleRate)
    }
}

/// The pluggable ASR seam (docs/03 §8.1). Adapters: WhisperKit (primary),
/// Apple SpeechAnalyzer/DictationTranscriber (fast path), fakes for tests.
public protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var displayName: String { get }

    func availability(for language: Language) async -> EngineAvailability

    /// Load models into memory; idempotent; concurrent calls coalesce.
    func prepare(languageMode: LanguageMode) async throws

    /// Transcribe a complete utterance (transcribe-on-release core flow).
    /// `dictionaryTerms` may be used for recognizer-level biasing where the
    /// engine supports it; stage 2 remains the correctness backstop.
    func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult

    /// Streaming partials for the HUD preview. Implementations may yield only
    /// a trailing `.final` update if they do not support partials.
    func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error>

    /// Release model memory (unload-after-idle setting).
    func unload() async
}
