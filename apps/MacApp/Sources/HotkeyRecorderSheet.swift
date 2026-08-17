import AppKit
import CoreModels
import SwiftUI

/// "Press your desired key or combination now" — the Custom… half of the
/// push-to-talk picker (docs/13 §5).
///
/// Capture uses a local `NSEvent` monitor while the sheet is key: no event tap,
/// so recording a hotkey needs no permission the app does not already hold, and
/// nothing outside this window ever sees the keystrokes.
@MainActor
struct HotkeyRecorderSheet: View {

    /// Called with the recorded binding when the user commits it.
    private let onUse: (HotkeySpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = HotkeyRecorder()

    init(onUse: @escaping (HotkeySpec) -> Void) {
        self.onUse = onUse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Press your desired key or combination now")
                .font(.headline)
            Text(
                """
                Hold a single modifier (⌘, ⌥, ⌃, ⇧ or 🌐) and release it, or \
                press a key together with the modifiers you want to hold.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            keycap

            if let errorMessage = recorder.errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(recorder.candidate?.advisories ?? [], id: \.self) { advisory in
                HotkeyAdvisoryLabel(advisory: advisory)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use") {
                    if let candidate = recorder.candidate {
                        onUse(candidate)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.candidate == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            // Escape is reserved for cancelling a take, so it can never be
            // recorded; inside the sheet it closes instead (docs/13 §2). The
            // monitor swallows key events, so `.cancelAction` alone would not
            // fire while recording is live.
            recorder.onEscape = { dismiss() }
            recorder.start()
        }
        .onDisappear { recorder.stop() }
    }

    private var keycap: some View {
        HStack {
            Spacer()
            Text(recorder.displayText)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(recorder.candidate == nil ? .secondary : .primary)
            Spacer()
        }
        .frame(height: 56)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One caveat/conflict note, styled by severity (docs/13 §2).
@MainActor
struct HotkeyAdvisoryLabel: View {
    let advisory: HotkeyAdvisory

    var body: some View {
        Label(advisory.message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var symbol: String {
        advisory.severity == .warning ? "exclamationmark.triangle" : "info.circle"
    }

    private var color: Color {
        advisory.severity == .warning ? .orange : .secondary
    }
}

/// Capture state for `HotkeyRecorderSheet`.
///
/// Capture rule (docs/13 §5): the first stable combination wins — a
/// modifier-only binding finalizes when the lone modifier is *released*, a keyed
/// binding finalizes on `keyDown`. Pressing again replaces the candidate, so a
/// misfire costs one more press rather than a re-open.
@MainActor
final class HotkeyRecorder: ObservableObject {

    /// The binding that "Use" would commit; nil until something valid is
    /// captured.
    @Published private(set) var candidate: HotkeySpec?
    /// Why the last capture was refused (docs/13 §2 validation).
    @Published private(set) var errorMessage: String?
    /// Modifiers held right now, for the live readout before a key lands.
    @Published private(set) var liveFlags: UInt64 = 0

    /// Invoked when the user presses Escape — the sheet's cancel gesture.
    var onEscape: (() -> Void)?

    /// Set while exactly one modifier is held; releasing that same modifier
    /// commits it as a modifier-only binding.
    private var pendingModifier: (keyCode: UInt16, mask: UInt64)?
    private var monitor: Any?

    var displayText: String {
        if let candidate {
            return candidate.label
        }
        let symbols = KeycapNames.modifierSymbols(for: liveFlags)
        return symbols.isEmpty ? "…" : symbols
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.consume(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Returns nil to swallow the event: while the sheet records, keystrokes
    /// belong to the recorder and must not reach menus or text fields.
    private func consume(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown(event)
        default:
            return event
        }
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // NSEvent.ModifierFlags and CGEventFlags share bit positions, so the
        // raw value feeds the shared mask helpers directly.
        let flags = UInt64(event.modifierFlags.rawValue) & HotkeyFlagMask.significant
        liveFlags = flags
        guard let mask = HotkeyKeyCode.modifierFlagMask(for: event.keyCode) else {
            pendingModifier = nil
            if event.keyCode == HotkeyKeyCode.capsLock {
                refuse(.capsLockUnsupported)
            }
            return
        }
        if flags & mask != 0 {
            // Down edge. A lone modifier is a candidate; a second modifier
            // joining means the user is building a chord, which needs a key.
            pendingModifier = flags == mask ? (keyCode: event.keyCode, mask: mask) : nil
        } else if let pending = pendingModifier, pending.keyCode == event.keyCode {
            pendingModifier = nil
            capture(.modifierOnly(keyCode: pending.keyCode, flagMask: pending.mask))
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard event.keyCode != HotkeyKeyCode.escape else {
            onEscape?()
            return
        }
        pendingModifier = nil
        let requiredFlags = HotkeyFlagMask.normalized(
            UInt64(event.modifierFlags.rawValue),
            forKeyCode: event.keyCode
        )
        liveFlags = requiredFlags
        capture(.key(keyCode: event.keyCode, requiredFlags: requiredFlags))
    }

    private func capture(_ kind: HotkeySpec.Kind) {
        if let error = HotkeySpec.validationError(for: kind) {
            refuse(error)
            return
        }
        candidate = HotkeySpec(kind: kind)
        errorMessage = nil
    }

    private func refuse(_ error: HotkeyValidationError) {
        candidate = nil
        errorMessage = error.message
    }
}
