import AppKit
import Foundation

/// AppKit-side lifecycle owner: builds the composition root, wires the global
/// hotkey to it, hosts the HUD panel, and keeps the event tap alive across
/// sleep/wake (docs/03 §3.4).
///
/// Cross-agent surfaces referenced here:
/// - `HotkeyMonitor(settings:)` with assignable `onPressBegan: () -> Void`,
///   `onPressEnded: (_ isLockMode: Bool) -> Void`, `onCancel: () -> Void`
///   callbacks plus `start()` and `rearm()` (re-create the tap after wake).
/// - `HUDPanelController(appState:)` — owns the NSPanel HUD.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Built in `init` (not `applicationDidFinishLaunching`) so the SwiftUI
    /// `MenuBarExtra` can reference it from its first body evaluation.
    let appState: AppState

    private var hotkeyMonitor: HotkeyMonitor?
    private var hudController: HUDPanelController?
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        appState = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = HotkeyMonitor(settings: appState.settings)
        monitor.onPressBegan = { [weak self] in
            self?.appState.startDictation()
        }
        monitor.onPressEnded = { [weak self] isLockMode in
            self?.appState.stopDictation(isLockMode: isLockMode)
        }
        monitor.onCancel = { [weak self] in
            self?.appState.cancelDictation()
        }
        monitor.start()
        hotkeyMonitor = monitor

        hudController = HUDPanelController(appState: appState)

        observeWorkspaceNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers = []
    }

    // MARK: - Sleep/wake/lock (docs/03 §3.4)

    private func observeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        // A held push-to-talk must not stay "recording" through sleep — treat
        // sleep as a tap interruption (docs/03 §3.1: synthetic release rule).
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appState.cancelDictation()
                }
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hotkeyMonitor?.rearm()
                }
            }
        )

        // Fast user switching parks the session; the tap needs the same
        // re-arm treatment when this session becomes active again.
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hotkeyMonitor?.rearm()
                }
            }
        )
    }
}
