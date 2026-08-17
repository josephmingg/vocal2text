import AppKit
import Carbon
import Foundation

/// Pre-flight probe run at delivery time — not at press; the 1–3 s gap matters
/// (docs/03 §3.2, FR-3.6). When another process holds a secure-input session
/// (password fields, some terminals), insertion AND persistence are blocked
/// per FR-3.2, and the HUD names the culprit when the system will tell us.
enum SecureInputProbe {

    /// Kernel-level secure-input state — synthesized keystrokes and pasteboard
    /// paste are useless while this is on.
    static func isSecureInputActive() -> Bool {
        return IsSecureEventInputEnabled()
    }

    /// Best-effort name of the app holding secure input. The PID reported by
    /// `kCGSSessionSecureInputPID` can be wrong when a background app set the
    /// state (docs/03 §3.2), so callers must phrase around nil and treat any
    /// name as a hint ("a password field somewhere may be active"), never a
    /// certainty.
    static func culpritName() -> String? {
        guard let rawSessionInfo = CGSessionCopyCurrentDictionary() else {
            return nil
        }
        let sessionInfo = rawSessionInfo as NSDictionary
        guard let pidNumber = sessionInfo["kCGSSessionSecureInputPID"] as? NSNumber else {
            return nil
        }
        let pid = pid_t(pidNumber.int32Value)
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return application.localizedName
    }
}
