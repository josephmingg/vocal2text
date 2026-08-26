import AppKit
import Foundation
import SessionKit

/// The macOS end of the insertion ladder (docs/03 §3.2): configuration-driven
/// tier selection (paste / Unicode typing / clipboard-only), a delivery-time
/// secure-input pre-flight (FR-3.2), and the lock-mode focus-change clipboard
/// fallback (FR-3.6). The HUD panel is non-activating, so the target app keeps
/// focus throughout — no activate-and-wait sleeps.
@MainActor
final class TextDeliverer: NSObject {

    private let strategies: InsertionStrategyTable
    private let clipboard: ClipboardManager

    /// Defaults let the composition root build a deliverer with the built-in
    /// strategy table (no user overrides) via `TextDeliverer()`.
    init(
        strategies: InsertionStrategyTable = InsertionStrategyTable(overrides: [:]),
        clipboard: ClipboardManager = ClipboardManager()
    ) {
        self.strategies = strategies
        self.clipboard = clipboard
        super.init()
    }

    func deliver(_ text: String, context: DeliveryContext) async -> DeliveryOutcome {
        // (1) Secure-input pre-flight runs at delivery time, not press — the
        // ~1–3 s gap matters (docs/03 §3.2, FR-3.6). Blocked means nothing is
        // inserted and nothing persisted (FR-3.2); the culprit name is a hint
        // only (the reported PID can be wrong for background apps).
        if SecureInputProbe.isSecureInputActive() {
            return .blockedSecureField(culpritApp: SecureInputProbe.culpritName())
        }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // (2) Lock-mode focus change: never paste into an app the user
        // wandered into during a hands-free take (FR-3.6). Hold-to-talk still
        // delivers — that switch was user-initiated within a short window.
        if context.isLockMode, context.pressTimeAppBundleID != frontmostBundleID {
            clipboard.write(text)
            return .copiedToClipboard(reason: .lockModeFocusChange)
        }

        guard let frontmostBundleID else {
            clipboard.write(text)
            return .copiedToClipboard(reason: .noFocusedField)
        }

        // (3) Tier selection. Tier 0 is AX insertion with a verifying
        // read-back (docs/15 step 17) — the success signal that finally lets
        // the ladder descend on failure; it only runs where the configured
        // strategy is paste, since unicodeTyping (terminals) and
        // clipboardOnly are deliberate choices about *how* text arrives.
        // Below tier 0, selection stays configuration-driven — a synthesized
        // ⌘V still has no reliable success signal (docs/03 §3.2).
        switch strategies.strategy(forBundleID: frontmostBundleID) {
        case .paste:
            if AXInserter.insertAndVerify(text) {
                return .inserted(method: .accessibility, appBundleID: frontmostBundleID)
            }
            return await paste(text, into: frontmostBundleID)
        case .unicodeTyping:
            KeystrokeSynthesizer.typeUnicode(text)
            return .inserted(method: .unicodeTyping, appBundleID: frontmostBundleID)
        case .clipboardOnly:
            clipboard.write(text)
            return .copiedToClipboard(reason: .userSetting)
        }
    }

    /// Tier 1: snapshot → write (transient+concealed) → ⌘V → restore, with
    /// per-app delays (Electron targets read the pasteboard late).
    private func paste(_ text: String, into bundleID: String) async -> DeliveryOutcome {
        let delays = strategies.pasteDelayMillis(forBundleID: bundleID)
        let snapshot = clipboard.snapshot()
        clipboard.write(text)
        try? await Task.sleep(for: .milliseconds(delays.prePaste))
        KeystrokeSynthesizer.synthesizeCmdV()
        try? await Task.sleep(for: .milliseconds(delays.preRestore))
        // Restore only if the pasteboard still holds our text — a user copy
        // during the window must never be clobbered (FR-3.5, docs/09).
        clipboard.restore(snapshot, ifPasteboardStillHolds: text)
        return .inserted(method: .paste, appBundleID: bundleID)
    }
}
