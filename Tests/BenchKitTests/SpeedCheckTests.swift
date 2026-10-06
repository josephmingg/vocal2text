import Foundation
import Testing
@testable import BenchKit

/// docs/17 G0: the built-in Speed Check's scoring and recommendation.
struct SpeedCheckTests {

    private func measure(_ engine: String, _ index: Int, decode: Double, text: String? = nil) -> SpeedCheck.Measurement {
        SpeedCheck.measure(
            engine: engine,
            passageIndex: index,
            transcript: text ?? SpeedCheck.passages[index],
            audioSeconds: 10,
            decodeSeconds: decode,
            pipelineSeconds: 0.002
        )
    }

    @Test func passagesAreWordsOnlySoWERScoresRecognition() {
        #expect(SpeedCheck.passages.count == 3)
        for passage in SpeedCheck.passages {
            let hasDigit = passage.contains { $0.isNumber }
            let wordCount = passage.split { $0.isWhitespace }.count
            #expect(!hasDigit)
            #expect(wordCount >= 25)
        }
    }

    @Test func aPerfectTranscriptScoresZeroWERRegardlessOfCaseAndPunctuation() {
        let shouted = SpeedCheck.passages[0].uppercased().replacingOccurrences(of: ",", with: "")
        #expect(measure("Whisper", 0, decode: 1, text: shouted).wordErrorRate == 0)
    }

    @Test func summariesAggregatePerEngine() {
        let rows = [
            measure("Whisper", 0, decode: 1.0), measure("Whisper", 1, decode: 1.2), measure("Whisper", 2, decode: 0.8),
            measure("Parakeet", 0, decode: 0.05), measure("Parakeet", 1, decode: 0.06), measure("Parakeet", 2, decode: 0.04),
        ]
        let summaries = SpeedCheck.summarize(rows)
        #expect(summaries.map(\.engine) == ["Whisper", "Parakeet"])
        #expect(summaries[0].takes == 3)
        #expect(abs(summaries[0].releaseToTextP50 - 1.002) < 1e-9)
        #expect(abs(summaries[1].realTimeFactor - 30 / 0.15) < 1e-6)
    }

    @Test func parakeetIsRecommendedWhenFasterAndAboutAsAccurate() {
        let summaries = SpeedCheck.summarize([measure("Whisper", 0, decode: 1), measure("Parakeet", 0, decode: 0.1)])
        #expect(SpeedCheck.recommendation(summaries).hasPrefix("Turn on Parakeet"))
    }

    @Test func whisperStaysWhenParakeetIsLessAccurate() {
        let sloppy = "thanks for the draft the structure works but cut the second section"
        let summaries = SpeedCheck.summarize([
            measure("Whisper", 0, decode: 1), measure("Parakeet", 0, decode: 0.1, text: sloppy),
        ])
        #expect(SpeedCheck.recommendation(summaries).hasPrefix("Keep Whisper: Parakeet was faster"))
    }

    @Test func oneEngineGetsNoRecommendation() {
        let summaries = SpeedCheck.summarize([measure("Whisper", 0, decode: 1)])
        #expect(SpeedCheck.recommendation(summaries).hasPrefix("Run the check with both engines"))
    }

    @Test func markdownReportHasTheTableRecommendationAndTranscripts() {
        let report = SpeedCheck.markdown(
            measurements: [measure("Whisper", 0, decode: 1), measure("Parakeet", 0, decode: 0.1)],
            machine: "MacBook Pro (M2)",
            date: Date(timeIntervalSince1970: 1_791_288_000)
        )
        #expect(report.hasPrefix("# Speed Check — MacBook Pro (M2)"))
        #expect(report.contains("| Whisper | 1 | 1002 ms |"))
        #expect(report.contains("**Recommendation:** Turn on Parakeet"))
        #expect(report.contains("**Parakeet**, passage 1"))
    }
}
