import CoreModels
import Foundation
import Testing

@testable import SessionKit

/// Sequence tests for the push-to-talk state machine (docs/13 §4).
///
/// These are written against the semantics the monitor shipped with — hold,
/// tap, double-tap lock, chord abort, Escape, debounce, synthetic release —
/// so the extraction out of `HotkeyMonitor` is provably behaviour-preserving,
/// and so the timing rules stop being field-tested only.

// MARK: - Driver

/// Feeds events into a core on a fake clock. `send` returns the decision, so a
/// test reads as the sequence a user performs.
private struct Driver {
    private var core: HotkeyDecisionCore
    private(set) var now: TimeInterval = 100

    init(spec: HotkeySpec, timings: HotkeyDecisionCore.Timings = .default) {
        core = HotkeyDecisionCore(spec: spec, timings: timings)
    }

    var isPressed: Bool { core.isPressed }

    mutating func advance(_ seconds: TimeInterval) {
        now += seconds
    }

    mutating func send(
        _ kind: HotkeyDecisionCore.EventKind,
        keyCode: UInt16 = 0,
        flags: UInt64 = 0,
        isRepeat: Bool = false
    ) -> HotkeyDecisionCore.Decision? {
        core.handle(
            HotkeyDecisionCore.Event(
                kind: kind,
                keyCode: keyCode,
                flags: flags,
                isRepeat: isRepeat,
                timestamp: now
            )
        )
    }

    /// Fn / Globe down edge.
    mutating func fnDown() -> HotkeyDecisionCore.Decision? {
        send(.flagsChanged, keyCode: HotkeyKeyCode.function, flags: HotkeyFlagMask.function)
    }

    /// Fn / Globe up edge.
    mutating func fnUp() -> HotkeyDecisionCore.Decision? {
        send(.flagsChanged, keyCode: HotkeyKeyCode.function, flags: 0)
    }

    /// Presses whatever the spec binds, the way the hardware would report it.
    mutating func press(_ spec: HotkeySpec) -> HotkeyDecisionCore.Decision? {
        switch spec.kind {
        case .modifierOnly(let keyCode, let flagMask):
            return send(.flagsChanged, keyCode: keyCode, flags: flagMask | deviceNoise)
        case .key(let keyCode, let requiredFlags):
            return send(.keyDown, keyCode: keyCode, flags: requiredFlags | deviceNoise)
        }
    }

    mutating func release(_ spec: HotkeySpec) -> HotkeyDecisionCore.Decision? {
        switch spec.kind {
        case .modifierOnly(let keyCode, _):
            return send(.flagsChanged, keyCode: keyCode, flags: 0)
        case .key(let keyCode, _):
            return send(.keyUp, keyCode: keyCode)
        }
    }
}

/// Bits a real CGEvent carries alongside the modifiers: the non-coalesced bit
/// and the device-dependent left/right bits. Matching must ignore them.
private let deviceNoise: UInt64 = 0x100 | 0x20

private let cKey: UInt16 = 8
private let aKey: UInt16 = 0

// MARK: - Modifier-only: press semantics

@Test func holdBeyondThresholdBeginsAndEndsAPress() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    #expect(driver.isPressed)
    driver.advance(0.6)
    #expect(driver.fnUp() == .pressEnded)
    #expect(!driver.isPressed)
}

@Test func shortTapEndsThePressSoTheSpeechOverrideCanDecide() {
    // FR-1.5: a sub-500 ms take is reported as ended, not cancelled — the
    // has-speech heuristic in SessionKit is what discards it.
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.2)
    #expect(driver.fnUp() == .pressEnded)
}

@Test func doubleTapTogglesTheHandsFreeLock() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.1)
    #expect(driver.fnUp() == .pressEnded)
    driver.advance(0.1)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.1)
    #expect(driver.fnUp() == .lockToggled)
}

@Test func secondTapOutsideTheWindowIsJustAnotherTap() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.1)
    #expect(driver.fnUp() == .pressEnded)
    driver.advance(0.5)  // past the 0.35 s double-tap window
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.1)
    #expect(driver.fnUp() == .pressEnded)
}

@Test func aThirdTapDoesNotChainOffTheLockToggle() {
    // The lock toggle consumes the pairing, so tap-tap-tap is lock then a
    // plain tap, never two locks.
    var driver = Driver(spec: .fnGlobe)
    _ = driver.fnDown()
    driver.advance(0.1)
    _ = driver.fnUp()
    driver.advance(0.1)
    _ = driver.fnDown()
    driver.advance(0.1)
    #expect(driver.fnUp() == .lockToggled)
    driver.advance(0.1)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.1)
    #expect(driver.fnUp() == .pressEnded)
}

@Test func holdIsNeverUpgradedToALock() {
    var driver = Driver(spec: .fnGlobe)
    _ = driver.fnDown()
    driver.advance(0.1)
    #expect(driver.fnUp() == .pressEnded)
    driver.advance(0.1)
    _ = driver.fnDown()
    driver.advance(0.6)  // held long enough to be push-to-talk
    #expect(driver.fnUp() == .pressEnded)
}

// MARK: - Modifier-only: aborts and hygiene

@Test func anotherKeyWithinTheChordWindowAbortsBeforeStart() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.2)
    #expect(driver.send(.keyDown, keyCode: cKey, flags: HotkeyFlagMask.function) == .cancelled)
    #expect(!driver.isPressed)
    // The trailing up edge of the aborted press must stay silent.
    driver.advance(0.1)
    #expect(driver.fnUp() == nil)
}

@Test func aKeyPressedLongAfterTheChordWindowDoesNotAbort() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(1.5)
    #expect(driver.send(.keyDown, keyCode: cKey, flags: HotkeyFlagMask.function) == nil)
    driver.advance(0.1)
    #expect(driver.fnUp() == .pressEnded)
}

@Test func escapeCancelsAnEstablishedRecording() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(3.0)  // well past the chord-abort window
    #expect(driver.send(.keyDown, keyCode: HotkeyKeyCode.escape) == .cancelled)
}

@Test func escapeWithNoPressIsIgnored() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.send(.keyDown, keyCode: HotkeyKeyCode.escape) == nil)
}

@Test func arrowAndFunctionKeysNeverCountAsFnEdges() {
    // macOS latches .maskSecondaryFn onto arrow/F-key events (docs/03 §3.1).
    var driver = Driver(spec: .fnGlobe)
    for keyCode in HotkeyKeyCode.fnLatchingKeyCodes.sorted() {
        #expect(driver.send(.flagsChanged, keyCode: keyCode, flags: HotkeyFlagMask.function) == nil)
    }
    #expect(!driver.isPressed)
}

@Test func edgesFromOtherModifiersAreIgnored() {
    var driver = Driver(spec: .fnGlobe)
    #expect(
        driver.send(
            .flagsChanged,
            keyCode: HotkeyKeyCode.rightCommand,
            flags: HotkeyFlagMask.command
        ) == nil
    )
}

@Test func sameDirectionEdgesAreDebounced() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.01)
    #expect(driver.fnDown() == nil)
    driver.advance(0.6)
    #expect(driver.fnUp() == .pressEnded)
    driver.advance(0.01)
    #expect(driver.fnUp() == nil)
}

@Test func aDisabledTapSynthesizesTheMissedRelease() {
    var driver = Driver(spec: .fnGlobe)
    #expect(driver.send(.tapDisabled) == nil)
    #expect(driver.fnDown() == .pressBegan)
    driver.advance(0.2)
    #expect(driver.send(.tapDisabled) == .pressEnded)
    #expect(!driver.isPressed)
    driver.advance(0.1)
    #expect(driver.fnUp() == nil)
}

@Test func rightCommandPresetMatchesItsOwnKeyCode() {
    var driver = Driver(spec: .rightCommand)
    #expect(
        driver.send(
            .flagsChanged,
            keyCode: HotkeyKeyCode.leftCommand,
            flags: HotkeyFlagMask.command
        ) == nil
    )
    #expect(
        driver.send(
            .flagsChanged,
            keyCode: HotkeyKeyCode.rightCommand,
            flags: HotkeyFlagMask.command | deviceNoise
        ) == .pressBegan
    )
    driver.advance(0.6)
    #expect(
        driver.send(.flagsChanged, keyCode: HotkeyKeyCode.rightCommand, flags: 0) == .pressEnded
    )
}

// MARK: - Keyed bindings

private let optionSpace = HotkeySpec(
    kind: .key(keyCode: HotkeyKeyCode.space, requiredFlags: HotkeyFlagMask.option)
)
private let f13 = HotkeySpec(kind: .key(keyCode: HotkeyKeyCode.f13, requiredFlags: 0))

@Test func keyedChordHoldsAndReleasesOnItsOwnKey() {
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(
            .keyDown,
            keyCode: HotkeyKeyCode.space,
            flags: HotkeyFlagMask.option | deviceNoise
        ) == .pressBegan
    )
    driver.advance(0.6)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.space) == .pressEnded)
}

@Test func keyedChordRequiresAnExactModifierMatch() {
    var driver = Driver(spec: optionSpace)
    // Extra modifier held: the user is pressing ⌃⌥Space, a different shortcut.
    #expect(
        driver.send(
            .keyDown,
            keyCode: HotkeyKeyCode.space,
            flags: HotkeyFlagMask.option | HotkeyFlagMask.control
        ) == nil
    )
    // Modifier missing: plain Space must keep typing a space.
    #expect(driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: 0) == nil)
    #expect(!driver.isPressed)
}

@Test func capsLockDoesNotBreakAKeyedMatch() {
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(
            .keyDown,
            keyCode: HotkeyKeyCode.space,
            flags: HotkeyFlagMask.option | HotkeyFlagMask.capsLock | HotkeyFlagMask.numericPad
        ) == .pressBegan
    )
}

@Test func releasingTheModifierFirstEndsThePress() {
    // Release order is the user's business: whichever half lifts first ends the
    // take, and the trailing event is swallowed by the debounce (docs/13 §4).
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: HotkeyFlagMask.option)
            == .pressBegan
    )
    driver.advance(0.6)
    #expect(driver.send(.flagsChanged, keyCode: HotkeyKeyCode.leftOption, flags: 0) == .pressEnded)
    driver.advance(0.01)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.space) == nil)
}

@Test func autorepeatDoesNotRetriggerAKeyedPress() {
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: HotkeyFlagMask.option)
            == .pressBegan
    )
    driver.advance(0.3)
    #expect(
        driver.send(
            .keyDown,
            keyCode: HotkeyKeyCode.space,
            flags: HotkeyFlagMask.option,
            isRepeat: true
        ) == nil
    )
    driver.advance(0.3)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.space) == .pressEnded)
}

@Test func keyedBindingsHaveNoChordAbort() {
    // The chord IS the binding — typing during it is typing, not an abort.
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: HotkeyFlagMask.option)
            == .pressBegan
    )
    driver.advance(0.2)
    #expect(driver.send(.keyDown, keyCode: aKey, flags: HotkeyFlagMask.option) == nil)
    #expect(driver.isPressed)
    driver.advance(0.5)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.space) == .pressEnded)
}

@Test func escapeStillCancelsAKeyedPress() {
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: HotkeyFlagMask.option)
            == .pressBegan
    )
    driver.advance(0.2)
    #expect(driver.send(.keyDown, keyCode: HotkeyKeyCode.escape) == .cancelled)
}

@Test func unrelatedKeyUpsAreIgnoredWhileHolding() {
    var driver = Driver(spec: optionSpace)
    _ = driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: HotkeyFlagMask.option)
    driver.advance(0.2)
    #expect(driver.send(.keyUp, keyCode: aKey) == nil)
    #expect(driver.isPressed)
}

@Test func functionKeyBindingIgnoresALatchedFnBit() {
    // Some keyboards latch .maskSecondaryFn onto F-key events and some do not;
    // an F13 binding must work on both (docs/13 §4).
    var driver = Driver(spec: f13)
    #expect(
        driver.send(
            .keyDown,
            keyCode: HotkeyKeyCode.f13,
            flags: HotkeyFlagMask.function | deviceNoise
        ) == .pressBegan
    )
    driver.advance(0.6)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.f13) == .pressEnded)
}

@Test func functionKeyBindingDoubleTapsToLock() {
    var driver = Driver(spec: f13)
    #expect(driver.send(.keyDown, keyCode: HotkeyKeyCode.f13) == .pressBegan)
    driver.advance(0.1)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.f13) == .pressEnded)
    driver.advance(0.1)
    #expect(driver.send(.keyDown, keyCode: HotkeyKeyCode.f13) == .pressBegan)
    driver.advance(0.1)
    #expect(driver.send(.keyUp, keyCode: HotkeyKeyCode.f13) == .lockToggled)
}

@Test func aDisabledTapAlsoReleasesAKeyedPress() {
    var driver = Driver(spec: optionSpace)
    _ = driver.send(.keyDown, keyCode: HotkeyKeyCode.space, flags: HotkeyFlagMask.option)
    driver.advance(0.2)
    #expect(driver.send(.tapDisabled) == .pressEnded)
}

@Test func modifierEdgesBeforeAKeyedPressAreIgnored() {
    var driver = Driver(spec: optionSpace)
    #expect(
        driver.send(
            .flagsChanged,
            keyCode: HotkeyKeyCode.leftOption,
            flags: HotkeyFlagMask.option
        ) == nil
    )
    #expect(!driver.isPressed)
}

// MARK: - Every preset drives the same press vocabulary

@Test func everyPresetHoldsAndDoubleTapLocks() {
    for spec in HotkeySpec.presets {
        var driver = Driver(spec: spec)
        #expect(driver.press(spec) == .pressBegan, "hold began: \(spec.label)")
        driver.advance(0.6)
        #expect(driver.release(spec) == .pressEnded, "hold ended: \(spec.label)")

        driver.advance(0.5)
        _ = driver.press(spec)
        driver.advance(0.1)
        #expect(driver.release(spec) == .pressEnded, "first tap: \(spec.label)")
        driver.advance(0.1)
        _ = driver.press(spec)
        driver.advance(0.1)
        #expect(driver.release(spec) == .lockToggled, "double tap: \(spec.label)")
    }
}
