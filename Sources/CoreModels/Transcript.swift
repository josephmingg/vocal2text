import Foundation

/// Where a transcript came from.
public enum TranscriptSource: String, Codable, Sendable {
    case dictation
    case fileImport
    case recovered
}

/// Outcome of the cleanup stage for one dictation (history metadata, FR-5.1).
public enum CleanupOutcome: Codable, Sendable, Hashable {
    case skipped(reason: SkipReason)
    case applied(provider: CleanupProviderID, model: String)
    case failed(provider: CleanupProviderID, reason: String)
    case rejectedByValidator(provider: CleanupProviderID, rule: String)

    public enum SkipReason: String, Codable, Sendable {
        case masterSwitchOff
        case profileDisabled
        case providerUnavailable
        /// The detected language opts out of cleanup by default
        /// (`Language.allowsCleanupByDefault`) and no profile pinned it.
        case languageOptOut
        /// The deterministic skip heuristic found nothing for the model to do
        /// — no fillers, no correction cues, punctuation already sane
        /// (docs/15 step 20).
        case notNeeded
    }
}

/// Per-stage timings for the debug overlay and latency budgets (FR-11.4).
public struct TimingBreakdown: Codable, Sendable, Hashable {
    /// Press → microphone open (docs/15 step 47): the milliseconds of speech
    /// the user loses at the start of every take. 0 on rows written before
    /// the mark existed, and for recovered takes (no press).
    public var armSeconds: Double
    public var captureSeconds: Double
    public var transcriptionSeconds: Double
    public var dictionarySeconds: Double
    public var cleanupSeconds: Double
    public var deliverySeconds: Double

    /// Release → text visible: the wait the user actually feels (docs/15
    /// step 47's second mark; the VAD gate is counted inside transcription).
    public var totalPostReleaseSeconds: Double {
        transcriptionSeconds + dictionarySeconds + cleanupSeconds + deliverySeconds
    }

    public init(
        armSeconds: Double = 0,
        captureSeconds: Double = 0,
        transcriptionSeconds: Double = 0,
        dictionarySeconds: Double = 0,
        cleanupSeconds: Double = 0,
        deliverySeconds: Double = 0
    ) {
        self.armSeconds = armSeconds
        self.captureSeconds = captureSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.dictionarySeconds = dictionarySeconds
        self.cleanupSeconds = cleanupSeconds
        self.deliverySeconds = deliverySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case armSeconds, captureSeconds, transcriptionSeconds
        case dictionarySeconds, cleanupSeconds, deliverySeconds
    }

    /// Lenient by design: rows written before a mark existed decode with that
    /// mark at 0 — a new field must never make old history unreadable (the
    /// list query already skips undecodable rows, which would silently hide
    /// them).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? 0
        }
        armSeconds = try value(.armSeconds)
        captureSeconds = try value(.captureSeconds)
        transcriptionSeconds = try value(.transcriptionSeconds)
        dictionarySeconds = try value(.dictionarySeconds)
        cleanupSeconds = try value(.cleanupSeconds)
        deliverySeconds = try value(.deliverySeconds)
    }
}

/// One completed dictation or import. The raw ASR text is never lost
/// (product principle #2); `deliveredText` is what actually landed.
public struct TranscriptRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var source: TranscriptSource
    public var language: Language
    /// Raw ASR output before any transformation.
    public var rawText: String
    /// Text after stages 1–4 as delivered (or as would have been delivered).
    public var deliveredText: String
    public var durationSeconds: Double
    /// Bundle ID + localized name of the delivery target (macOS) or host app (iOS).
    public var targetAppBundleID: String?
    public var targetAppName: String?
    /// Profile name + route type only — never a hostname (FR-8.4).
    public var profileName: String
    public var routeKind: RouteKind
    public var cleanup: CleanupOutcome
    public var timings: TimingBreakdown
    /// Relative path of stored audio inside the app's audio directory, if retained.
    public var audioPath: String?
    /// Cancelled takes are recoverable for 24 h (FR-1.6).
    public var isCancelled: Bool
    /// Import source filename (FR-6.3).
    public var importedFilename: String?

    public enum RouteKind: String, Codable, Sendable {
        case app
        case website
        case defaultRoute
        case manualPin
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        source: TranscriptSource,
        language: Language,
        rawText: String,
        deliveredText: String,
        durationSeconds: Double,
        targetAppBundleID: String? = nil,
        targetAppName: String? = nil,
        profileName: String,
        routeKind: RouteKind,
        cleanup: CleanupOutcome,
        timings: TimingBreakdown = .init(),
        audioPath: String? = nil,
        isCancelled: Bool = false,
        importedFilename: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.language = language
        self.rawText = rawText
        self.deliveredText = deliveredText
        self.durationSeconds = durationSeconds
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.profileName = profileName
        self.routeKind = routeKind
        self.cleanup = cleanup
        self.timings = timings
        self.audioPath = audioPath
        self.isCancelled = isCancelled
        self.importedFilename = importedFilename
    }
}
