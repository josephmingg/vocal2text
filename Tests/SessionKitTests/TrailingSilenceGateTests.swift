import Foundation
import Testing
@testable import SessionKit

// Mutating calls are hoisted out of #expect throughout: the macro rewrites a
// bare `gate.ingest(…)` into a function-call check whose subject is
// immutable, which does not compile for mutating members.
struct TrailingSilenceGateTests {

    @Test func silenceBeforeAnySpeechNeverTrips() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        for tick in 0..<100 {
            let tripped = gate.ingest(level: 0.05, at: Double(tick) * 0.1)
            #expect(!tripped)
        }
    }

    @Test func tripsOnceAfterSpeechThenSustainedSilence() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        _ = gate.ingest(level: 0.6, at: 0)
        _ = gate.ingest(level: 0.1, at: 1.0)
        let early = gate.ingest(level: 0.1, at: 2.0)
        #expect(!early)
        let tripped = gate.ingest(level: 0.1, at: 3.0)
        #expect(tripped)
        // Exactly once: further silence stays quiet until reset.
        let again = gate.ingest(level: 0.1, at: 4.0)
        #expect(!again)
    }

    @Test func speechResetsTheCountdown() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        _ = gate.ingest(level: 0.6, at: 0)
        _ = gate.ingest(level: 0.1, at: 1.0)
        // The user resumes speaking at 2.5 s — the countdown must restart.
        _ = gate.ingest(level: 0.7, at: 2.5)
        let atThree = gate.ingest(level: 0.1, at: 3.0)
        #expect(!atThree)
        let atFourAndAHalf = gate.ingest(level: 0.1, at: 4.5)
        #expect(!atFourAndAHalf)
        let tripped = gate.ingest(level: 0.1, at: 5.1)
        #expect(tripped)
    }

    @Test func theInBetweenBandNeitherArmsNorDefersTheStop() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        // 0.4 sits between silence (0.35) and speech (0.45): a gate fed only
        // this never arms…
        let unarmedEarly = gate.ingest(level: 0.4, at: 0)
        #expect(!unarmedEarly)
        let unarmedLate = gate.ingest(level: 0.4, at: 5)
        #expect(!unarmedLate)
        // …and once armed and counting, a word tail passing through the band
        // does not push the deadline out.
        _ = gate.ingest(level: 0.6, at: 6)
        _ = gate.ingest(level: 0.1, at: 7)
        _ = gate.ingest(level: 0.4, at: 8)
        let tripped = gate.ingest(level: 0.1, at: 9.1)
        #expect(tripped)
    }

    @Test func resetArmsANewTake() {
        var gate = TrailingSilenceGate(holdSeconds: 1)
        _ = gate.ingest(level: 0.6, at: 0)
        _ = gate.ingest(level: 0.1, at: 1)
        let firstTrip = gate.ingest(level: 0.1, at: 2.1)
        #expect(firstTrip)
        gate.reset()
        let quietAfterReset = gate.ingest(level: 0.1, at: 3)
        #expect(!quietAfterReset)
        _ = gate.ingest(level: 0.6, at: 4)
        _ = gate.ingest(level: 0.1, at: 5)
        let secondTrip = gate.ingest(level: 0.1, at: 6.1)
        #expect(secondTrip)
    }

    @Test func zeroHoldMeansDisabled() {
        var gate = TrailingSilenceGate(holdSeconds: 0)
        _ = gate.ingest(level: 0.6, at: 0)
        let tripped = gate.ingest(level: 0.1, at: 100)
        #expect(!tripped)
    }
}
