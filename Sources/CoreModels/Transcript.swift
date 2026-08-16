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
    }
}

/// Per-stage timings for the debug overlay and latency budgets (FR-11.4).
public struct TimingBreakdown: Codable, Sendable, Hashable {
    public var captureSeconds: Double
    public var transcriptionSeconds: Double
    public var dictionarySeconds: Double
    public var cleanupSeconds: Double
    public var deliverySeconds: Double

    public var totalPostReleaseSeconds: Double {
        transcriptionSeconds + dictionarySeconds + cleanupSeconds + deliverySeconds
    }

    public init(
        captureSeconds: Double = 0,
        transcriptionSeconds: Double = 0,
        dictionarySeconds: Double = 0,
        cleanupSeconds: Double = 0,
        deliverySeconds: Double = 0
    ) {
        self.captureSeconds = captureSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.dictionarySeconds = dictionarySeconds
        self.cleanupSeconds = cleanupSeconds
        self.deliverySeconds = deliverySeconds
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
