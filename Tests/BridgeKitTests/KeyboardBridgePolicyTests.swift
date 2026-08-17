import Foundation
import Testing

@testable import BridgeKit

@Suite("Keyboard mic-key policy")
struct KeyboardBridgePolicyTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func armedStatus(
        phase: BridgeStatus.Phase = .idle,
        activeRequestID: UUID? = nil,
        window: CaptureWindow = .fiveMinutes,
        profile: String = "Chat",
        updatedAt: Date? = nil
    ) -> BridgeStatus {
        BridgeStatus(
            updatedAt: updatedAt ?? epoch,
            session: .armed(window: window, profileName: profile, now: epoch),
            phase: phase,
            activeRequestID: activeRequestID,
            availableProfileNames: ["Chat", "Email"]
        )
    }

    private func action(
        _ status: BridgeStatus?,
        fullAccess: Bool = true,
        container: Bool = true,
        at now: Date? = nil
    ) -> MicKeyAction {
        KeyboardBridgePolicy.micKeyAction(
            status: status,
            hasFullAccess: fullAccess,
            containerReachable: container,
            now: now ?? epoch
        )
    }

    @Test("Without Full Access the key explains itself instead of failing")
    func withoutFullAccess() {
        guard case .unavailable(let message) = action(armedStatus(), fullAccess: false) else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(message == KeyboardBridgePolicy.fullAccessMessage)
        // The scary prompt is the reason people bail — the copy must say
        // Vocal makes no network calls.
        #expect(message.lowercased().contains("no network"))
    }

    @Test("An unreachable App Group is reported, not silently ignored")
    func unreachableContainer() {
        guard case .unavailable = action(armedStatus(), container: false) else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test("No status at all means bounce to the app to arm")
    func noStatusOpensTheApp() throws {
        guard case .openApp(let url) = action(nil) else {
            Issue.record("expected .openApp")
            return
        }
        let parsed = try #require(VocalURL(url))
        #expect(parsed == .arm(window: .default, profileName: nil))
    }

    @Test("A stale status is not evidence of a live session")
    func staleStatusOpensTheApp() {
        let stale = epoch.addingTimeInterval(KeyboardBridgePolicy.statusFreshnessWindow + 1)
        guard case .openApp = action(armedStatus(), at: stale) else {
            Issue.record("expected .openApp for a status the app stopped refreshing")
            return
        }
        // One second inside the window is still trusted.
        let fresh = epoch.addingTimeInterval(KeyboardBridgePolicy.statusFreshnessWindow)
        #expect(action(armedStatus(updatedAt: fresh), at: fresh) == .startRecording)
    }

    @Test("An expired session bounces, carrying its profile forward")
    func expiredSessionOpensTheApp() throws {
        let afterExpiry = epoch.addingTimeInterval(301)
        let status = armedStatus(updatedAt: afterExpiry)
        guard case .openApp(let url) = action(status, at: afterExpiry) else {
            Issue.record("expected .openApp")
            return
        }
        #expect(VocalURL(url) == .arm(window: .default, profileName: "Chat"))
    }

    @Test("Armed and idle starts a recording")
    func armedIdleStarts() {
        #expect(action(armedStatus(phase: .idle)) == .startRecording)
    }

    @Test("Recording for us stops that exact request")
    func recordingStopsOurRequest() {
        let id = UUID()
        #expect(
            action(armedStatus(phase: .recording, activeRequestID: id)) == .stopRecording(
                requestID: id
            )
        )
    }

    @Test("A take started in the app is left alone")
    func foreignRecordingIsBusy() {
        guard case .busy = action(armedStatus(phase: .recording, activeRequestID: nil)) else {
            Issue.record("expected .busy when the app records without our request")
            return
        }
    }

    @Test("Mid-pipeline phases report busy")
    func pipelinePhasesAreBusy() {
        for phase in [BridgeStatus.Phase.transcribing, .delivering] {
            guard case .busy = action(armedStatus(phase: phase)) else {
                Issue.record("expected .busy for \(phase)")
                return
            }
        }
    }

    @Test("Future-dated status is trusted rather than stranding a live session")
    func futureDatedStatusIsFresh() {
        let status = armedStatus(updatedAt: epoch.addingTimeInterval(30))
        #expect(KeyboardBridgePolicy.isFresh(status, at: epoch))
    }
}

@Suite("Reply insertion guards")
struct ReplyInsertionTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func reply(
        id: UUID,
        outcome: BridgeReply.Outcome = .text("hello"),
        producedAt: Date? = nil
    ) -> BridgeReply {
        BridgeReply(
            requestID: id,
            producedAt: producedAt ?? epoch,
            outcome: outcome,
            language: .english,
            profileName: "Chat"
        )
    }

    @Test("A reply to our own request inserts")
    func matchingReplyInserts() {
        let id = UUID()
        #expect(
            KeyboardBridgePolicy.shouldInsert(
                reply: reply(id: id), awaitingRequestID: id, now: epoch
            )
        )
    }

    @Test("A reply to somebody else's request never inserts")
    func mismatchedReplyIsDropped() {
        #expect(
            !KeyboardBridgePolicy.shouldInsert(
                reply: reply(id: UUID()), awaitingRequestID: UUID(), now: epoch
            )
        )
        #expect(
            !KeyboardBridgePolicy.shouldInsert(
                reply: reply(id: UUID()), awaitingRequestID: nil, now: epoch
            )
        )
    }

    @Test("A stale reply is dropped — it belongs to an earlier host app")
    func staleReplyIsDropped() {
        let id = UUID()
        let late = epoch.addingTimeInterval(KeyboardBridgePolicy.replyFreshnessWindow + 1)
        #expect(
            !KeyboardBridgePolicy.shouldInsert(reply: reply(id: id), awaitingRequestID: id, now: late)
        )
    }

    @Test("Cancelled, failed, and empty replies insert nothing")
    func nonTextRepliesInsertNothing() {
        let id = UUID()
        for outcome in [
            BridgeReply.Outcome.cancelled,
            .failed(reason: "boom"),
            .text(""),
        ] {
            #expect(
                !KeyboardBridgePolicy.shouldInsert(
                    reply: reply(id: id, outcome: outcome), awaitingRequestID: id, now: epoch
                )
            )
        }
    }
}

@Suite("Keyboard status line")
struct KeyboardStatusLineTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Unarmed keyboards tell the user what the mic key will do")
    func unarmedLine() {
        #expect(KeyboardBridgePolicy.statusLine(for: nil, at: epoch).contains("arm a session"))
    }

    @Test("Armed keyboards show profile and time left")
    func armedLine() {
        let session = CaptureSessionState.armed(
            window: .fifteenMinutes, profileName: "Chat", now: epoch
        )
        #expect(
            KeyboardBridgePolicy.statusLine(
                for: BridgeStatus(updatedAt: epoch, session: session), at: epoch
            ) == "Chat · 15 min left"
        )
        // The status is republished as the session runs, so it stays fresh.
        let nearlyOver = epoch.addingTimeInterval(870)
        #expect(
            KeyboardBridgePolicy.statusLine(
                for: BridgeStatus(updatedAt: nearlyOver, session: session), at: nearlyOver
            ) == "Chat · under a minute left"
        )
    }

    @Test("A status the app stopped refreshing falls back to the unarmed line")
    func staleArmedLine() {
        let status = BridgeStatus(
            updatedAt: epoch,
            session: .armed(window: .sixtyMinutes, profileName: "Chat", now: epoch)
        )
        let late = epoch.addingTimeInterval(KeyboardBridgePolicy.statusFreshnessWindow + 1)
        #expect(KeyboardBridgePolicy.statusLine(for: status, at: late).contains("arm a session"))
    }
}
