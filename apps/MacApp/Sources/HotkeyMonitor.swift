import ApplicationServices
import CoreModels
import Foundation
import SessionKit

/// Global push-to-talk hotkey monitor built on one CGEventTap (docs/03 §3.1).
///
/// A session-level tap listens for `keyDown|keyUp|flagsChanged` on a dedicated
/// tap thread; each event is handed to a `HotkeyDecisionCore` — the pure state
/// machine that owns every press semantic (hold/tap/double-tap-lock/chord-abort,
/// docs/13 §4) — and the decisions it returns are marshalled to the main actor
/// via `DispatchQueue.main` (FIFO — unstructured Tasks would not preserve edge
/// ordering).
///
/// This type is deliberately thin: tap creation, the tap thread, re-enable
/// hygiene, and dispatch. Anything a user can feel belongs in the core, where
/// Linux CI tests it.
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
    /// Short tap (< 0.5 s — SessionKit separately applies the has-speech
    /// override, FR-1.5), chord abort, or Escape while holding.
    var onCancel: (() -> Void)?
    /// Second tap of a double-tap: hands-free lock toggle (FR-1.3).
    var onLockToggle: (() -> Void)?

    private var spec: HotkeySpec
    private var machine: HotkeyTapMachine?
    /// Whether `suspend()` interrupted a live tap, so `resume()` knows whether
    /// to bring it back.
    private var wasArmedBeforeSuspend = false
    /// Bumped on every start/stop so in-flight main-queue hops from a
    /// stopped tap are dropped instead of firing stale callbacks.
    private var generation = 0

    init(spec: HotkeySpec) {
        self.spec = spec
    }

    /// Whether the tap is live. False means the hotkey does nothing — the UI
    /// uses this to say so instead of leaving the user guessing.
    var isArmed: Bool { machine != nil }

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
        let machine = HotkeyTapMachine(spec: spec) { [weak self] decision in
            // Tap thread → main actor. DispatchQueue.main preserves order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == expectedGeneration else {
                        return
                    }
                    self.dispatch(decision)
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
    /// re-arm the tap on wake). Returns false when the tap could not be
    /// recreated, so the caller can fall back to retrying.
    @discardableResult
    func rearm() -> Bool {
        stop()
        return start()
    }

    /// Stops listening while the app itself needs the raw keyboard — recording
    /// a new binding, where holding the current hotkey would otherwise start a
    /// real dictation behind the recorder sheet. `resume()` restores exactly
    /// the previous state, armed or not.
    func suspend() {
        wasArmedBeforeSuspend = machine != nil
        stop()
    }

    func resume() {
        guard wasArmedBeforeSuspend else { return }
        wasArmedBeforeSuspend = false
        _ = start()
    }

    /// Switch the hotkey; rebuilds the tap machine when one is running.
    func updateSpec(_ newSpec: HotkeySpec) {
        guard newSpec != spec else {
            return
        }
        spec = newSpec
        if machine != nil {
            rearm()
        }
    }

    private func dispatch(_ decision: HotkeyDecisionCore.Decision) {
        switch decision {
        case .pressBegan:
            onPressBegan?()
        case .pressEnded:
            onPressEnded?()
        case .cancelled:
            onCancel?()
        case .lockToggled:
            onLockToggle?()
        }
    }
}

/// C callback for the event tap — runs on the tap thread. It must not capture
/// context; the machine arrives via `userInfo` (Unmanaged, docs/03 §3.1).
///
/// Returning nil swallows the event. That happens only for a keyed binding's own
/// press and release: otherwise holding ⌥Space to talk would also type a
/// non-breaking space into the document. Modifier-only bindings are never
/// swallowed — the Globe action fires below the tap regardless, and chord-abort
/// needs to see the keyDown that follows.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let machine = Unmanaged<HotkeyTapMachine>.fromOpaque(userInfo).takeUnretainedValue()
    let consumed = machine.handle(type: type, event: event)
    return consumed ? nil : Unmanaged.passUnretained(event)
}

/// CGEventTap plumbing around a `HotkeyDecisionCore`. Single-use: one
/// `startTap()` per instance; `HotkeyMonitor` builds a fresh machine per start.
///
/// Thread model: the C callback is the only reader/writer of the decision core,
/// and the dedicated tap thread's run loop services events serially, so that
/// state is thread-confined. `runLoop` is the one cross-thread field and is
/// guarded by `stateLock`. `eventTap`/`runLoopSource` are written before the
/// tap thread starts (`Thread.start()` is the happens-before edge) and never
/// mutated afterwards. `@unchecked Sendable` because the compiler cannot see
/// this confinement.
private final class HotkeyTapMachine: @unchecked Sendable {

    private let sink: @Sendable (HotkeyDecisionCore.Decision) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?

    private let stateLock = NSLock()
    /// Published by the tap thread at startup, consumed by `stopTap()`.
    private var runLoop: CFRunLoop?

    /// Press state — tap-thread-confined. All timings use systemUptime
    /// (docs/03 §3.1: 50 ms debounce on systemUptime).
    private var core: HotkeyDecisionCore

    init(
        spec: HotkeySpec,
        sink: @escaping @Sendable (HotkeyDecisionCore.Decision) -> Void
    ) {
        self.core = HotkeyDecisionCore(spec: spec)
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
        _ = ready.wait(timeout: .now() + .seconds(2))
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

    /// Returns true when the event must be swallowed instead of forwarded.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard let coreEvent = makeCoreEvent(type: type, event: event) else {
            return false
        }
        let outcome = core.handle(coreEvent)
        if let decision = outcome.decision {
            sink(decision)
        }
        return outcome.consumesEvent
    }

    /// Translates a CGEvent into the core's value type, and performs the one
    /// side effect the core must not own: re-enabling a force-disabled tap.
    /// Returns nil for event types outside the tap's mask.
    private func makeCoreEvent(type: CGEventType, event: CGEvent) -> HotkeyDecisionCore.Event? {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable only from inside the callback (docs/03 §3.1). Never poll
            // CGEventTapIsEnabled from outside — documented IPC-voucher leak that
            // kernel-panics macOS 26.5.2 (docs/03 §3.1).
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return HotkeyDecisionCore.Event(kind: .tapDisabled, timestamp: now)
        case .keyDown, .keyUp, .flagsChanged:
            return HotkeyDecisionCore.Event(
                kind: Self.eventKind(for: type),
                keyCode: UInt16(
                    truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)
                ),
                flags: event.flags.rawValue,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                timestamp: now
            )
        default:
            return nil
        }
    }

    private static func eventKind(for type: CGEventType) -> HotkeyDecisionCore.EventKind {
        switch type {
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        default: return .flagsChanged
        }
    }
}
