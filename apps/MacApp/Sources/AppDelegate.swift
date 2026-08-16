import AppKit
import Combine
import Foundation

/// AppKit-side lifecycle owner: builds the composition root, wires the global
/// hotkey to it, hosts the HUD panel, and keeps the event tap alive across
/// sleep/wake (docs/03 §3.4).
///
/// Cross-agent surfaces referenced here:
/// - `HotkeyMonitor(choice:)` with assignable `onPressBegan` / `onPressEnded`
///   / `onCancel` / `onLockToggle: () -> Void` callbacks plus `start()`,
///   `rearm()` (re-create the tap after wake), and `updateChoice(_:)`.
/// - `HUDPanelController(appState:)` — owns the NSPanel HUD.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Built in `init` (not `applicationDidFinishLaunching`) so the SwiftUI
    /// `MenuBarExtra` can reference it from its first body evaluation.
    let appState: AppState

    private var hotkeyMonitor: HotkeyMonitor?
    private var hudController: HUDPanelController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsSinks: Set<AnyCancellable> = []
    /// Hands-free lock (FR-1.3). The monitor is stateless about lock mode; it
    /// reports edges and this flag reinterprets them while a locked take runs.
    private var isLockModeActive = false

    override init() {
        appState = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = HotkeyMonitor(choice: appState.settings.hotkeyChoice)
        monitor.onPressBegan = { [weak self] in
            guard let self else { return }
            // During a locked take the recording is already running; the
            // ending tap's down-edge must not re-arm (its up-edge stops it).
            if !self.isLockModeActive {
                self.appState.startDictation()
            }
        }
        monitor.onPressEnded = { [weak self] in
            guard let self else { return }
            let wasLocked = self.isLockModeActive
            self.isLockModeActive = false
            self.appState.stopDictation(isLockMode: wasLocked)
        }
        monitor.onCancel = { [weak self] in
            guard let self else { return }
            if self.isLockModeActive {
                // A short tap finishes a hands-free take and transcribes it
                // (FR-1.3) — only Escape discards, which the monitor reports
                // while a press is held, and the session ignores when idle.
                self.isLockModeActive = false
                self.appState.stopDictation(isLockMode: true)
            } else {
                self.appState.cancelDictation()
            }
        }
        monitor.onLockToggle = { [weak self] in
            guard let self else { return }
            if self.isLockModeActive {
                self.isLockModeActive = false
                self.appState.stopDictation(isLockMode: true)
            } else {
                // The second tap's down-edge already started the recording;
                // it now runs hands-free until the next tap (FR-1.3).
                self.isLockModeActive = true
            }
        }
        _ = monitor.start()
        hotkeyMonitor = monitor

        // Hotkey choice changes take effect immediately, not at relaunch.
        appState.settings.$hotkeyChoice
            .dropFirst()
            .sink { [weak self] choice in
                self?.hotkeyMonitor?.updateChoice(choice)
                self?.hotkeyMonitor?.rearm()
            }
            .store(in: &settingsSinks)

        hudController = HUDPanelController(appState: appState)

        observeWorkspaceNotifications()

        if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            WindowManager.shared.showOnboarding(appState: appState)
        }
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
                    self?.isLockModeActive = false
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
