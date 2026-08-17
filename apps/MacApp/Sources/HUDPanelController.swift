import AppKit
import Combine
import SwiftUI

/// Owns the floating recording HUD: a fixed-size borderless `NSPanel` whose
/// SwiftUI content morphs inside a constant frame, so animations never clip
/// and the panel never steals focus from the target app (docs/03 §3.4,
/// SpeakType pattern per docs/09).
@MainActor
final class HUDPanelController {

    /// Constant panel frame; only the SwiftUI content inside changes shape
    /// (docs/03 §3.4).
    nonisolated static let panelSize = NSSize(width: 420, height: 88)

    /// Gap between the panel's bottom edge and the visible-frame bottom.
    nonisolated static let bottomMargin: CGFloat = 24

    private let appState: AppState
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []
    // nonisolated(unsafe): the token is written once on the main actor and
    // read only in deinit (which Swift 6 treats as nonisolated); the observer
    // must be removed there or its block leaks.
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    /// Latest values delivered by the Combine sinks. `@Published` emits during
    /// `willSet`, so reading `appState.hudState` inside a sink would observe
    /// the previous value — these mirrors hold the emitted (new) ones.
    private var currentState: HUDState
    private var isHUDEnabled: Bool

    init(appState: AppState) {
        self.appState = appState
        self.currentState = appState.hudState
        self.isHUDEnabled = appState.settings.hudEnabled

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSPanel defaults hidesOnDeactivate to true; the HUD must survive the
        // host app never being active (LSUIElement, docs/03 §3.4).
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        // The HUD renders as a dark capsule regardless of the system theme.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: HUDView(appState: appState))
        // No auto-layout sizing constraints from SwiftUI — the panel frame is
        // fixed and the root view already frames itself to `panelSize`.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        reposition()
        observeState()
        observeScreenChanges()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Geometry

    /// Bottom-center placement as a pure function, so it is unit-testable and
    /// can be re-run verbatim on screen-parameter changes (docs/03 §3.4;
    /// docs/09 "PillPosition" pattern).
    internal nonisolated static func position(panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + bottomMargin
        )
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        panel.setFrameOrigin(
            Self.position(panelSize: Self.panelSize, visibleFrame: screen.visibleFrame)
        )
    }

    // MARK: - Observation

    private func observeState() {
        appState.$hudState
            .sink { [weak self] state in
                guard let self else { return }
                self.currentState = state
                self.applyPresentation()
            }
            .store(in: &cancellables)

        // FR-4.3: the HUD can be disabled entirely; the menu-bar icon still
        // reflects state.
        appState.settings.$hudEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isHUDEnabled = enabled
                self.applyPresentation()
            }
            .store(in: &cancellables)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reposition()
            }
        }
    }

    // MARK: - Presentation

    private func applyPresentation() {
        guard isHUDEnabled, currentState.mode != .hidden else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }
        // Click-through except while listening (FR-4.2); the nonactivating
        // style means even interactive clicks never move focus.
        if case .listening = currentState.mode {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
        }
        reposition()
        panel.orderFrontRegardless()
    }
}
