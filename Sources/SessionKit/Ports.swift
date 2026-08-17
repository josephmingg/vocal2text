import ASRKit
import CoreModels
import Foundation

/// Platform seam for capturing microphone audio. macOS/iOS implement this over
/// AVAudioEngine; tests use a scripted fake. The capture implementation is
/// responsible for crash-safe temp persistence of PCM during recording (FR-11.3).
public protocol AudioCapturing: Sendable {
    /// Begin capturing. Returns a stream of 16 kHz mono chunks plus a handle
    /// used to stop/cancel. Pre-arming (permission checks, engine start) happens
    /// inside; the first chunk should arrive within ~100 ms of the call.
    func start() async throws -> CaptureSession
}

public struct CaptureSession: Sendable {
    public var chunks: AsyncStream<PCMChunk>
    /// Stop capturing and return the complete utterance audio.
    public var finish: @Sendable () async -> PCMChunk
    /// Abort; audio may still be recoverable per FR-1.6.
    public var cancel: @Sendable () async -> Void

    public init(
        chunks: AsyncStream<PCMChunk>,
        finish: @escaping @Sendable () async -> PCMChunk,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.chunks = chunks
        self.finish = finish
        self.cancel = cancel
    }
}

/// Platform seam for delivering text (docs/03 §8.3). macOS = insertion ladder;
/// iOS = keyboard/clipboard; tests record calls.
public protocol TextDelivering: Sendable {
    /// Deliver `text` to the current target. Returns how it was delivered so the
    /// session can record it and the HUD can react.
    func deliver(_ text: String, context: DeliveryContext) async -> DeliveryOutcome
}

public struct DeliveryContext: Sendable, Hashable {
    /// App frontmost at hotkey press (profile anchor, FR-3.6).
    public var pressTimeAppBundleID: String?
    /// Recording mode — lock mode falls back to clipboard on focus change (FR-3.6).
    public var isLockMode: Bool
    public var formatting: FormattingOptions

    public init(pressTimeAppBundleID: String?, isLockMode: Bool, formatting: FormattingOptions) {
        self.pressTimeAppBundleID = pressTimeAppBundleID
        self.isLockMode = isLockMode
        self.formatting = formatting
    }
}

public enum DeliveryOutcome: Sendable, Hashable {
    case inserted(method: InsertionMethod, appBundleID: String?)
    case copiedToClipboard(reason: ClipboardFallbackReason)
    /// Secure input active: nothing inserted, nothing persisted (FR-3.2).
    case blockedSecureField(culpritApp: String?)

    public enum InsertionMethod: String, Sendable, Codable {
        case paste
        case unicodeTyping
    }

    public enum ClipboardFallbackReason: String, Sendable, Codable {
        case noFocusedField
        case lockModeFocusChange
        case insertionUnavailable
        case userSetting
    }
}

/// Persistence seam so SessionKit stays Linux-testable; PersistenceKit (GRDB)
/// implements it on Apple platforms, tests use in-memory fakes.
public protocol TranscriptStoring: Sendable {
    func save(_ record: TranscriptRecord) async throws
}

/// Read seam for the pieces of configuration a session needs at press time.
public protocol SessionConfiguring: Sendable {
    /// The global cleanup master switch (ships OFF, docs/05 §0).
    var cleanupMasterSwitch: Bool { get async }
    var globalLanguageMode: LanguageMode { get async }
    var globalStylePrompt: String { get async }
    var cleanupTimeout: Duration { get async }
    func enabledDictionaryEntries() async -> [DictionaryEntry]
}
