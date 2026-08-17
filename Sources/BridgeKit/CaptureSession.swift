import Foundation

/// How long a capture session stays armed before it expires on its own
/// (docs/02 §3.1 — auto-expiry 5/15/60 min).
///
/// The window is short by default *on purpose*: an armed session holds a live
/// audio session so iOS keeps the app resident, which means the orange mic
/// indicator stays lit and battery is spent for the whole window. See
/// ``CaptureWindow/residencyDisclosure``.
public enum CaptureWindow: String, Codable, Sendable, CaseIterable, Hashable {
    case fiveMinutes
    case fifteenMinutes
    case sixtyMinutes

    /// The default an unconfigured install arms with — the shortest window,
    /// because it is the cheapest one to leave running by accident.
    public static let `default` = CaptureWindow.fiveMinutes

    public var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .sixtyMinutes: 60 * 60
        }
    }

    public var displayName: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .sixtyMinutes: "1 hour"
        }
    }

    /// One line of plain truth shown next to the arming control. Not marketing
    /// copy — docs/02 §3.1 requires the trade to be stated where it is made.
    public var residencyDisclosure: String {
        "Vocal keeps the microphone session open for \(displayName) so the keyboard can "
            + "reach it. The orange recording dot stays lit and battery is used the whole time."
    }
}

/// An armed capture session: the window during which the keyboard's mic key
/// reaches a live container app instead of bouncing the user into it.
public struct CaptureSessionState: Codable, Sendable, Hashable {
    public var armedAt: Date
    public var expiresAt: Date
    public var window: CaptureWindow
    /// Profile the session dictates under until the keyboard picks another
    /// (docs/02 FR-i2.2 — no host-app routing exists on iOS).
    public var profileName: String

    public init(armedAt: Date, expiresAt: Date, window: CaptureWindow, profileName: String) {
        self.armedAt = armedAt
        self.expiresAt = expiresAt
        self.window = window
        self.profileName = profileName
    }

    /// Arms a fresh session of `window` length starting at `now`.
    public static func armed(
        window: CaptureWindow,
        profileName: String,
        now: Date
    ) -> CaptureSessionState {
        CaptureSessionState(
            armedAt: now,
            expiresAt: now.addingTimeInterval(window.duration),
            window: window,
            profileName: profileName
        )
    }

    /// Expiry is exclusive: a session whose `expiresAt` equals `now` is over.
    /// The keyboard and the app both evaluate this from the same clock source
    /// (wall clock), so a single definition keeps them from disagreeing.
    public func isArmed(at now: Date) -> Bool {
        now < expiresAt
    }

    /// Seconds left, floored at zero.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    /// Pushes expiry back to a full window from `now` — what a successful
    /// dictation does, so an actively used session does not die mid-sentence.
    public func extended(to now: Date) -> CaptureSessionState {
        var copy = self
        copy.expiresAt = now.addingTimeInterval(window.duration)
        return copy
    }

    /// Re-targets the session at another profile, keeping its clock.
    public func retargeted(toProfileNamed name: String) -> CaptureSessionState {
        var copy = self
        copy.profileName = name
        return copy
    }

    /// Ends the session now, keeping its window and profile.
    ///
    /// Disarming expires the session rather than forgetting it, so the
    /// keyboard's "open Vocal to re-arm" link can offer the window and profile
    /// the user actually chose instead of silently downgrading them to the
    /// 5-minute default. `isArmed(at:)` remains the single source of truth for
    /// whether it is live.
    public func expired(at now: Date) -> CaptureSessionState {
        var copy = self
        copy.expiresAt = min(expiresAt, now)
        return copy
    }
}
