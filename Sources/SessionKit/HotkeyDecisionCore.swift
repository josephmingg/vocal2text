import CoreModels
import Foundation

/// The push-to-talk press state machine, as pure values.
///
/// Everything the hotkey does that a user can feel lives here — the 0.5 s tap
/// threshold, the 0.35 s double-tap lock, the ~1 s chord abort, the 50 ms
/// debounce, the Escape cancel, the synthetic release when the event tap is
/// force-disabled (docs/03 §3.1, FR-1.3/FR-1.5/FR-1.6). `HotkeyMonitor` in the
/// macOS app keeps only the `CGEventTap` plumbing and feeds events in here, so
/// the semantics are regression-tested on Linux CI instead of by hand
/// (docs/13 §4).
///
/// Not thread-safe by design: the monitor confines one instance to its tap
/// thread, whose run loop services events serially.
public struct HotkeyDecisionCore: Sendable {

    /// What the monitor should do about an event. `nil` from `handle` means
    /// "nothing" — the overwhelmingly common case.
    public enum Decision: Sendable, Hashable {
        /// Hotkey down edge: pre-arm the session (docs/03 §2).
        case pressBegan
        /// Release after a hold, a short tap (SessionKit applies the FR-1.5
        /// has-speech override), or a synthetic release after tap interruption.
        case pressEnded
        /// Second tap of a double-tap: hands-free lock toggle (FR-1.3).
        case lockToggled
        /// Chord abort or Escape while holding (FR-1.6).
        case cancelled
    }

    /// What the monitor does with one event: act on it, swallow it, or both.
    public struct Outcome: Sendable, Hashable {
        public var decision: Decision?
        /// True when the event is the binding's own key press or release and
        /// must not reach the rest of the system — otherwise ⌥Space would type
        /// a non-breaking space into the document you are dictating into.
        ///
        /// Only keyed bindings consume. A modifier-only binding must pass
        /// through: the Globe action fires below the tap and cannot be
        /// suppressed anyway (docs/03 §3.1), and chord-abort depends on seeing
        /// the keyDown that follows.
        public var consumesEvent: Bool

        public init(decision: Decision? = nil, consumesEvent: Bool = false) {
            self.decision = decision
            self.consumesEvent = consumesEvent
        }
    }

    public enum EventKind: Sendable, Hashable {
        case keyDown
        case keyUp
        case flagsChanged
        /// The tap was disabled by timeout or user input: edges were missed.
        case tapDisabled
    }

    /// One keyboard event, reduced to the fields matching depends on.
    public struct Event: Sendable, Hashable {
        public var kind: EventKind
        public var keyCode: UInt16
        /// Raw event flags; normalization happens inside the core.
        public var flags: UInt64
        /// Autorepeat `keyDown`s never re-trigger a press.
        public var isRepeat: Bool
        /// Monotonic clock (the monitor passes `systemUptime`, docs/03 §3.1).
        public var timestamp: TimeInterval

        public init(
            kind: EventKind,
            keyCode: UInt16 = 0,
            flags: UInt64 = 0,
            isRepeat: Bool = false,
            timestamp: TimeInterval
        ) {
            self.kind = kind
            self.keyCode = keyCode
            self.flags = flags
            self.isRepeat = isRepeat
            self.timestamp = timestamp
        }
    }

    /// The press-semantics constants, injectable so tests can read as sequences
    /// of intent rather than sleeps. Defaults are the shipping values.
    public struct Timings: Sendable, Hashable {
        /// Same-direction edge debounce (docs/03 §3.1).
        public var debounce: TimeInterval
        /// A hold shorter than this is a tap, not push-to-talk (FR-1.5).
        public var hold: TimeInterval
        /// Two down-edges within this window = double-tap → lock (FR-1.3).
        public var doubleTap: TimeInterval
        /// Another keyDown this soon after a modifier-only down-edge = chord →
        /// abort-before-start (docs/03 §3.1).
        public var chordAbort: TimeInterval

        public init(
            debounce: TimeInterval = 0.050,
            hold: TimeInterval = 0.5,
            doubleTap: TimeInterval = 0.35,
            chordAbort: TimeInterval = 1.0
        ) {
            self.debounce = debounce
            self.hold = hold
            self.doubleTap = doubleTap
            self.chordAbort = chordAbort
        }

        public static let `default` = Timings()
    }

    private let spec: HotkeySpec
    private let timings: Timings

    public private(set) var isPressed = false
    private var pressStartTime: TimeInterval = 0
    /// The device-specific bit observed on the current press's down edge, or 0
    /// when the hardware did not report one. Self-calibrating on purpose: a
    /// keyboard that reports the bits gets left/right release detection, and one
    /// that does not falls back to the shared-bit behaviour rather than losing
    /// the binding entirely.
    private var pressDeviceFlagMask: UInt64 = 0
    /// True while a keyed binding's `keyDown` has been swallowed, so its
    /// matching `keyUp` is swallowed too and no app sees a half chord.
    private var isConsumingKey = false
    /// Down-edge time of the last short tap; a second down-edge within
    /// `timings.doubleTap` of it upgrades the pair to a lock toggle (FR-1.3).
    private var lastShortTapDownTime: TimeInterval?
    private var lastDownEdgeTime: TimeInterval = -1
    private var lastUpEdgeTime: TimeInterval = -1

    public init(spec: HotkeySpec, timings: Timings = .default) {
        self.spec = spec
        self.timings = timings
    }

    // MARK: - Event intake

    public mutating func handle(_ event: Event) -> Outcome {
        switch event.kind {
        case .tapDisabled:
            isConsumingKey = false
            return Outcome(decision: handleTapDisabled())
        case .flagsChanged:
            return Outcome(decision: handleFlagsChanged(event))
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        }
    }

    private func matchesModifierOnly(_ event: Event, keyCode: UInt16) -> Bool {
        // Arrow/F-key events latch `.maskSecondaryFn` — never Fn edges
        // (docs/03 §3.1). Their synthesized Fn sandwich around a real keyDown
        // is caught by the chord abort instead.
        guard !HotkeyKeyCode.fnLatchingKeyCodes.contains(event.keyCode) else { return false }
        return event.keyCode == keyCode
    }

    private mutating func handleFlagsChanged(_ event: Event) -> Decision? {
        switch spec.kind {
        case .modifierOnly(let keyCode, let flagMask):
            guard matchesModifierOnly(event, keyCode: keyCode) else { return nil }
            if isPressed {
                // Still held? Left and right share one flag bit, so while the
                // twin key is down the shared bit stays set through our key's
                // release — check the device-specific bit when the hardware
                // reported one on the down edge, or the recording never stops.
                let heldMask = pressDeviceFlagMask != 0 ? pressDeviceFlagMask : flagMask
                guard event.flags & heldMask != heldMask else { return nil }
                return upEdge(at: event.timestamp)
            }
            guard event.flags & flagMask == flagMask else {
                // A stray up edge: no press to end, but the debounce clock is
                // still advanced, exactly as the pre-refactor monitor did.
                return upEdge(at: event.timestamp)
            }
            let deviceMask = HotkeyKeyCode.deviceFlagMask(for: keyCode)
            let decision = downEdge(at: event.timestamp)
            if decision != nil {
                pressDeviceFlagMask = event.flags & deviceMask != 0 ? deviceMask : 0
            }
            return decision
        case .key(let keyCode, let requiredFlags):
            // Releasing one of the chord's modifiers before the key itself ends
            // the press — it is a release, not a cancel (docs/13 §4).
            guard isPressed, requiredFlags != 0 else { return nil }
            // Normalized the same way the binding was recorded, so the two
            // sides of the comparison always agree.
            let held = HotkeyFlagMask.normalized(event.flags, forKeyCode: keyCode)
            guard held & requiredFlags != requiredFlags else { return nil }
            return upEdge(at: event.timestamp)
        }
    }

    private mutating func handleKeyDown(_ event: Event) -> Outcome {
        if case .key(let keyCode, let requiredFlags) = spec.kind,
            event.keyCode == keyCode,
            HotkeyFlagMask.normalized(event.flags, forKeyCode: keyCode) == requiredFlags {
            // The binding's own press — swallow it, including the autorepeats
            // that arrive while the user holds it to talk.
            isConsumingKey = true
            let decision = event.isRepeat ? nil : downEdge(at: event.timestamp)
            return Outcome(decision: decision, consumesEvent: true)
        }
        guard isPressed else { return Outcome() }
        if event.keyCode == HotkeyKeyCode.escape {
            // Escape cancels an active press at any time (docs/03 §3.1), and
            // passes through so it keeps doing its normal job as well.
            return Outcome(decision: abortActivePress())
        }
        guard case .modifierOnly = spec.kind else {
            // A keyed binding is itself a chord; other keys pressed during it
            // are the user typing, not aborting (docs/13 §4).
            return Outcome()
        }
        if event.timestamp - pressStartTime < timings.chordAbort {
            // Chord (e.g. Fn+arrow, right-⌘+C): the user wanted a shortcut, not
            // dictation → abort-before-start (docs/03 §3.1). The event itself
            // passes through untouched — a modifier binding never swallows.
            return Outcome(decision: abortActivePress())
        }
        return Outcome()
    }

    private mutating func handleKeyUp(_ event: Event) -> Outcome {
        guard case .key(let keyCode, _) = spec.kind, event.keyCode == keyCode else {
            return Outcome()
        }
        // Swallow the release of a press whose keyDown was swallowed, so no app
        // ever sees half of the chord.
        let consumes = isConsumingKey
        isConsumingKey = false
        guard isPressed else { return Outcome(consumesEvent: consumes) }
        return Outcome(decision: upEdge(at: event.timestamp), consumesEvent: consumes)
    }

    private mutating func handleTapDisabled() -> Decision? {
        // Edges were missed while disabled: a held press may have been released
        // unseen, so synthesize the release (docs/03 §3.1). Re-enabling the tap
        // is the monitor's job — it must happen inside the tap callback.
        guard isPressed else { return nil }
        isPressed = false
        lastShortTapDownTime = nil
        return .pressEnded
    }

    // MARK: - Press edges

    private mutating func abortActivePress() -> Decision {
        isPressed = false
        lastShortTapDownTime = nil
        return .cancelled
    }

    private mutating func downEdge(at now: TimeInterval) -> Decision? {
        if now - lastDownEdgeTime < timings.debounce {
            return nil
        }
        lastDownEdgeTime = now
        guard !isPressed else {
            return nil
        }
        isPressed = true
        pressStartTime = now
        return .pressBegan
    }

    private mutating func upEdge(at now: TimeInterval) -> Decision? {
        if now - lastUpEdgeTime < timings.debounce {
            return nil
        }
        lastUpEdgeTime = now
        guard isPressed else {
            return nil
        }
        isPressed = false
        let heldDuration = now - pressStartTime
        if heldDuration >= timings.hold {
            lastShortTapDownTime = nil
            return .pressEnded
        }
        if let previousTapDownTime = lastShortTapDownTime,
            pressStartTime - previousTapDownTime <= timings.doubleTap {
            // Second tap of a double-tap → hands-free lock toggle (FR-1.3).
            lastShortTapDownTime = nil
            return .lockToggled
        }
        // Short tap: report it as an ended press so SessionKit's FR-1.5
        // heuristic decides (a sub-500 ms take WITH speech transcribes; without
        // speech it discards silently — docs/03 §3.1). Routing it to cancel
        // would make the has-speech override a dead path.
        lastShortTapDownTime = pressStartTime
        return .pressEnded
    }
}
