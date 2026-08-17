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
}
