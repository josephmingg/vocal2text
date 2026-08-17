import AppKit
import SwiftUI

/// Owner of the app's real windows. Settings, History, and Onboarding are
/// AppKit-managed `NSWindow`s hosting SwiftUI because SwiftUI's `openSettings`
/// is broken from menu-bar (`LSUIElement`) apps (docs/03 §3.4). Windows are
/// created once, retained here with `isReleasedWhenClosed = false`, and
/// re-presented on subsequent calls.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    private init() {}

    func showSettings(appState: AppState) {
        if settingsWindow == nil {
            settingsWindow = Self.makeWindow(
                title: "Vocal Settings",
                content: SettingsView(appState: appState),
                size: NSSize(width: 560, height: 480),
                resizable: false
            )
        }
        present(settingsWindow)
    }

    func showHistory(appState: AppState) {
        if historyWindow == nil {
            historyWindow = Self.makeWindow(
                title: "History",
                content: HistoryView(appState: appState),
                size: NSSize(width: 760, height: 480),
                resizable: true
            )
        }
        present(historyWindow)
    }

    func showOnboarding(appState: AppState) {
        if onboardingWindow == nil {
            let view = OnboardingView(appState: appState) { [weak self] in
                self?.onboardingWindow?.close()
            }
            onboardingWindow = Self.makeWindow(
                title: "Welcome to Vocal",
                content: view,
                size: NSSize(width: 520, height: 440),
                resizable: false
            )
        }
        present(onboardingWindow)
    }

    // MARK: - Helpers

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        // An accessory (LSUIElement) app is not frontmost when the menu-bar
        // item is clicked; without activation the window opens behind others.
        NSApp.activate()
    }

    private static func makeWindow(
        title: String,
        content: some View,
        size: NSSize,
        resizable: Bool
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            styleMask.insert(.resizable)
        }
        window.styleMask = styleMask
        window.setContentSize(size)
        // Retained by this manager for reuse; AppKit must not deallocate the
        // window when the user closes it (docs/03 §3.4).
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
