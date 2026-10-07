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
    /// Abort and delete the recoverable copy too — for takes "Recover" must
    /// never offer back. nil: the platform keeps no copy, `cancel` suffices.
    public var discard: (@Sendable () async -> Void)?

    public init(
        chunks: AsyncStream<PCMChunk>,
        finish: @escaping @Sendable () async -> PCMChunk,
        cancel: @escaping @Sendable () async -> Void,
        discard: (@Sendable () async -> Void)? = nil
    ) {
        self.chunks = chunks
        self.finish = finish
        self.cancel = cancel
        self.discard = discard
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
    /// Language the take resolved to. A delivery port that cannot see this
    /// cannot label or route by it — the iOS keyboard bridge reports it back
    /// to the extension, and language-aware insertion rules need it.
    public var language: Language

    public init(
        pressTimeAppBundleID: String?,
        isLockMode: Bool,
        formatting: FormattingOptions,
        language: Language = .english
    ) {
        self.pressTimeAppBundleID = pressTimeAppBundleID
        self.isLockMode = isLockMode
        self.formatting = formatting
        self.language = language
    }
}

public enum DeliveryOutcome: Sendable, Hashable {
    case inserted(method: InsertionMethod, appBundleID: String?)
    case copiedToClipboard(reason: ClipboardFallbackReason)
    /// Secure input active: nothing inserted, nothing persisted (FR-3.2).
    case blockedSecureField(culpritApp: String?)

    public enum InsertionMethod: String, Sendable, Codable {
        /// Tier 0 (docs/15 step 17): Accessibility-API insertion, verified by
        /// reading the focused element back — no clipboard, no sleeps.
        case accessibility
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
    /// When true, stage 3 runs even on takes the skip heuristic calls clean.
    /// Misheard words ("rose your ideas" for "roast your ideas") look
    /// perfectly tidy to any deterministic check — only the model, reading
    /// context, can catch them — so a user who wants those repaired has to
    /// pay the round-trip on every take.
    var cleanupRunsOnCleanTakes: Bool { get async }
    /// The one-click output style (docs/17 §5); profiles that ignore the
    /// global style are unaffected.
    var dictationStyle: DictationStyle { get async }
    /// Opt-in (docs/17 G3.2): cleanup may read a bounded slice of the text
    /// around the cursor for casing, name spelling and tone. Never persisted.
    var cleanupUsesSurroundingText: Bool { get async }
    /// Opt-in (docs/17 G4.4): a dictation that starts with "Vocal, …" or
    /// "Hey Vocal …" becomes a command instead of being typed.
    var wakeWordCommandsEnabled: Bool { get async }
    func enabledDictionaryEntries() async -> [DictionaryEntry]
    /// Counts the dictionary entries a delivered take applied, one ID per
    /// replacement (docs/17 F10: the recognizer's bias list leads with the
    /// most-used words). Called after delivery, off the latency path.
    func recordDictionaryUse(_ entryIDs: [UUID], at date: Date) async
}

extension SessionConfiguring {
    /// Default: keep the latency-saving skip (docs/15 step 20).
    public var cleanupRunsOnCleanTakes: Bool { false }
    public var dictationStyle: DictationStyle { .standard }
    /// Default OFF — the owner's choice: reading surrounding text is opt-in.
    public var cleanupUsesSurroundingText: Bool { false }
    public var wakeWordCommandsEnabled: Bool { false }
    /// Default: nothing is counted.
    public func recordDictionaryUse(_ entryIDs: [UUID], at date: Date) async {}
}

/// What a press is for (docs/17 G4): ordinary dictation, or a spoken
/// command from the command key.
public enum TakeKind: Sendable, Hashable {
    case dictation
    case command
}

/// A transcribed command, handed to the platform instead of being typed.
public struct VoiceCommand: Sendable, Hashable {
    /// The spoken instruction, wake word removed, dictionary fixes applied.
    public var instruction: String
    /// The selection captured when the key went down; nil when nothing was
    /// selected or the platform could not read it.
    public var selectedText: String?
    public var language: Language
    /// The app the command was spoken in — where the result belongs.
    public var pressTimeBundleID: String?
    /// True when the command came from the wake word rather than the key.
    public var viaWakeWord: Bool

    public init(
        instruction: String,
        selectedText: String?,
        language: Language,
        pressTimeBundleID: String?,
        viaWakeWord: Bool
    ) {
        self.instruction = instruction
        self.selectedText = selectedText
        self.language = language
        self.pressTimeBundleID = pressTimeBundleID
        self.viaWakeWord = viaWakeWord
    }
}
