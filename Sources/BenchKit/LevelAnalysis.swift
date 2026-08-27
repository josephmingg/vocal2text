import Foundation

/// Signal-level measurement for bench fixtures (docs/15 step 45's measurable
/// half): quiet-speech "whisper mode" tuning needs numbers before anyone can
/// say a fixture *is* quiet, or that accuracy at −40 dBFS regressed. Pure and
/// deterministic — frame the samples, estimate the noise floor from the
/// quietest frames, and report how far the speech sits above it.
public struct LevelAnalysis: Equatable, Sendable {
    /// Loudest single sample, in dBFS (0 = full scale).
    public var peakDBFS: Double
    /// Whole-signal RMS, in dBFS.
    public var rmsDBFS: Double
    /// RMS over speech-active frames only — the level of the voice itself,
    /// not diluted by the pauses around it.
    public var activeRMSDBFS: Double
    /// Active level minus the noise-floor estimate: the honest "how quiet is
    /// this recording really" number.
    public var estimatedSNRDecibels: Double

    /// Frame length used for the floor/activity split.
    public static let frameSeconds = 0.03
    /// A frame this far above the floor counts as speech.
    static let activityMarginDecibels = 10.0
    /// Silence clamps here rather than −∞, keeping the numbers printable.
    static let silenceFloorDBFS = -120.0

    /// nil for empty input. All-silence input reports the clamp floor
    /// everywhere with 0 dB SNR — a legible answer, not a crash.
    public static func analyze(samples: [Float], sampleRate: Int) -> LevelAnalysis? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let frameLength = max(1, Int(Double(sampleRate) * frameSeconds))
        var frameDecibels: [Double] = []
        var index = 0
        while index < samples.count {
            let end = min(index + frameLength, samples.count)
            frameDecibels.append(decibels(rms(samples[index..<end])))
            index = end
        }

        let sorted = frameDecibels.sorted()
        // The 10th-percentile frame is the noise floor: real speech leaves
        // plenty of between-word frames down there, and one dead frame does
        // not drag the estimate to the clamp.
        let floor = Percentile.value(sorted, 10)
        let activeFrames = frameDecibels.filter { $0 >= floor + activityMarginDecibels }
        // Energy-mean of the active frames (not a mean of dB values, which
        // would understate loud stretches).
        let active: Double
        if activeFrames.isEmpty {
            active = floor
        } else {
            let meanEnergy =
                activeFrames.map { pow(10, $0 / 10) }.reduce(0, +) / Double(activeFrames.count)
            active = 10 * log10(meanEnergy)
        }

        return LevelAnalysis(
            peakDBFS: decibels(Double(peak)),
            rmsDBFS: decibels(rms(samples[...])),
            activeRMSDBFS: active,
            estimatedSNRDecibels: max(0, active - floor)
        )
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return silenceFloorDBFS }
        return max(silenceFloorDBFS, 20 * log10(amplitude))
    }
}
