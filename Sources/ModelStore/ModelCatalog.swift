import CoreModels
import Foundation

/// One downloadable file belonging to a model variant.
public struct ModelFileSpec: Codable, Sendable, Hashable {
    /// Path of the file inside the model's install directory.
    public var relativePath: String
    /// Where the file is downloaded from.
    public var url: URL
    /// Lowercase hex SHA-256 of the complete file; nil skips verification.
    public var sha256: String?
    /// Expected size in bytes.
    public var bytes: Int64

    public init(relativePath: String, url: URL, sha256: String? = nil, bytes: Int64) {
        self.relativePath = relativePath
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// A model variant the app can install (docs/04 §5). Purely data — adding a
/// model is a catalog entry, never a code change.
public struct ModelSpec: Codable, Sendable, Hashable {
    /// Stable variant identifier, e.g. "whisper-large-v3-turbo".
    public var id: String
    public var displayName: String
    /// The engine that consumes this model, e.g. "whisperkit".
    public var engine: String
    public var languages: [Language]
    /// Expected total on-disk size; drives the docs/09 truncation guard when
    /// `files` is empty.
    public var approximateBytes: Int64
    /// Individual files to download; empty when the engine manages its own
    /// download and ModelStore only tracks the on-disk footprint.
    public var files: [ModelFileSpec]

    public init(
        id: String,
        displayName: String,
        engine: String,
        languages: [Language],
        approximateBytes: Int64,
        files: [ModelFileSpec] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.languages = languages
        self.approximateBytes = approximateBytes
        self.files = files
    }
}

/// The built-in model catalog (docs/04 §1). Data-driven: new models are
/// catalog entries, and remote catalogs can decode the same `ModelSpec` JSON.
public enum ModelCatalog {
    public static let builtIn: [ModelSpec] = [
        /// Primary EN+ZH model. WhisperKit manages its own download and cache
        /// layout, so `files` is empty; ModelStore tracks only the installed
        /// footprint under `<root>/whisperkit/whisper-large-v3-turbo`.
        ModelSpec(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: "whisperkit",
            languages: [.english, .chinese],
            approximateBytes: 656_408_576, // ≈626 MB
            files: []
        ),
        /// Fallback for low-RAM machines; also WhisperKit-managed (`files` empty).
        ModelSpec(
            id: "whisper-small",
            displayName: "Whisper Small",
            engine: "whisperkit",
            languages: [.english, .chinese],
            approximateBytes: 506_462_208, // ≈483 MB
            files: []
        ),
        /// Burmese (v1.1). Whisper is unusable for Burmese — 80–100% WER with
        /// hallucination loops — so Burmese gets its own engine rather than
        /// another Whisper variant (docs/04 Appendix A). Benchmarked on
        /// FLEURS my_mm: 10.78% CER (1B) / 15.19% (300M) — docs/11 G13.
        ///
        /// Served by `SherpaOnnxEngine` (ASREngineSherpaOnnx), which manages
        /// its own archive download/extraction into the same
        /// `<root>/sherpa-onnx/<id>/` directory this catalog describes, so
        /// `files` stays empty like the WhisperKit entries and ModelStore
        /// tracks the installed footprint.
        ModelSpec(
            id: "omni-asr-ctc-1b-int8",
            displayName: "Omnilingual ASR CTC 1B (int8)",
            engine: "sherpa-onnx",
            languages: [.burmese],
            approximateBytes: 1_181_116_006, // ≈1.1 GB — Mac tier
            files: []
        ),
        ModelSpec(
            id: "omni-asr-ctc-300m-int8",
            displayName: "Omnilingual ASR CTC 300M (int8)",
            engine: "sherpa-onnx",
            languages: [.burmese],
            approximateBytes: 364_904_448, // ≈348 MB — iPhone tier
            files: []
        ),
    ]

    /// Catalog entries that can serve `language`.
    public static func models(for language: Language) -> [ModelSpec] {
        builtIn.filter { $0.languages.contains(language) }
    }
}
