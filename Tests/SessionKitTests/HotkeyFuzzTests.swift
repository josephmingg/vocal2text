import CoreModels
import Foundation
import Testing

@testable import SessionKit

/// Stress test (docs/17 §10): thousands of seeded, plausible key sequences —
/// holds, taps, double-taps, shortcuts, Escape, key bounce, a disabled tap —
/// fed through the real decision core, with the app's reaction to each
/// decision modelled exactly as `AppDelegate` wires it. After every gesture
/// the invariants a user feels must hold: the key is never stuck down, and
/// the microphone runs only during a hold or a hands-free take.

/// Deterministic RNG so a failure reproduces from its seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The app side of the hotkey: what AppDelegate + AppState do with decisions.
private struct AppModel {
    var recording = false
    var locked = false
    var takesEnded = 0
    var takesCancelled = 0

    mutating func apply(_ decision: HotkeyDecisionCore.Decision?) {
        switch decision {
        case nil:
            break
        case .pressBegan:
            if !locked { recording = true }
        case .pressEnded:
            locked = false
            if recording { takesEnded += 1 }
            recording = false
        case .shortTap:
            if recording { takesEnded += 1 }
            recording = false
        case .cancelled:
            locked = false
            if recording { takesCancelled += 1 }
            recording = false
        case .lockToggled:
            if locked {
                locked = false
                if recording { takesEnded += 1 }
                recording = false
            } else {
                // The second tap's down-edge already started the recording;
                // it now runs hands-free.
                locked = true
            }
        }
    }
}

private struct Simulator {
    var core: HotkeyDecisionCore
    var app = AppModel()
    var now: TimeInterval = 1_000
    let spec: HotkeySpec
    var log: [String] = []

    init(spec: HotkeySpec) {
        self.spec = spec
        core = HotkeyDecisionCore(spec: spec)
    }

    mutating func send(_ kind: HotkeyDecisionCore.EventKind, keyCode: UInt16 = 0, flags: UInt64 = 0) {
        let decision = core.handle(
            HotkeyDecisionCore.Event(kind: kind, keyCode: keyCode, flags: flags, timestamp: now)
        ).decision
        app.apply(decision)
    }

    mutating func wait(_ seconds: TimeInterval) { now += seconds }

    mutating func press() {
        switch spec.kind {
        case .modifierOnly(let keyCode, let flagMask):
            send(.flagsChanged, keyCode: keyCode, flags: flagMask)
        case .key(let keyCode, let requiredFlags):
            send(.keyDown, keyCode: keyCode, flags: requiredFlags)
        }
    }

    mutating func release() {
        switch spec.kind {
        case .modifierOnly(let keyCode, _):
            send(.flagsChanged, keyCode: keyCode, flags: 0)
        case .key(let keyCode, _):
            send(.keyUp, keyCode: keyCode)
        }
    }

    var heldFlags: UInt64 {
        switch spec.kind {
        case .modifierOnly(_, let flagMask): flagMask
        case .key(_, let requiredFlags): requiredFlags
        }
    }
}

private enum Gesture: CaseIterable {
    case hold, tap, doubleTap, shortcut, escapeWhileHolding, escapeAlone, bounce, tapDisabledMidHold, longPause
}

private let presets: [HotkeySpec] = [.fnGlobe, .rightCommand, .rightOption] + HotkeySpec.presets.filter {
    if case .key = $0.kind { return true }
    return false
}

@Test(arguments: presets)
func randomUserSessionsNeverLeaveTheMicStuck(spec: HotkeySpec) {
    for seed in UInt64(1)...UInt64(150) {
        var rng = SplitMix64(state: seed &* 7919)
        var sim = Simulator(spec: spec)
        for step in 0..<60 {
            let gesture = Gesture.allCases.randomElement(using: &rng)!
            let lockedBefore = sim.app.locked
            switch gesture {
            case .hold:
                sim.press()
                sim.wait(Double.random(in: 0.6...4, using: &rng))
                sim.release()
            case .tap:
                sim.press()
                sim.wait(Double.random(in: 0.06...0.3, using: &rng))
                sim.release()
            case .doubleTap:
                sim.press()
                sim.wait(Double.random(in: 0.06...0.12, using: &rng))
                sim.release()
                sim.wait(Double.random(in: 0.06...0.12, using: &rng))
                sim.press()
                sim.wait(Double.random(in: 0.06...0.12, using: &rng))
                sim.release()
            case .shortcut:
                sim.press()
                sim.wait(Double.random(in: 0.08...0.5, using: &rng))
                sim.send(.keyDown, keyCode: 48, flags: sim.heldFlags)  // Tab
                sim.wait(0.05)
                sim.send(.keyUp, keyCode: 48, flags: sim.heldFlags)
                sim.wait(Double.random(in: 0.05...0.3, using: &rng))
                sim.release()
            case .escapeWhileHolding:
                sim.press()
                sim.wait(Double.random(in: 0.6...2, using: &rng))
                sim.send(.keyDown, keyCode: HotkeyKeyCode.escape, flags: sim.heldFlags)
                sim.send(.keyUp, keyCode: HotkeyKeyCode.escape, flags: sim.heldFlags)
                sim.wait(0.1)
                sim.release()
            case .escapeAlone:
                sim.send(.keyDown, keyCode: HotkeyKeyCode.escape)
                sim.send(.keyUp, keyCode: HotkeyKeyCode.escape)
            case .bounce:
                // A worn switch: press, chatter, release.
                sim.press()
                sim.wait(0.01)
                sim.release()
                sim.wait(0.01)
                sim.press()
                sim.wait(Double.random(in: 0.6...1.5, using: &rng))
                sim.release()
            case .tapDisabledMidHold:
                sim.press()
                sim.wait(Double.random(in: 0.3...2, using: &rng))
                sim.send(.tapDisabled)
                sim.wait(0.2)
                sim.release()
            case .longPause:
                sim.wait(Double.random(in: 1...30, using: &rng))
            }
            // Let any double-tap window close before judging.
            sim.wait(1.0)
            let context = "spec \(spec.label) seed \(seed) step \(step) after \(gesture)"
            #expect(!sim.core.isPressed, "key stuck down — \(context)")
            #expect(!sim.app.recording || sim.app.locked, "mic running outside hands-free — \(context)")
            // Hands-free only ever begins with a double-tap.
            if !lockedBefore, sim.app.locked {
                #expect(gesture == .doubleTap, "lock entered without a double-tap — \(context)")
            }
            // A hold always ends a hands-free take, and Escape always discards it.
            if lockedBefore, gesture == .hold || gesture == .escapeAlone || gesture == .escapeWhileHolding {
                #expect(!sim.app.locked, "hands-free survived \(gesture) — \(context)")
            }
            // Leaving hands-free the way you entered it must leave it.
            if lockedBefore, gesture == .doubleTap {
                #expect(!sim.app.locked, "double-tap out of hands-free re-locked — \(context)")
            }
            // A shortcut must never end or discard a hands-free take.
            if lockedBefore, gesture == .shortcut, case .modifierOnly = spec.kind {
                #expect(sim.app.locked && sim.app.recording, "shortcut ended hands-free — \(context)")
            }
        }
    }
}
