import ApplicationServices
import Carbon.HIToolbox
import CoreModels
import Foundation

/// Global push-to-talk hotkey monitor built on one CGEventTap (docs/03 §3.1).
///
/// A session-level tap listens for `keyDown|keyUp|flagsChanged`; the chosen
/// hotkey (Fn / right-⌘ / right-⌥) is edge-detected from `flagsChanged` on a
/// dedicated tap thread, and events are marshalled to the main actor via
/// `DispatchQueue.main` (FIFO — unstructured Tasks would not preserve edge
/// ordering).
///
/// The tap is `.defaultTap` but never consumes anything in v1: every event is
/// returned unmodified (docs/03 §3.1 — the Globe system action cannot be
/// suppressed anyway; onboarding handles it via `FnKeySetup`).
///
/// Requires the Accessibility permission; `start()` returns false without it.
/// Call `stop()` before releasing the monitor — there is no deinit teardown.
@MainActor
final class HotkeyMonitor {

    /// Accepted hotkey down-edge: pre-arm the session (docs/03 §2).
    var onPressBegan: (() -> Void)?
    /// Release after a hold ≥ 0.5 s (push-to-talk), or a synthesized release
    /// when the tap was force-disabled mid-press (docs/03 §3.1).
    var onPressEnded: (() -> Void)?
    /// Short tap (< 0.5 s) that may still become the first half of a lock
    /// double-tap — the caller ends the take provisionally and commits it
    /// only if `onLockToggle` doesn't fire within the double-tap window
    /// (SessionKit separately applies the has-speech override, FR-1.5).
    var onShortTap: (() -> Void)?
    /// Chord abort, or Escape while holding.
    var onCancel: (() -> Void)?
    /// Second tap of a double-tap: hands-free lock toggle (FR-1.3).
    var onLockToggle: (() -> Void)?

    private var choice: SettingsStore.HotkeyChoice
    private var machine: HotkeyTapMachine?
    /// Bumped on every start/stop so in-flight main-queue hops from a
    /// stopped tap are dropped instead of firing stale callbacks.
    private var generation = 0

    init(choice: SettingsStore.HotkeyChoice) {
        self.choice = choice
    }

    /// Creates and starts the event tap. Returns false when the Accessibility
    /// permission is missing or tap creation fails (either way: onboarding).
    func start() -> Bool {
        if machine != nil {
            return true
        }
        guard AXIsProcessTrusted() else {
            return false
        }
        generation += 1
        let expectedGeneration = generation
        let binding = Self.binding(for: choice)
        let machine = HotkeyTapMachine(
            hotkeyKeyCode: binding.keyCode,
            hotkeyFlag: binding.flag,
            hotkeyDeviceFlag: binding.deviceFlag
        ) { [weak self] event in
            // Tap thread → main actor. DispatchQueue.main preserves order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == expectedGeneration else {
                        return
                    }
                    self.dispatch(event)
                }
            }
        }
        guard machine.startTap() else {
            return false
        }
        self.machine = machine
        return true
    }

    func stop() {
        generation += 1
        machine?.stopTap()
        machine = nil
    }

    /// Tear down and recreate the tap — call on wake/unlock (docs/03 §3.4:
    /// re-arm the tap on wake). Returns whether the new tap armed, so callers
    /// can surface an unarmed hotkey instead of silently losing it.
    @discardableResult
    func rearm() -> Bool {
        stop()
        return start()
    }

    /// Switch the hotkey; rebuilds the tap machine when one is running.
    func updateChoice(_ newChoice: SettingsStore.HotkeyChoice) {
        guard newChoice != choice else {
            return
        }
        choice = newChoice
        if machine != nil {
            rearm()
        }
    }

    private func dispatch(_ event: HotkeyTapEvent) {
        switch event {
        case .pressBegan:
            onPressBegan?()
        case .pressEnded:
            onPressEnded?()
        case .shortTap:
            onShortTap?()
        case .cancelled:
            onCancel?()
        case .lockToggled:
            onLockToggle?()
        }
    }

    /// `deviceFlag` is the NX_DEVICER…KEYMASK bit for the physical right-side
    /// key (0x10 right-⌘, 0x40 right-⌥, per IOKit's NX event tables). It reads
    /// the edge direction for *this* key even while its left sibling holds the
    /// class mask; Fn has no sibling, so the class mask stays the signal.
    private static func binding(
        for choice: SettingsStore.HotkeyChoice
    ) -> (keyCode: Int64, flag: CGEventFlags, deviceFlag: CGEventFlags?) {
        switch choice {
        case .fnKey:
            return (Int64(kVK_Function), .maskSecondaryFn, nil)
        case .rightCommand:
            return (Int64(kVK_RightCommand), .maskCommand, CGEventFlags(rawValue: 0x0010))
        case .rightOption:
            return (Int64(kVK_RightOption), .maskAlternate, CGEventFlags(rawValue: 0x0040))
        }
    }
}

/// Events computed on the tap thread, marshalled to the main actor.
private enum HotkeyTapEvent: Sendable {
    case pressBegan
    case pressEnded
    case shortTap
    case cancelled
    case lockToggled
}

/// C callback for the event tap — runs on the tap thread. It must not capture
/// context; the machine arrives via `userInfo` (Unmanaged, docs/03 §3.1).
/// v1 never consumes events: the event is always returned unmodified.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let machine = Unmanaged<HotkeyTapMachine>.fromOpaque(userInfo).takeUnretainedValue()
    machine.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

/// Tap-side press state machine (docs/03 §3.1 semantics). Single-use: one
/// `startTap()` per instance; `HotkeyMonitor` builds a fresh machine per start.
///
/// Thread model: the C callback is the only reader/writer of the press state,
/// and the dedicated tap thread's run loop services events serially, so that
/// state is thread-confined. `runLoop` is the one cross-thread field and is
/// guarded by `stateLock`. `eventTap`/`runLoopSource` are written before the
/// tap thread starts (`Thread.start()` is the happens-before edge) and never
/// mutated afterwards. `@unchecked Sendable` because the compiler cannot see
/// this confinement.
private final class HotkeyTapMachine: @unchecked Sendable {

    private let hotkeyKeyCode: Int64
    private let hotkeyFlag: CGEventFlags
    /// Device-specific bit for the physical hotkey (see `binding(for:)`);
    /// nil for Fn, which has no left/right sibling.
    private let hotkeyDeviceFlag: CGEventFlags?
    private let sink: @Sendable (HotkeyTapEvent) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?

    private let stateLock = NSLock()
    /// Published by the tap thread at startup, consumed by `stopTap()`.
    private var runLoop: CFRunLoop?

    // Press state — tap-thread-confined. All timings use systemUptime
    // (docs/03 §3.1: 50 ms debounce on systemUptime).
    private var isPressed = false
    private var pressStartTime: TimeInterval = 0
    /// Down-edge time of the last short tap; a second down-edge within
    /// `doubleTapWindow` of it upgrades the pair to a lock toggle (FR-1.3).
    private var lastShortTapDownTime: TimeInterval?
    private var lastDownEdgeTime: TimeInterval = -1
    private var lastUpEdgeTime: TimeInterval = -1

    /// Same-direction edge debounce (docs/03 §3.1).
    private static let debounceInterval: TimeInterval = 0.050
    /// A hold shorter than this is a tap, not push-to-talk (FR-1.5).
    private static let holdThreshold: TimeInterval = 0.5
    /// Two down-edges within this window = double-tap → lock (FR-1.3).
    private static let doubleTapWindow: TimeInterval = 0.35
    /// Another keyDown this soon after the hotkey down-edge = chord →
    /// abort-before-start (docs/03 §3.1 — distinct from cancelling an
    /// established recording, which only Escape does).
    private static let chordAbortWindow: TimeInterval = 1.0

    /// Arrow and F-key keyCodes. macOS latches `.maskSecondaryFn` onto their
    /// events, so they must never be treated as Fn edges (docs/03 §3.1: strip
    /// `.function` from F-key/arrow events before matching).
    private static let fnLatchingKeyCodes = Set<Int64>(
        [
            kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow,
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ].map { Int64($0) }
    )

    init(
        hotkeyKeyCode: Int64,
        hotkeyFlag: CGEventFlags,
        hotkeyDeviceFlag: CGEventFlags?,
        sink: @escaping @Sendable (HotkeyTapEvent) -> Void
    ) {
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyFlag = hotkeyFlag
        self.hotkeyDeviceFlag = hotkeyDeviceFlag
        self.sink = sink
    }

    // MARK: Lifecycle (called on the main thread by HotkeyMonitor)

    func startTap() -> Bool {
        guard eventTap == nil else {
            return true
        }
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        let ready = DispatchSemaphore(value: 0)
        // The thread closure holds `self` strongly, so the machine (the tap's
        // unretained userInfo target) outlives every possible callback.
        let tapThread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            stateLock.lock()
            runLoop = loop
            stateLock.unlock()
            if let source = runLoopSource {
                CFRunLoopAddSource(loop, source, CFRunLoopMode.commonModes)
            }
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            ready.signal()
            CFRunLoopRun()
        }
        tapThread.name = "com.vocal.hotkey-tap"
        tapThread.qualityOfService = .userInteractive
        tapThread.start()
        if ready.wait(timeout: .now() + .seconds(2)) == .timedOut {
            // The tap thread never came up. Reporting success here would
            // leave the hotkey silently dead with the caller's retry loop
            // stopped; tear down and let the caller keep retrying.
            stopTap()
            return false
        }
        thread = tapThread
        return true
    }

    func stopTap() {
        stateLock.lock()
        let loop = runLoop
        runLoop = nil
        stateLock.unlock()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
        // eventTap/runLoopSource intentionally stay set: the tap thread may be
        // mid-callback; the invalidated port is inert, and nil-ing here would
        // race that thread's reads.
        thread = nil
    }

    // MARK: Event handling (tap thread, called from the C callback)

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            handleTapDisabled()
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown(event)
        default:
            break
        }
    }

    private func handleTapDisabled() {
        // Re-enable only from inside the callback (docs/03 §3.1). Never poll
        // CGEventTapIsEnabled from outside — documented IPC-voucher leak that
        // kernel-panics macOS 26.5.2 (docs/03 §3.1).
        Diagnostics.shared.increment(.hotkeyTapReenables)
        VocalLog.hotkey.warning("event tap was disabled by the system — re-enabling")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Edges were missed while disabled: a held press may have been
        // released unseen, so synthesize the release (docs/03 §3.1).
        if isPressed {
            isPressed = false
            lastShortTapDownTime = nil
            sink(.pressEnded)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Arrow/F-key events latch .maskSecondaryFn — never Fn edges
        // (docs/03 §3.1). Their synthesized Fn sandwich around a real
        // keyDown is caught by the chord abort below instead.
        if Self.fnLatchingKeyCodes.contains(keyCode) {
            return
        }
        guard keyCode == hotkeyKeyCode else {
            return
        }
        // Direction must be read per-key: with both ⌘ (or ⌥) keys held,
        // releasing the right one still leaves the class mask set for the
        // left sibling, which a bare contains(hotkeyFlag) misreads as a
        // down-edge — recording would start and never stop (docs/13's
        // "both-keys-held caveat"). The device-specific bit tracks exactly
        // this physical key.
        let isDown: Bool
        if let deviceFlag = hotkeyDeviceFlag {
            isDown = event.flags.contains(deviceFlag)
        } else {
            isDown = event.flags.contains(hotkeyFlag)
        }
        if isDown {
            downEdge()
        } else {
            upEdge()
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        guard isPressed else {
            return
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == Int64(kVK_Escape) {
            // Escape cancels an active press at any time (docs/03 §3.1).
            abortActivePress()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - pressStartTime < Self.chordAbortWindow {
            // Chord (e.g. Fn+arrow, right-⌘+C): the user wanted a shortcut,
            // not dictation → abort-before-start (docs/03 §3.1). The event
            // itself passes through untouched — we never swallow.
            abortActivePress()
        }
    }

    private func abortActivePress() {
        isPressed = false
        lastShortTapDownTime = nil
        sink(.cancelled)
    }

    private func downEdge() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDownEdgeTime < Self.debounceInterval {
            return
        }
        lastDownEdgeTime = now
        guard !isPressed else {
            return
        }
        isPressed = true
        pressStartTime = now
        sink(.pressBegan)
    }

    private func upEdge() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastUpEdgeTime < Self.debounceInterval {
            return
        }
        lastUpEdgeTime = now
        guard isPressed else {
            return
        }
        isPressed = false
        let heldDuration = now - pressStartTime
        if heldDuration >= Self.holdThreshold {
            lastShortTapDownTime = nil
            sink(.pressEnded)
            return
        }
        if let previousTapDownTime = lastShortTapDownTime,
            pressStartTime - previousTapDownTime <= Self.doubleTapWindow {
            // Second tap of a double-tap → hands-free lock toggle (FR-1.3).
            lastShortTapDownTime = nil
            sink(.lockToggled)
        } else {
            // Short tap: reported as `.shortTap` so the caller ends the take
            // provisionally — SessionKit's FR-1.5 heuristic still decides
            // (a sub-500 ms take WITH speech transcribes; without speech it
            // discards silently — docs/03 §3.1), but delivery waits out the
            // double-tap window so the first tap of a lock gesture can never
            // paste text before the second tap locks.
            lastShortTapDownTime = pressStartTime
            sink(.shortTap)
        }
    }
}
