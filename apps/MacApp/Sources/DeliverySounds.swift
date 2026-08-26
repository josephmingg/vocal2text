import AppKit

/// Start/stop feedback sounds for dictation takes, using system sounds so no
/// audio assets ship with the app. Callers pass the current
/// `SettingsStore.soundsEnabled` value; the flag is respected here so call
/// sites never need their own guards.
@MainActor
enum DeliverySounds {

    static func playStart(enabled: Bool) {
        guard enabled else { return }
        NSSound(named: "Tink")?.play()
    }

    static func playStop(enabled: Bool) {
        guard enabled else { return }
        NSSound(named: "Pop")?.play()
    }

    /// Text landed in the target app (docs/15 step 23): the paste moment gets
    /// its own sound, distinct from the stop click that precedes it.
    static func playDelivered(enabled: Bool) {
        guard enabled else { return }
        NSSound(named: "Bottle")?.play()
    }

    /// A take failed and the HUD is about to say so.
    static func playError(enabled: Bool) {
        guard enabled else { return }
        NSSound(named: "Basso")?.play()
    }
}
