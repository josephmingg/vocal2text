import Foundation

/// Ends a hands-free take when the speaker has clearly stopped (the Phase 3
/// follow-up docs/15 step 22 left open): once speech has been heard, a
/// sustained run of near-silence trips the gate exactly once.
///
/// Deliberately energy-based, not model-based: it consumes the same
/// dB-normalized 0…1 levels the HUD waveform draws (`AudioLevelMeter` — 0 is
/// the −60 dBFS floor, ordinary speech ≈ 0.5–0.8), so it adds no second
/// consumer to the audio stream and no live VAD session. The Silero pass
/// still owns "was there speech at all" after the take ends; this gate only
/// decides *when* a locked take ends.
///
/// Hysteresis: arming requires a level above `speechLevel`; the countdown
/// runs while levels sit below the lower `silenceLevel`, so breathy trailing
/// consonants and room tone between words neither arm nor reset it.
public struct TrailingSilenceGate: Sendable {

    /// HUD-scale level that counts as the user speaking (≈ −33 dBFS).
    public var speechLevel: Float = 0.45
    /// HUD-scale level below which the countdown runs (≈ −39 dBFS).
    public var silenceLevel: Float = 0.35
    /// How long the silence must hold before the gate trips.
    public var holdSeconds: Double

    private var heardSpeech = false
    private var silenceBegan: Double?
    private var tripped = false

    public init(holdSeconds: Double) {
        self.holdSeconds = holdSeconds
    }

    /// Feeds one level with its position on the take's timeline (seconds from
    /// any fixed origin). Returns true exactly once, when silence has held
    /// for `holdSeconds` after speech was heard; after that the gate stays
    /// quiet until `reset()`.
    public mutating func ingest(level: Float, at seconds: Double) -> Bool {
        guard !tripped, holdSeconds > 0 else { return false }
        if level >= speechLevel {
            heardSpeech = true
            silenceBegan = nil
            return false
        }
        if level > silenceLevel {
            // The in-between band: not speech, not silence. It neither arms
            // nor advances the countdown, and it does not reset one that is
            // already running — a fading word tail should not defer the stop.
            return false
        }
        guard heardSpeech else { return false }
        guard let began = silenceBegan else {
            silenceBegan = seconds
            return false
        }
        if seconds - began >= holdSeconds {
            tripped = true
            return true
        }
        return false
    }

    /// Ready for the next take.
    public mutating func reset() {
        heardSpeech = false
        silenceBegan = nil
        tripped = false
    }
}
