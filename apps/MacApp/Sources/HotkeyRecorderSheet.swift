import AppKit
import CoreModels
import SwiftUI

/// "Press your desired key or combination now" — the Custom… half of the
/// push-to-talk picker (docs/13 §5).
///
/// Capture uses a local `NSEvent` monitor for the duration of the sheet: no
/// event tap, so recording needs no permission the app does not already hold,
/// and no other process ever sees the keystrokes. The monitor is local, so it
/// consumes key events destined for Vocal only, and only while the sheet is up.
@MainActor
struct HotkeyRecorderSheet: View {

    /// What is bound right now, shown so the sheet does not open on a blank
    /// slate with no reminder of what it is about to replace.
    private let currentBinding: HotkeySpec
    /// The live push-to-talk tap, suspended for as long as the sheet is up.
    /// Without this, holding the current hotkey to see it captured would also
    /// start a real dictation behind the sheet.
    private let hotkeyMonitor: HotkeyMonitor?
    /// Called with the recorded binding when the user commits it.
    private let onUse: (HotkeySpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = HotkeyRecorder()

    init(
        currentBinding: HotkeySpec,
        hotkeyMonitor: HotkeyMonitor?,
        onUse: @escaping (HotkeySpec) -> Void
    ) {
        self.currentBinding = currentBinding
        self.hotkeyMonitor = hotkeyMonitor
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

            Text("Currently: \(currentBinding.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if let errorMessage = recorder.errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(recorder.candidate?.advisories ?? [], id: \.self) { advisory in
                HotkeyAdvisoryLabel(advisory: advisory)
            }

            Text("Press ⏎ to use it, or esc to close without changing your key.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.candidate == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(WindowReader { recorder.hostWindow = $0 })
        .onAppear {
            // The recorder swallows key events, so the Cancel and Use buttons'
            // keyboard shortcuts never fire on their own — Escape and Return
            // are routed back out of the capture logic instead (docs/13 §2:
            // Escape is reserved, so it can never be recorded).
            recorder.onEscape = { dismiss() }
            recorder.onCommit = { commit() }
            hotkeyMonitor?.suspend()
            recorder.start()
        }
        .onDisappear {
            recorder.stop()
            hotkeyMonitor?.resume()
        }
    }

    private func commit() {
        if let candidate = recorder.candidate {
            onUse(candidate)
        }
        dismiss()
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

/// Hands back the `NSWindow` hosting this view, so the recorder can tell its own
/// sheet's key events from those of Vocal's other windows.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
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

/// The facts a capture needs, lifted off the `NSEvent` on the event-monitor's
/// own thread. `NSEvent` is not `Sendable`, so this value — which is — is what
/// crosses to the main actor.
///
/// `NSEvent.ModifierFlags` and `CGEventFlags` share bit positions, so the raw
/// flags feed `HotkeyFlagMask` directly, with no translation table.
private struct RecordedKeyEvent: Sendable {
    enum Kind: Sendable {
        case keyDown
        case flagsChanged
    }

    var kind: Kind
    var keyCode: UInt16
    var flags: UInt64
    var isRepeat: Bool
    /// Whether any modifier at all was held — Return with a modifier is a
    /// recordable chord, bare Return is the confirm gesture.
    var hasModifiers: Bool

    /// Fails for any event type outside the monitor's mask.
    init?(_ event: NSEvent) {
        switch event.type {
        case .keyDown: kind = .keyDown
        case .flagsChanged: kind = .flagsChanged
        default: return nil
        }
        keyCode = event.keyCode
        flags = UInt64(event.modifierFlags.rawValue)
        hasModifiers = flags & HotkeyFlagMask.significant != 0
        // `isARepeat` is only defined for key events.
        isRepeat = event.type == .keyDown && event.isARepeat
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
    /// Invoked when the user presses Return on a valid capture — the sheet's
    /// default action, which cannot fire on its own while capture swallows keys.
    var onCommit: (() -> Void)?
    /// The sheet's own window. Key events belonging to Vocal's other windows
    /// (History, Settings behind the sheet) are left alone.
    var hostWindow: NSWindow?

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
        // A re-opened sheet starts blank: a candidate left over from a session
        // the user cancelled must never be one click from being committed.
        candidate = nil
        errorMessage = nil
        liveFlags = 0
        pendingModifier = nil
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let recorded = RecordedKeyEvent(event) else { return event }
            let isOurs = MainActor.assumeIsolated { self?.owns(event.window) ?? false }
            guard isOurs else { return event }
            // Only Sendable values cross to the main actor — NSEvent is not
            // Sendable, so it stays on this side of the hop.
            let swallow = MainActor.assumeIsolated { self?.consume(recorded) ?? false }
            return swallow ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onEscape = nil
        onCommit = nil
    }

    /// Until the host window resolves, claim everything — a recorder that
    /// captures nothing is a worse failure than one that is briefly greedy.
    private func owns(_ window: NSWindow?) -> Bool {
        guard let hostWindow else { return true }
        return window == nil || window === hostWindow
    }

    /// Returns true when the event must not travel on. Key presses are
    /// swallowed — while the sheet records, they belong to the recorder and
    /// must not type or fire a menu shortcut. Modifier changes pass through so
    /// the rest of the app keeps an accurate picture of what is held down.
    private func consume(_ event: RecordedKeyEvent) -> Bool {
        switch event.kind {
        case .flagsChanged:
            handleFlagsChanged(event)
            return false
        case .keyDown:
            handleKeyDown(event)
            return true
        }
    }

    private func handleFlagsChanged(_ event: RecordedKeyEvent) {
        let flags = event.flags & HotkeyFlagMask.significant
        liveFlags = flags
        guard let mask = HotkeyKeyCode.modifierFlagMask(for: event.keyCode) else {
            pendingModifier = nil
            if event.keyCode == HotkeyKeyCode.capsLock {
                // The latch happens below the event tap and cannot be undone
                // from here, so at least say so — otherwise the user is left
                // with a refusal and an inexplicably lit keyboard.
                let turnedOn = event.flags & HotkeyFlagMask.capsLock != 0
                errorMessage = HotkeyValidationError.capsLockUnsupported.message
                    + (turnedOn ? " Caps Lock is now on — press it again to turn it off." : "")
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

    /// True when the key press was handled as a sheet gesture rather than as
    /// something to record.
    private func handleSheetGesture(_ event: RecordedKeyEvent) -> Bool {
        if event.keyCode == HotkeyKeyCode.escape {
            onEscape?()
            return true
        }
        // Bare Return confirms, the way the blue default button implies. With a
        // modifier held it is an ordinary chord and gets recorded.
        if !event.hasModifiers,
            event.keyCode == HotkeyKeyCode.returnKey || event.keyCode == HotkeyKeyCode.keypadEnter,
            candidate != nil {
            onCommit?()
            return true
        }
        return false
    }

    private func handleKeyDown(_ event: RecordedKeyEvent) {
        guard !event.isRepeat else { return }
        guard !handleSheetGesture(event) else { return }
        pendingModifier = nil
        let requiredFlags = HotkeyFlagMask.normalized(event.flags, forKeyCode: event.keyCode)
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

    /// Explains the refusal but keeps whatever was already captured — a bad
    /// press should cost the user an explanation, not their good capture.
    private func refuse(_ error: HotkeyValidationError) {
        errorMessage = error.message
    }
}
