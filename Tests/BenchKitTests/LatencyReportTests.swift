import CoreModels
import Foundation
import Testing
@testable import BenchKit

struct LatencyReportTests {

    private func sample(
        duration: Double, transcribe: Double, arm: Double = 0.05
    ) -> LatencyReport.Sample {
        LatencyReport.Sample(
            durationSeconds: duration,
            timings: TimingBreakdown(
                armSeconds: arm,
                captureSeconds: duration,
                transcriptionSeconds: transcribe,
                dictionarySeconds: 0.01,
                cleanupSeconds: 0,
                deliverySeconds: 0.1
            )
        )
    }

    @Test func emptyHistoryExplainsItself() {
        let report = LatencyReport.render(samples: [])
        #expect(report.contains("No completed dictations"))
    }

    @Test func samplesLandInTheirDurationBuckets() {
        let report = LatencyReport.render(samples: [
            sample(duration: 2, transcribe: 0.4),
            sample(duration: 8, transcribe: 1.2),
            sample(duration: 30, transcribe: 3.0),
        ])
        #expect(report.contains("## under 5 s (1 takes)"))
        #expect(report.contains("## 5–15 s (1 takes)"))
        #expect(report.contains("## over 15 s (1 takes)"))
    }

    @Test func percentilesCoverEveryStageIncludingTheNewMarks() {
        let report = LatencyReport.render(samples: [
            sample(duration: 2, transcribe: 0.4),
            sample(duration: 3, transcribe: 0.6),
        ])
        // The two marks docs/15 step 47 adds: press→mic-open and the
        // release→text total the user feels.
        #expect(report.contains("| arm |"))
        #expect(report.contains("| release→text |"))
        #expect(report.contains("| transcribe |"))
        // p50 of [0.4, 0.6] by nearest rank is 0.4.
        #expect(report.contains("| transcribe | 0.40s"))
    }
}
