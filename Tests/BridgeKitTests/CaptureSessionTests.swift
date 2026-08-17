import Foundation
import Testing

@testable import BridgeKit

@Suite("Capture session arming")
struct CaptureSessionTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Windows carry the docs/02 durations")
    func windowDurations() {
        #expect(CaptureWindow.fiveMinutes.duration == 300)
        #expect(CaptureWindow.fifteenMinutes.duration == 900)
        #expect(CaptureWindow.sixtyMinutes.duration == 3_600)
        // The cheapest window is the default: an armed session burns battery.
        #expect(CaptureWindow.default == .fiveMinutes)
        #expect(CaptureWindow.allCases.count == 3)
    }

    @Test("Every window states the residency trade")
    func disclosureMentionsTheCost() {
        for window in CaptureWindow.allCases {
            let text = window.residencyDisclosure
            #expect(text.contains(window.displayName))
            #expect(text.lowercased().contains("battery"))
        }
    }

    @Test("Arming sets expiry one window ahead")
    func armingSetsExpiry() {
        let state = CaptureSessionState.armed(
            window: .fifteenMinutes, profileName: "Chat", now: epoch
        )
        #expect(state.armedAt == epoch)
        #expect(state.expiresAt == epoch.addingTimeInterval(900))
        #expect(state.profileName == "Chat")
    }

    @Test("Expiry is exclusive at the boundary")
    func expiryBoundaryIsExclusive() {
        let state = CaptureSessionState.armed(
            window: .fiveMinutes, profileName: "Default", now: epoch
        )
        #expect(state.isArmed(at: epoch))
        #expect(state.isArmed(at: epoch.addingTimeInterval(299.999)))
        // Exactly at expiry the session is over — both processes must agree.
        #expect(!state.isArmed(at: epoch.addingTimeInterval(300)))
        #expect(!state.isArmed(at: epoch.addingTimeInterval(301)))
    }

    @Test("Remaining never goes negative")
    func remainingIsFloored() {
        let state = CaptureSessionState.armed(
            window: .fiveMinutes, profileName: "Default", now: epoch
        )
        #expect(state.remaining(at: epoch) == 300)
        #expect(state.remaining(at: epoch.addingTimeInterval(120)) == 180)
        #expect(state.remaining(at: epoch.addingTimeInterval(9_999)) == 0)
    }

    @Test("Extending restarts the full window without moving armedAt")
    func extendingRestartsTheWindow() {
        let state = CaptureSessionState.armed(
            window: .fiveMinutes, profileName: "Default", now: epoch
        )
        let later = epoch.addingTimeInterval(240)
        let extended = state.extended(to: later)
        #expect(extended.armedAt == epoch)
        #expect(extended.expiresAt == later.addingTimeInterval(300))
        #expect(extended.isArmed(at: later.addingTimeInterval(299)))
    }

    @Test("Expiring ends the session now but keeps how it was armed")
    func expiringKeepsTheTerms() {
        let state = CaptureSessionState.armed(
            window: .sixtyMinutes, profileName: "Email", now: epoch
        )
        let stopped = state.expired(at: epoch.addingTimeInterval(120))
        #expect(!stopped.isArmed(at: epoch.addingTimeInterval(120)))
        // These are what the keyboard's re-arm link offers back.
        #expect(stopped.window == .sixtyMinutes)
        #expect(stopped.profileName == "Email")
        #expect(stopped.armedAt == epoch)
    }

    @Test("Expiring never extends a session that already ended")
    func expiringNeverExtends() {
        let state = CaptureSessionState.armed(
            window: .fiveMinutes, profileName: "Chat", now: epoch
        )
        let alreadyOver = epoch.addingTimeInterval(9_999)
        let stopped = state.expired(at: alreadyOver)
        #expect(stopped.expiresAt == state.expiresAt)
        #expect(!stopped.isArmed(at: epoch.addingTimeInterval(299)))
    }

    @Test("Retargeting keeps the clock")
    func retargetingKeepsTheClock() {
        let state = CaptureSessionState.armed(
            window: .sixtyMinutes, profileName: "Default", now: epoch
        )
        let moved = state.retargeted(toProfileNamed: "Email")
        #expect(moved.profileName == "Email")
        #expect(moved.expiresAt == state.expiresAt)
        #expect(moved.armedAt == state.armedAt)
    }
}
