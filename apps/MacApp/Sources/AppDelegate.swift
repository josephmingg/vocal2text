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
    /// FR-1.3 hard cap: a forgotten hands-free take auto-stops (default 15 min)
    /// instead of recording until the disk fills.
    private var lockCapTask: Task<Void, Never>?
    /// First run: Accessibility isn't granted yet, so the tap fails to arm;
    /// this poll re-arms the moment the user grants it during onboarding.
    private var armRetryTimer: Timer?
    /// Pending commit of a short-tap take (FR-1.5 × FR-1.3): fires once the
    /// double-tap window closes; a lock gesture cancels it and discards the
    /// held take so the first tap can never paste before the second locks.
    private var shortTapCommitTask: Task<Void, Never>?
    /// The tap machine's double-tap window (0.35 s) plus margin for the
    /// tap-thread → main-actor hop.
    private static let shortTapCommitDelay = Duration.milliseconds(400)

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
            self.endLockMode(stopping: false)
            self.appState.stopDictation(isLockMode: wasLocked)
        }
        monitor.onShortTap = { [weak self] in
            guard let self else { return }
            if self.isLockModeActive {
                // A single tap ends a hands-free take immediately — no
                // deferral; a double tap during lock just restarts one.
                self.endLockMode(stopping: false)
                self.appState.stopDictation(isLockMode: true)
                return
            }
            // End the take now (mic off), deliver only if no second tap
            // upgrades this into the lock gesture within the window.
            self.appState.endDictationProvisionally()
            self.shortTapCommitTask?.cancel()
            self.shortTapCommitTask = Task { [weak self] in
                try? await Task.sleep(for: Self.shortTapCommitDelay)
                guard !Task.isCancelled else { return }
                self?.appState.commitProvisionalDictation()
            }
        }
        monitor.onCancel = { [weak self] in
            guard let self else { return }
            if self.isLockModeActive {
                // Escape/chord during a hands-free take discards it (FR-1.6);
                // finishing-and-transcribing is the tap path (onPressEnded).
                self.endLockMode(stopping: false)
            }
            self.appState.cancelDictation()
        }
        monitor.onLockToggle = { [weak self] in
            guard let self else { return }
            if self.isLockModeActive {
                self.endLockMode(stopping: true)
            } else {
                // The tap pair was the lock gesture: drop the first tap's
                // held take, then run the second tap's recording hands-free
                // until the next tap (FR-1.3).
                self.shortTapCommitTask?.cancel()
                self.shortTapCommitTask = nil
                self.appState.discardProvisionalDictation()
                self.isLockModeActive = true
                self.startLockCapTimer()
            }
        }
        let armed = monitor.start()
        appState.hotkeyArmed = armed
        if !armed {
            scheduleArmRetry()
        }
        hotkeyMonitor = monitor

        // Hotkey choice changes take effect immediately, not at relaunch.
        appState.settings.$hotkeyChoice
            .dropFirst()
            .sink { [weak self] choice in
                self?.hotkeyMonitor?.updateChoice(choice)
                self?.rearmAndReport()
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
        lockCapTask?.cancel()
        shortTapCommitTask?.cancel()
        armRetryTimer?.invalidate()
    }

    /// Re-arms the tap and mirrors the result into `hotkeyArmed`; a failed
    /// re-arm restarts the retry poll instead of leaving the hotkey dead.
    private func rearmAndReport() {
        let armed = hotkeyMonitor?.rearm() ?? false
        appState.hotkeyArmed = armed
        if !armed {
            scheduleArmRetry()
        }
    }

    // MARK: - Lock-mode cap + first-run arming

    private func startLockCapTimer() {
        lockCapTask?.cancel()
        lockCapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15 * 60))
            guard !Task.isCancelled, let self, self.isLockModeActive else { return }
            self.endLockMode(stopping: false)
            self.appState.stopDictation(isLockMode: true)
            self.appState.hudState.mode = .notice("Hands-free capped at 15 min — take saved")
        }
    }

    private func endLockMode(stopping: Bool) {
        isLockModeActive = false
        lockCapTask?.cancel()
        lockCapTask = nil
        if stopping {
            appState.stopDictation(isLockMode: true)
        }
    }

    private func scheduleArmRetry() {
        armRetryTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hotkeyMonitor?.start() == true {
                    self.appState.hotkeyArmed = true
                    self.armRetryTimer?.invalidate()
                    self.armRetryTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        armRetryTimer = timer
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
                    self?.rearmAndReport()
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
                    self?.rearmAndReport()
                }
            }
        )
    }
}
