import Foundation

/// What the keyboard's mic key should do right now.
public enum MicKeyAction: Sendable, Equatable {
    /// A session is armed and the app is idle — ask it to start recording.
    case startRecording
    /// The app is recording for us — ask it to stop and transcribe.
    case stopRecording(requestID: UUID)
    /// Nothing is armed. Bounce to the app once to arm a session; iOS offers
    /// no way back, which is why arming is worth the trip (docs/02 §3.1).
    case openApp(URL)
    /// The app is mid-pipeline for this or another take; the key waits.
    case busy(message: String)
    /// The bridge itself is unusable — Full Access off, or no App Group.
    case unavailable(message: String)
}

/// Every decision the keyboard makes, as pure functions.
///
/// The keyboard extension has a hard memory ceiling and no room for a test
/// harness, so its logic lives here where Linux CI runs it.
public enum KeyboardBridgePolicy {

    /// A status file older than this is treated as stale: the app was killed
    /// without disarming, so its "armed" claim can no longer be trusted.
    /// Comfortably longer than the app's status heartbeat.
    public static let statusFreshnessWindow: TimeInterval = 90

    /// Replies older than this are dropped rather than inserted — a transcript
    /// from a previous host app must never land in the current one.
    public static let replyFreshnessWindow: TimeInterval = 120

    /// Copy shown when the keyboard has no App Group access at all.
    public static let fullAccessMessage =
        "Turn on Full Access for the Vocal keyboard in Settings → General → Keyboard. "
        + "Vocal makes no network calls — Full Access is only how iOS lets the keyboard "
        + "reach the app on this device."

    /// Decides the mic key's behaviour from what the app last published.
    ///
    /// - Parameters:
    ///   - status: the app's last published status, nil when never written.
    ///   - hasFullAccess: `UIInputViewController.hasFullAccess`.
    ///   - containerReachable: whether the App Group container resolved.
    ///   - now: wall clock, injected for tests.
    public static func micKeyAction(
        status: BridgeStatus?,
        hasFullAccess: Bool,
        containerReachable: Bool,
        now: Date
    ) -> MicKeyAction {
        guard hasFullAccess else { return .unavailable(message: fullAccessMessage) }
        guard containerReachable else {
            return .unavailable(
                message: "Vocal's shared storage is unavailable. Reopen Vocal once to repair it."
            )
        }

        guard let status, isFresh(status, at: now) else {
            return .openApp(VocalURL.arm(window: .default, profileName: nil).url)
        }
        guard let session = status.session, session.isArmed(at: now) else {
            // Re-arm on the terms the user last chose. The app expires a
            // session rather than forgetting it, so a 60-minute "Email"
            // session comes back as 60 minutes of "Email".
            let previous = status.session
            return .openApp(
                VocalURL.arm(
                    window: previous?.window ?? .default, profileName: previous?.profileName
                ).url
            )
        }

        switch status.phase {
        case .idle:
            return .startRecording
        case .recording:
            guard let requestID = status.activeRequestID else {
                // Recording without a request of ours: the user started a take
                // in the app itself. Leave it alone.
                return .busy(message: "Vocal is recording in the app.")
            }
            return .stopRecording(requestID: requestID)
        case .transcribing:
            return .busy(message: "Transcribing…")
        case .delivering:
            return .busy(message: "Almost there…")
        }
    }

    /// A status the app stopped refreshing is not evidence of a live session.
    public static func isFresh(_ status: BridgeStatus, at now: Date) -> Bool {
        let age = now.timeIntervalSince(status.updatedAt)
        // Future-dated status (clock change between processes) is treated as
        // fresh rather than stale: refusing it would strand a live session.
        return age <= statusFreshnessWindow
    }

    /// Whether a reply answers a request this keyboard is waiting on and is
    /// still recent enough to act on — whatever its outcome.
    ///
    /// Two guards, both about not acting on the wrong take: the reply must
    /// answer a request this keyboard instance issued, and it must be recent
    /// (a transcript from the previous host app must never surface in this
    /// one). Cancellations and failures pass this check too, so the keyboard
    /// can report them immediately instead of waiting for them to age out.
    public static func isCurrent(
        reply: BridgeReply,
        awaitingRequestID: UUID?,
        now: Date
    ) -> Bool {
        guard let awaitingRequestID, reply.requestID == awaitingRequestID else { return false }
        return now.timeIntervalSince(reply.producedAt) <= replyFreshnessWindow
    }

    /// Whether a reply's text should be typed at the cursor. A strictly
    /// narrower condition than ``isCurrent(reply:awaitingRequestID:now:)``:
    /// only a non-empty transcript is ever inserted.
    public static func shouldInsert(
        reply: BridgeReply,
        awaitingRequestID: UUID?,
        now: Date
    ) -> Bool {
        guard isCurrent(reply: reply, awaitingRequestID: awaitingRequestID, now: now) else {
            return false
        }
        return reply.insertableText?.isEmpty == false
    }

    /// One-line status text under the keys.
    public static func statusLine(for status: BridgeStatus?, at now: Date) -> String {
        guard let status, isFresh(status, at: now), let session = status.session,
            session.isArmed(at: now)
        else {
            return "Tap the mic to open Vocal and arm a session"
        }
        let remaining = Int(session.remaining(at: now).rounded(.down))
        let minutes = remaining / 60
        let clock = minutes >= 1 ? "\(minutes) min left" : "under a minute left"
        return "\(session.profileName) · \(clock)"
    }
}
