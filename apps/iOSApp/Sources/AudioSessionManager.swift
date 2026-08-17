import AVFoundation
import Foundation

/// One place that configures `AVAudioSession`, because two places would fight.
///
/// Both the ordinary "hold the button and speak" take and an armed capture
/// session (docs/02 §3.1) run over the same session; only the engine on top of
/// it changes. Keeping the session itself continuously active across that
/// handoff is what stops iOS suspending the app between the keyboard's mic
/// press and the recording actually starting.
@MainActor
enum AudioSessionManager {

    /// Activates a capture-capable session. Idempotent.
    ///
    /// `.mixWithOthers` is deliberate: arming a session should not stop the
    /// user's podcast for the next five minutes.
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true)
    }

    /// Releases the session and lets other apps resume at full volume.
    static func deactivate() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Whether the microphone is usable without prompting — used to explain
    /// rather than silently fail when arming.
    static var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
}

/// Keeps the app resident while a capture session is armed.
///
/// The honest mechanism, stated in the PRD and in the arming UI: iOS keeps a
/// backgrounded app alive only while its audio session is *actively running*,
/// so an armed session runs a real input tap that throws its samples away.
/// That is why the orange recording dot stays lit for the whole window and why
/// the default window is only five minutes.
///
/// The idle engine yields the input to the real capture engine during a take
/// and takes it back afterwards; the `AVAudioSession` underneath stays active
/// throughout, which is the part that preserves residency.
@MainActor
final class CaptureResidency {

    private var engine: AVAudioEngine?

    var isRunning: Bool { engine?.isRunning ?? false }

    /// Starts the discard tap. Safe to call when already running.
    func beginIdleHold() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        // Samples are deliberately dropped: this tap exists to keep the audio
        // session running, not to capture anything.
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in }
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    /// Stops the discard tap so a real capture engine can own the input.
    func endIdleHold() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
