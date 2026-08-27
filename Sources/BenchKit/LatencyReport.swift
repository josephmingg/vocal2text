import CoreModels
import Foundation

/// Renders latency percentiles from real daily-driving history (docs/15
/// step 47): the fixture harness measures fixtures; this measures the takes
/// the user actually dictated, per stage, bucketed by utterance length.
/// Pure — the CLI feeds it decoded `TimingBreakdown`s from the transcript
/// database and prints what comes back.
public enum LatencyReport {

    /// One take's contribution: how long the utterance was, and its timings.
    public struct Sample: Sendable {
        public var durationSeconds: Double
        public var timings: TimingBreakdown

        public init(durationSeconds: Double, timings: TimingBreakdown) {
            self.durationSeconds = durationSeconds
            self.timings = timings
        }
    }

    /// Utterance-length buckets: short taps, ordinary dictation, long-form.
    static let buckets: [(label: String, range: Range<Double>)] = [
        ("under 5 s", 0..<5),
        ("5–15 s", 5..<15),
        ("over 15 s", 15..<Double.infinity),
    ]

    static let percentiles: [Double] = [50, 95, 99]

    /// Markdown report. Empty input explains itself rather than rendering an
    /// empty table.
    public static func render(samples: [Sample]) -> String {
        guard !samples.isEmpty else {
            return "No completed dictations with timings found — dictate first, then re-run."
        }
        var lines: [String] = []
        lines.append("# Latency from history (\(samples.count) takes)")
        lines.append("")
        lines.append("`release→text` is the wait the user feels; `arm` is press→mic-open.")
        for bucket in buckets {
            let matching = samples.filter { bucket.range.contains($0.durationSeconds) }
            lines.append("")
            lines.append("## \(bucket.label) (\(matching.count) takes)")
            guard !matching.isEmpty else { continue }
            lines.append("")
            lines.append("| stage | p50 | p95 | p99 |")
            lines.append("|---|---|---|---|")
            let stages: [(String, (TimingBreakdown) -> Double)] = [
                ("arm", { $0.armSeconds }),
                ("transcribe", { $0.transcriptionSeconds }),
                ("dictionary", { $0.dictionarySeconds }),
                ("cleanup", { $0.cleanupSeconds }),
                ("deliver", { $0.deliverySeconds }),
                ("release→text", { $0.totalPostReleaseSeconds }),
            ]
            for (label, extract) in stages {
                let sorted = matching.map { extract($0.timings) }.sorted()
                let cells = percentiles
                    .map { String(format: "%.2fs", Percentile.value(sorted, $0)) }
                    .joined(separator: " | ")
                lines.append("| \(label) | \(cells) |")
            }
        }
        return lines.joined(separator: "\n")
    }
}
