import Foundation
import Testing
@testable import SessionKit

struct TrailingSilenceGateTests {

    @Test func silenceBeforeAnySpeechNeverTrips() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        for tick in 0..<100 {
            #expect(!gate.ingest(level: 0.05, at: Double(tick) * 0.1))
        }
    }

    @Test func tripsOnceAfterSpeechThenSustainedSilence() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        #expect(!gate.ingest(level: 0.6, at: 0))
        #expect(!gate.ingest(level: 0.1, at: 1.0))
        #expect(!gate.ingest(level: 0.1, at: 2.0))
        #expect(gate.ingest(level: 0.1, at: 3.0))
        // Exactly once: further silence stays quiet until reset.
        #expect(!gate.ingest(level: 0.1, at: 4.0))
    }

    @Test func speechResetsTheCountdown() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        _ = gate.ingest(level: 0.6, at: 0)
        _ = gate.ingest(level: 0.1, at: 1.0)
        // The user resumes speaking at 2.5 s — the countdown must restart.
        _ = gate.ingest(level: 0.7, at: 2.5)
        #expect(!gate.ingest(level: 0.1, at: 3.0))
        #expect(!gate.ingest(level: 0.1, at: 4.5))
        #expect(gate.ingest(level: 0.1, at: 5.1))
    }

    @Test func theInBetweenBandNeitherArmsNorDefersTheStop() {
        var gate = TrailingSilenceGate(holdSeconds: 2)
        // 0.4 sits between silence (0.35) and speech (0.45): a gate fed only
        // this never arms…
        #expect(!gate.ingest(level: 0.4, at: 0))
        #expect(!gate.ingest(level: 0.4, at: 5))
        // …and once armed and counting, a word tail passing through the band
        // does not push the deadline out.
        _ = gate.ingest(level: 0.6, at: 6)
        _ = gate.ingest(level: 0.1, at: 7)
        _ = gate.ingest(level: 0.4, at: 8)
        #expect(gate.ingest(level: 0.1, at: 9.1))
    }

    @Test func resetArmsANewTake() {
        var gate = TrailingSilenceGate(holdSeconds: 1)
        _ = gate.ingest(level: 0.6, at: 0)
        _ = gate.ingest(level: 0.1, at: 1)
        #expect(gate.ingest(level: 0.1, at: 2.1))
        gate.reset()
        #expect(!gate.ingest(level: 0.1, at: 3))
        _ = gate.ingest(level: 0.6, at: 4)
        _ = gate.ingest(level: 0.1, at: 5)
        #expect(gate.ingest(level: 0.1, at: 6.1))
    }

    @Test func zeroHoldMeansDisabled() {
        var gate = TrailingSilenceGate(holdSeconds: 0)
        _ = gate.ingest(level: 0.6, at: 0)
        #expect(!gate.ingest(level: 0.1, at: 100))
    }
}
