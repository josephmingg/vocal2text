import CoreModels
import Foundation

/// Versioning for everything written into the App Group container.
///
/// The keyboard and the app are separate binaries that iOS may run at
/// different versions (an extension can stay loaded across an app update), so
/// every payload is version-stamped and readers refuse futures loudly instead
/// of silently mis-decoding.
public enum BridgeSchema {
    /// Bump when a payload changes shape in a way older readers cannot handle.
    public static let current = 1
    /// Oldest version this build still understands.
    public static let minimumSupported = 1
}

/// Named files inside the bridge directory. One writer per slot keeps the
/// protocol single-direction and race-free: the keyboard owns `request`, the
/// app owns `status` and `reply`.
public enum BridgeSlot: String, Sendable, CaseIterable, Hashable {
    /// App → keyboard: is a session armed, what is it doing right now.
    case status
    /// Keyboard → app: the mic key was pressed / released / cancelled.
    case request
    /// App → keyboard: the transcript for a completed request.
    case reply

    public var filename: String { "\(rawValue).json" }
}

/// What the keyboard is asking the container app to do.
public enum BridgeCommand: String, Codable, Sendable, Hashable {
    case startRecording
    case stopRecording
    case cancelRecording
}

/// A keyboard → app message. `id` correlates the eventual ``BridgeReply``, so
/// a stale reply from an earlier press can never be inserted into the wrong
/// text field.
public struct BridgeRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var command: BridgeCommand
    public var issuedAt: Date
    /// Profile the keyboard's picker key selected; nil means "use the armed
    /// session's profile".
    public var requestedProfileName: String?
    /// Best-effort identity of the app the keyboard is typing into. iOS
    /// exposes no public API for this (docs/02 FR-i2.2), so this is nil today
    /// and exists so a future host hint routes profiles without a wire change.
    public var hostAppBundleID: String?

    public init(
        id: UUID = UUID(),
        command: BridgeCommand,
        issuedAt: Date,
        requestedProfileName: String? = nil,
        hostAppBundleID: String? = nil
    ) {
        self.id = id
        self.command = command
        self.issuedAt = issuedAt
        self.requestedProfileName = requestedProfileName
        self.hostAppBundleID = hostAppBundleID
    }
}

/// An app → keyboard message carrying the outcome of one request.
public struct BridgeReply: Codable, Sendable, Hashable {
    public enum Outcome: Codable, Sendable, Hashable {
        /// Text ready to insert at the cursor.
        case text(String)
        /// The take was discarded (Escape, accidental tap, expiry).
        case cancelled
        /// Something failed; `reason` is already user-facing.
        case failed(reason: String)
    }

    public var requestID: UUID
    public var producedAt: Date
    public var outcome: Outcome
    public var language: Language?
    public var profileName: String

    public init(
        requestID: UUID,
        producedAt: Date,
        outcome: Outcome,
        language: Language? = nil,
        profileName: String
    ) {
        self.requestID = requestID
        self.producedAt = producedAt
        self.outcome = outcome
        self.language = language
        self.profileName = profileName
    }

    /// The insertable string, or nil for cancelled/failed outcomes.
    public var insertableText: String? {
        if case .text(let text) = outcome { return text }
        return nil
    }
}

/// The app's live state, republished on every phase change so the keyboard can
/// render without asking. Small on purpose: the keyboard polls this on every
/// appearance and every Darwin ping.
public struct BridgeStatus: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable, Hashable {
        case idle
        case recording
        case transcribing
        case delivering
    }

    public var updatedAt: Date
    /// nil when nothing is armed — the keyboard's mic key then deep-links.
    public var session: CaptureSessionState?
    public var phase: Phase
    /// Request the app is currently working on, if any.
    public var activeRequestID: UUID?
    /// Profiles the keyboard's picker key offers (names only — the keyboard
    /// never loads the profile store).
    public var availableProfileNames: [String]
    /// Voice notes waiting in the share-sheet import queue, surfaced so the
    /// keyboard can hint that the app has work pending.
    public var pendingImportCount: Int
    /// FR-i2.2: insert the transcript straight at the cursor instead of
    /// showing the ✓/✗ preview row. The app owns this setting and publishes
    /// it, so the keyboard needs no settings store of its own. Defaults to
    /// off — typing unreviewed text into someone's chat is the costly mistake.
    public var autoInsert: Bool

    public init(
        updatedAt: Date,
        session: CaptureSessionState? = nil,
        phase: Phase = .idle,
        activeRequestID: UUID? = nil,
        availableProfileNames: [String] = [],
        pendingImportCount: Int = 0,
        autoInsert: Bool = false
    ) {
        self.updatedAt = updatedAt
        self.session = session
        self.phase = phase
        self.activeRequestID = activeRequestID
        self.availableProfileNames = availableProfileNames
        self.pendingImportCount = pendingImportCount
        self.autoInsert = autoInsert
    }

    /// A status the keyboard can act on: armed, and the app is not already
    /// busy with another take.
    public func acceptsNewRecording(at now: Date) -> Bool {
        guard let session, session.isArmed(at: now) else { return false }
        return phase == .idle
    }
}

/// The version stamp wrapped around every payload on disk.
public struct BridgeEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var payload: Payload

    public init(schemaVersion: Int = BridgeSchema.current, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }
}

/// Failures a bridge reader can hit. Every case is actionable by the caller:
/// the keyboard shows "open Vocal to finish updating" for `unsupportedSchema`
/// and stays silent for `empty`.
public enum BridgeError: Error, Sendable, Equatable {
    /// The slot exists but the writer speaks a newer protocol.
    case unsupportedSchema(found: Int, supported: ClosedRange<Int>)
    /// The App Group container is unreachable — almost always a missing
    /// entitlement or Full Access turned off.
    case containerUnavailable
    case decodeFailed(String)
    case encodeFailed(String)
    case writeFailed(String)
}
