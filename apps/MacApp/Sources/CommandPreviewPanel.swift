import AppKit
import SwiftUI

/// What the command preview shows (docs/17 G4, after Glaido's command
/// window): the spoken instruction, then the model's answer to accept with
/// Return or dismiss with Escape.
@MainActor
final class CommandPreviewModel: ObservableObject {
    enum Phase: Equatable {
        case thinking
        case ready(String)
        case failed(String)
    }

    @Published var instruction = ""
    @Published var actsOnSelection = false
    @Published var phase: Phase = .thinking
    /// The Cancel button's action (the panel is not key while thinking, so
    /// Escape would go to the user's app instead).
    var cancel: () -> Void = {}
}

/// A panel that can take keyboard focus without activating Vocal — so the
/// app the user was working in stays frontmost, with its selection intact,
/// and Return/Escape still reach the preview.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the command preview window. Every `begin` bumps a generation, so a
/// slow model answer for a command the user already dismissed (or replaced
/// with a newer one) is dropped instead of popping up late.
@MainActor
final class CommandPreviewController {
    private let model: CommandPreviewModel
    private let panel: NSPanel
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onInsert: ((String) -> Void)?
    private var onDismiss: (() -> Void)?
    private(set) var generation = 0

    init() {
        let model = CommandPreviewModel()
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // Titled only for the rounded corners and shadow: a transient
        // preview has no business showing close/minimise/zoom buttons.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: CommandPreviewView(model: model))
        self.model = model
        self.panel = panel
    }

    var isVisible: Bool { panel.isVisible }
    /// Whether the preview holds the keyboard (an answer is showing).
    var isKey: Bool { panel.isKeyWindow }

    /// Shows the "working on it" state for a new command and returns the
    /// token its answer must carry. The panel does not take keyboard focus
    /// yet: for the seconds a model can take, the user keeps typing in their
    /// own app (docs/17 §11). It becomes key when there is something to act
    /// on. `onDismiss` runs when the preview closes without inserting.
    @discardableResult
    func begin(
        instruction: String,
        actsOnSelection: Bool,
        onInsert: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) -> Int {
        // A replaced preview counts as dismissed: its model call must stop.
        let previous = self.onDismiss
        self.onDismiss = nil
        previous?()
        generation += 1
        model.instruction = instruction
        model.actsOnSelection = actsOnSelection
        model.phase = .thinking
        model.cancel = { [weak self] in self?.dismiss() }
        self.onInsert = onInsert
        self.onDismiss = onDismiss
        present()
        return generation
    }

    func show(result: String, for token: Int) {
        guard token == generation, panel.isVisible else { return }
        model.phase = .ready(result)
        takeFocus()
    }

    func show(failure: String, for token: Int) {
        guard token == generation, panel.isVisible else { return }
        model.phase = .failed(failure)
        takeFocus()
    }

    func dismiss() {
        generation += 1
        onInsert = nil
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        panel.orderOut(nil)
    }

    // MARK: - Presentation

    private func present() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height / 6)
            )
        }
        panel.orderFrontRegardless()
    }

    /// The answer (or failure) is in: take the keyboard so Return, ⌘C and
    /// Escape reach the preview. Never steals the app activation.
    private func takeFocus() {
        panel.makeKey()
        installKeyMonitor()
        // Clicking anywhere else abandons the preview — Return would
        // otherwise land in whatever the user clicked into.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                }
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Only Sendable values cross into the main-actor hop (NSEvent is
            // not Sendable) — the same pattern as the hotkey recorder.
            let keyCode = event.keyCode
            let isCopy = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "c"
            let swallow = MainActor.assumeIsolated {
                self?.handleKey(keyCode, isCopy: isCopy) ?? false
            }
            return swallow ? nil : event
        }
    }

    /// Return / keypad Enter inserts a ready answer; Escape dismisses; ⌘C
    /// copies the answer. Everything else passes through untouched.
    private func handleKey(_ keyCode: UInt16, isCopy: Bool) -> Bool {
        guard panel.isKeyWindow else { return false }
        switch keyCode {
        case 36, 76:
            if case .ready(let text) = model.phase {
                let insert = onInsert
                // Inserting is not abandoning: the model call is done.
                onDismiss = nil
                dismiss()
                insert?(text)
            }
            return true
        case 53:
            dismiss()
            return true
        default:
            if isCopy, case .ready(let text) = model.phase {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                return true
            }
            return false
        }
    }
}

/// SwiftUI body of the preview window.
private struct CommandPreviewView: View {
    @ObservedObject var model: CommandPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Text(model.instruction)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                if model.actsOnSelection {
                    Text("on selection")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.phase == .thinking {
                    Button("Cancel") { model.cancel() }
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 260)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .thinking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Working on it…")
                    .foregroundStyle(.secondary)
            }
        case .ready(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var hint: String {
        switch model.phase {
        case .ready: "↩ Insert   ⌘C Copy   ⎋ Dismiss"
        case .thinking: "Keep typing — the answer appears here"
        case .failed: "⎋ Dismiss"
        }
    }
}
