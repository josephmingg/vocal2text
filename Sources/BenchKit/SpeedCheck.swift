import Foundation

/// The built-in Speed Check (docs/17 G0): read three short passages once,
/// decode the *same* audio with each engine, and get your own release→text
/// numbers and accuracy — the evidence that decides whether Parakeet becomes
/// the default English engine (G0.3). Pure scoring and reporting; the app
/// records and runs the engines.
public enum SpeedCheck {

    /// Words only — no digits, times or symbols — so WER scores recognition,
    /// not whether an engine writes "three thirty" or "3:30".
    public static let passages: [String] = [
        "Thanks for sending the draft over. I read it this morning and the structure works well, but the second section repeats the introduction, so let's cut it before we share it with the team.",
        "Could you move our weekly sync to Thursday afternoon? I have a dentist appointment on Wednesday, and I would rather not rush the conversation about the new onboarding flow.",
        "The build failed again because the test runner could not find the configuration file. I think the path changed when we renamed the folder, so I will fix it after lunch.",
    ]

    /// One engine's result on one recorded passage.
    public struct Measurement: Sendable, Equatable {
        public var engine: String
        public var passageIndex: Int
        public var audioSeconds: Double
        /// Engine decode time: the bulk of the release→text wait.
        public var decodeSeconds: Double
        /// Deterministic text pipeline (stages 1–4) on the transcript.
        public var pipelineSeconds: Double
        public var transcript: String
        public var wordErrorRate: Double

        public init(
            engine: String,
            passageIndex: Int,
            audioSeconds: Double,
            decodeSeconds: Double,
            pipelineSeconds: Double,
            transcript: String,
            wordErrorRate: Double
        ) {
            self.engine = engine
            self.passageIndex = passageIndex
            self.audioSeconds = audioSeconds
            self.decodeSeconds = decodeSeconds
            self.pipelineSeconds = pipelineSeconds
            self.transcript = transcript
            self.wordErrorRate = wordErrorRate
        }

        /// Decode + text pipeline: release→text minus insertion, which is the
        /// same for every engine.
        public var releaseToTextSeconds: Double { decodeSeconds + pipelineSeconds }
    }

    /// Scores a transcript against its passage.
    public static func measure(
        engine: String,
        passageIndex: Int,
        transcript: String,
        audioSeconds: Double,
        decodeSeconds: Double,
        pipelineSeconds: Double
    ) -> Measurement {
        let reference = passages.indices.contains(passageIndex) ? passages[passageIndex] : ""
        return Measurement(
            engine: engine,
            passageIndex: passageIndex,
            audioSeconds: audioSeconds,
            decodeSeconds: decodeSeconds,
            pipelineSeconds: pipelineSeconds,
            transcript: transcript,
            wordErrorRate: WordErrorRate.score(reference: reference, hypothesis: transcript).rate
        )
    }

    /// Per-engine aggregate.
    public struct Summary: Sendable, Equatable {
        public var engine: String
        public var takes: Int
        public var releaseToTextP50: Double
        public var releaseToTextP95: Double
        /// Audio seconds per decode second (higher is faster).
        public var realTimeFactor: Double
        /// Word-weighted across passages.
        public var wordErrorRate: Double
        /// Words in the passages this engine read; WER's denominator.
        public var referenceWords: Int = 0

        /// Wrong, missing or extra words, counted against the passages.
        public var wordErrors: Int { Int((wordErrorRate * Double(referenceWords)).rounded()) }
    }

    /// One summary per engine, in first-seen order.
    public static func summarize(_ measurements: [Measurement]) -> [Summary] {
        var order: [String] = []
        for measurement in measurements where !order.contains(measurement.engine) {
            order.append(measurement.engine)
        }
        return order.map { engine in
            let rows = measurements.filter { $0.engine == engine }
            let latencies = rows.map(\.releaseToTextSeconds).sorted()
            let audio = rows.map(\.audioSeconds).reduce(0, +)
            let decode = rows.map(\.decodeSeconds).reduce(0, +)
            // Word-weighted WER: each passage counts by its reference length.
            var errors = 0.0
            var words = 0.0
            for row in rows {
                let reference = passages.indices.contains(row.passageIndex) ? passages[row.passageIndex] : ""
                let count = Double(reference.split(whereSeparator: \.isWhitespace).count)
                errors += row.wordErrorRate * count
                words += count
            }
            return Summary(
                engine: engine,
                takes: rows.count,
                releaseToTextP50: Percentile.value(latencies, 50),
                releaseToTextP95: Percentile.value(latencies, 95),
                realTimeFactor: decode > 0 ? audio / decode : 0,
                wordErrorRate: words > 0 ? errors / words : 0,
                referenceWords: Int(words)
            )
        }
    }

    /// The outcome of the docs/17 G0.3 gate.
    public enum Verdict: Sendable, Equatable {
        case needBothEngines
        case useParakeet
        case keepWhisperLessAccurate
        case keepWhisperNotFaster
    }

    /// How many more word errors Parakeet may make and still count as about
    /// as accurate. The check reads about 94 words, so one point of WER is a
    /// single word, and one reading of the same passage varies by a word or
    /// two: the owner's two runs split 6 against 7 errors, once each way, on
    /// the same "sync"/"sink" word. A gap that small is the reading, not the
    /// engine. Longer samples get one point of WER instead.
    static func errorTolerance(words: Int) -> Int {
        max(2, Int((Double(words) * 0.01).rounded()))
    }

    /// The docs/17 G0.3 gate: Parakeet earns the English default when it is
    /// faster and makes no more than `errorTolerance` extra word errors.
    public static func verdict(_ summaries: [Summary]) -> Verdict {
        guard
            let whisper = summaries.first(where: { $0.engine.lowercased().contains("whisper") }),
            let parakeet = summaries.first(where: { $0.engine.lowercased().contains("parakeet") })
        else {
            return .needBothEngines
        }
        let faster = parakeet.releaseToTextP50 < whisper.releaseToTextP50
        let words = max(whisper.referenceWords, parakeet.referenceWords)
        let accurateEnough = parakeet.wordErrors <= whisper.wordErrors + errorTolerance(words: words)
        switch (faster, accurateEnough) {
        case (true, true): return .useParakeet
        case (true, false): return .keepWhisperLessAccurate
        case (false, _): return .keepWhisperNotFaster
        }
    }

    public static func recommendation(_ summaries: [Summary]) -> String {
        switch verdict(summaries) {
        case .needBothEngines:
            return "Run the check with both engines to get a recommendation."
        case .useParakeet:
            return "Turn on Parakeet for English: it was faster and about as accurate on your voice."
        case .keepWhisperLessAccurate:
            return "Keep Whisper: Parakeet was faster but noticeably less accurate on your voice."
        case .keepWhisperNotFaster:
            return "Keep Whisper: Parakeet was not faster on this Mac."
        }
    }

    /// A Markdown report, ready to commit as docs/benchmarks/M0-results.md.
    public static func markdown(
        measurements: [Measurement], machine: String, date: Date
    ) -> String {
        let summaries = summarize(measurements)
        let stamp = ISO8601DateFormatter().string(from: date)
        var lines = [
            "# Speed Check — \(machine)",
            "",
            "Recorded \(stamp) with Vocal's built-in Speed Check (docs/17 G0): each passage read once, the same audio decoded by every engine after a warm-up. Release→text = engine decode + text pipeline; insertion is identical across engines and not included.",
            "",
            "| Engine | Takes | Release→text p50 | p95 | Real-time factor | WER |",
            "|---|---|---|---|---|---|",
        ]
        for summary in summaries {
            lines.append(
                "| \(summary.engine) | \(summary.takes) | \(milliseconds(summary.releaseToTextP50)) | "
                    + "\(milliseconds(summary.releaseToTextP95)) | "
                    + String(format: "%.0fx", summary.realTimeFactor) + " | "
                    + String(format: "%.1f%%", summary.wordErrorRate * 100) + " |"
            )
        }
        if let words = summaries.map(\.referenceWords).max(), words > 0 {
            let counts = summaries.map { "\($0.engine) \($0.wordErrors)" }.joined(separator: ", ")
            lines += ["", "Word errors, of \(words) words: \(counts)."]
        }
        lines += ["", "**Recommendation:** \(recommendation(summaries))", "", "## Transcripts", ""]
        for measurement in measurements {
            lines.append(
                "- **\(measurement.engine)**, passage \(measurement.passageIndex + 1) "
                    + "(\(String(format: "%.1f", measurement.audioSeconds)) s audio, "
                    + "\(milliseconds(measurement.releaseToTextSeconds)), "
                    + String(format: "WER %.1f%%", measurement.wordErrorRate * 100) + "): "
                    + measurement.transcript
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func milliseconds(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}
