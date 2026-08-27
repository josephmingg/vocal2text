import Foundation
import Testing
@testable import BenchKit

struct LevelAnalysisTests {

    static func sine(amplitude: Float, seconds: Double, rate: Int = 16_000) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { index in
            amplitude * sin(Float(index) * 2 * .pi * 440 / Float(rate))
        }
    }

    @Test func emptyInputIsNil() {
        #expect(LevelAnalysis.analyze(samples: [], sampleRate: 16_000) == nil)
    }

    @Test func fullScaleSineMeasuresAsExpected() throws {
        let analysis = try #require(
            LevelAnalysis.analyze(samples: Self.sine(amplitude: 1.0, seconds: 1), sampleRate: 16_000)
        )
        // Peak 0 dBFS; sine RMS = amplitude/√2 ≈ −3.01 dBFS.
        #expect(abs(analysis.peakDBFS - 0) < 0.1)
        #expect(abs(analysis.rmsDBFS - (-3.01)) < 0.2)
    }

    @Test func silenceClampsInsteadOfExploding() throws {
        let analysis = try #require(
            LevelAnalysis.analyze(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        )
        #expect(analysis.peakDBFS == LevelAnalysis.silenceFloorDBFS)
        #expect(analysis.estimatedSNRDecibels == 0)
    }

    @Test func quietSpeechOverNoiseFloorReportsTheGap() throws {
        // 1 s of low noise (~0.001 ≈ −60 dBFS) then 1 s of "speech" at 0.1
        // (−23 dBFS RMS): the SNR estimate should land near the ~37 dB gap.
        var samples = (0..<16_000).map { _ in Float(0.001) }
        samples += Self.sine(amplitude: 0.1, seconds: 1)
        let analysis = try #require(LevelAnalysis.analyze(samples: samples, sampleRate: 16_000))
        #expect(analysis.estimatedSNRDecibels > 30)
        #expect(analysis.estimatedSNRDecibels < 45)
        // The active level reflects the tone, not the tone diluted by noise.
        #expect(abs(analysis.activeRMSDBFS - (-23)) < 2)
    }

    @Test func snrNeverGoesNegative() throws {
        // Constant tone: every frame is "active" relative to a floor equal to
        // itself — the estimate degrades to 0, not below.
        let analysis = try #require(
            LevelAnalysis.analyze(samples: Self.sine(amplitude: 0.5, seconds: 1), sampleRate: 16_000)
        )
        #expect(analysis.estimatedSNRDecibels >= 0)
    }
}
