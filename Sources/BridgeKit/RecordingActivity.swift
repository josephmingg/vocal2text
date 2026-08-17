import CoreModels
import Foundation

/// What the Dynamic Island / Live Activity shows during a take
/// (docs/02 FR-i1.3, AC-i6).
///
/// Deliberately a plain value in a Linux-testable target: ActivityKit lives in
/// the widget extension, and everything it renders is decided here so the
/// wording and the elapsed-time formatting can be unit-tested.
public struct RecordingActivityState: Codable, Sendable, Hashable {
    public enum Stage: String, Codable, Sendable, Hashable {
        case recording
        case transcribing
        case cleaning
        case delivering
        case finished
        case failed
    }

    public var stage: Stage
    /// Start of the take, used for the live elapsed timer.
    public var startedAt: Date
    public var profileName: String
    /// Populated once text exists — a short lead-in, never the full transcript
    /// (a Live Activity is visible on a locked screen).
    public var preview: String?
    /// User-facing failure text when `stage == .failed`.
    public var failureReason: String?

    public init(
        stage: Stage,
        startedAt: Date,
        profileName: String,
        preview: String? = nil,
        failureReason: String? = nil
    ) {
        self.stage = stage
        self.startedAt = startedAt
        self.profileName = profileName
        self.preview = preview
        self.failureReason = failureReason
    }

    /// Longest preview shown on the Lock Screen. Truncating here rather than
    /// in the view keeps the privacy rule testable.
    public static let previewCharacterLimit = 60

    /// Trims `text` to a lock-screen-safe lead-in.
    public static func makePreview(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > previewCharacterLimit else { return trimmed }
        return String(trimmed.prefix(previewCharacterLimit)) + "…"
    }
}

/// Turns a ``RecordingActivityState`` into the strings and SF Symbol names the
/// widget renders, in all three Dynamic Island presentations.
public enum RecordingActivityPresenter {

    public static func title(for state: RecordingActivityState) -> String {
        switch state.stage {
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning up"
        case .delivering: "Delivering"
        case .finished: "Ready to paste"
        case .failed: "Dictation failed"
        }
    }

    /// The second line: the failure reason, then the preview, then the profile.
    public static func subtitle(for state: RecordingActivityState) -> String {
        if state.stage == .failed, let reason = state.failureReason, !reason.isEmpty {
            return reason
        }
        if let preview = state.preview, !preview.isEmpty {
            return preview
        }
        return state.profileName
    }

    public static func symbolName(for state: RecordingActivityState) -> String {
        switch state.stage {
        case .recording: "waveform"
        case .transcribing, .cleaning: "gearshape.2"
        case .delivering: "arrow.right.doc.on.clipboard"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// True while the take is still running — the widget only animates and
    /// only shows a live timer in that case.
    public static func isLive(_ state: RecordingActivityState) -> Bool {
        switch state.stage {
        case .recording, .transcribing, .cleaning, .delivering: true
        case .finished, .failed: false
        }
    }

    /// `m:ss` elapsed, floored at zero so a clock adjustment cannot render
    /// a negative timer.
    public static func elapsedText(for state: RecordingActivityState, at now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(state.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The compact leading/trailing pair for the Dynamic Island.
    public static func compactTrailing(
        for state: RecordingActivityState,
        at now: Date
    ) -> String {
        isLive(state) ? elapsedText(for: state, at: now) : title(for: state)
    }
}

extension RecordingActivityState {
    /// Maps the language a take resolved to onto the activity, for callers
    /// that want it in the subtitle. Kept as a helper rather than a stored
    /// field so the shared attributes type stays minimal.
    public func withPreview(_ text: String, language: Language?) -> RecordingActivityState {
        var copy = self
        let prefix = language.map { "\($0.displayName) · " } ?? ""
        copy.preview = Self.makePreview(from: text).map { prefix + $0 }
        return copy
    }
}
