import AppKit
import Foundation

/// Onboarding helpers for the Fn/Globe key (docs/03 §3.1).
///
/// The Globe system action (emoji picker / input-source switch / system
/// Dictation) fires at the IOHID layer — our event tap cannot suppress it.
/// The only clean coexistence is the user setting System Settings → Keyboard
/// → "Press 🌐 key to" = "Do Nothing". We only READ the preference and
/// deep-link the pane; we never `defaults write` it ourselves — a programmatic
/// write is ignored until re-login (docs/03 §3.1).
enum FnKeySetup {

    /// True when the Globe key currently has a system action bound that would
    /// fire alongside our push-to-talk, so onboarding should ask the user to
    /// set "Do Nothing". Reads `com.apple.HIToolbox AppleFnUsageType`; 0 or a
    /// missing key means the safe "Do Nothing" state (docs/03 §3.1).
    static func globeKeyActionIsConfigured() -> Bool {
        let value = CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString
        )
        guard let number = value as? NSNumber else {
            return false
        }
        return number.intValue != 0
    }

    /// Deep-link System Settings → Keyboard so the user flips the Globe
    /// action themselves (docs/03 §3.1: never write the default for them).
    @MainActor
    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
