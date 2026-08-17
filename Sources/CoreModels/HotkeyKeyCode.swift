import Foundation

/// Virtual keycodes for the push-to-talk hotkey, spelled out as plain integers.
///
/// The values mirror Carbon's `kVK_*` constants. Carbon and CoreGraphics are
/// Apple-only, and the hotkey model plus its decision core must stay pure so
/// they compile and are unit-tested on Linux CI (docs/13 §4). The app layer
/// feeds raw `CGEvent` keycode fields straight in — no conversion table is
/// needed because the numbers are identical by construction.
public enum HotkeyKeyCode {

    // MARK: - Modifiers

    public static let leftCommand: UInt16 = 55
    public static let rightCommand: UInt16 = 54
    public static let leftShift: UInt16 = 56
    public static let rightShift: UInt16 = 60
    public static let leftOption: UInt16 = 58
    public static let rightOption: UInt16 = 61
    public static let leftControl: UInt16 = 59
    public static let rightControl: UInt16 = 62
    /// The Fn / 🌐 Globe key (`kVK_Function`).
    public static let function: UInt16 = 63
    public static let capsLock: UInt16 = 57

    // MARK: - Keys referenced by rules

    public static let escape: UInt16 = 53
    public static let space: UInt16 = 49
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let f11: UInt16 = 103
    public static let f12: UInt16 = 111
    public static let f13: UInt16 = 105
    public static let f14: UInt16 = 107
    public static let f15: UInt16 = 113

    // MARK: - Classification

    /// Every modifier key, including Caps Lock (which is recognised so the
    /// recorder can reject it explicitly rather than mistaking it for a key).
    public static let modifierKeyCodes: Set<UInt16> = [
        leftCommand, rightCommand, leftShift, rightShift,
        leftOption, rightOption, leftControl, rightControl,
        function, capsLock,
    ]

    /// The flag bit a modifier key raises while held, or `nil` when the code is
    /// not a bindable modifier. Caps Lock is deliberately absent: macOS reports
    /// it as a latching toggle, not a held modifier, so it cannot drive
    /// push-to-talk edges.
    public static func modifierFlagMask(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case leftCommand, rightCommand: return HotkeyFlagMask.command
        case leftShift, rightShift: return HotkeyFlagMask.shift
        case leftOption, rightOption: return HotkeyFlagMask.option
        case leftControl, rightControl: return HotkeyFlagMask.control
        case function: return HotkeyFlagMask.function
        default: return nil
        }
    }

    /// The device-specific bit a modifier key raises *in addition to* the shared
    /// one (IOKit's `NX_DEVICE*KEYMASK`), or 0 when there is no side to
    /// distinguish (Fn) or the code is not a modifier.
    ///
    /// This is what tells Left ⇧ apart from Right ⇧ mid-press: the shared shift
    /// bit stays set while either key is down, so a release edge is invisible
    /// without it (docs/03 §3.1 left-vs-right caveat).
    public static func deviceFlagMask(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case leftControl: return 0x0000_0001
        case leftShift: return 0x0000_0002
        case rightShift: return 0x0000_0004
        case leftCommand: return 0x0000_0008
        case rightCommand: return 0x0000_0010
        case leftOption: return 0x0000_0020
        case rightOption: return 0x0000_0040
        case rightControl: return 0x0000_2000
        default: return 0
        }
    }

    public static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    /// Arrow and F1–F12 keycodes. macOS latches `.maskSecondaryFn` onto their
    /// events, so a `flagsChanged` carrying one of these keycodes is never an Fn
    /// edge (docs/03 §3.1: strip `.function` from F-key/arrow events before
    /// matching). Extracted verbatim from the pre-refactor monitor.
    public static let fnLatchingKeyCodes: Set<UInt16> =
        arrowKeyCodes.union([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111])

    /// Keys whose *own* events may carry a latched `.function` bit depending on
    /// the keyboard: the arrows plus the whole F1–F20 range. A keyed binding on
    /// one of these never requires Fn, so external keyboards that do (or do not)
    /// latch the bit behave identically (docs/13 §4).
    public static let functionAndArrowKeyCodes: Set<UInt16> =
        fnLatchingKeyCodes.union([105, 107, 113, 106, 64, 79, 80, 90])  // F13…F20

    /// Keys that neither insert text nor edit it, so they are safe to bind with
    /// no modifier at all (docs/13 §2 validation).
    public static let nonTypingKeyCodes: Set<UInt16> =
        functionAndArrowKeyCodes.union([
            115,  // Home
            119,  // End
            116,  // Page Up
            121,  // Page Down
            114,  // Help
        ])

    /// Modifiers a touch typist holds constantly — the left-hand cluster, and
    /// both Shifts for capitals. Bindable, but they arm on ordinary typing, so
    /// the UI says so (docs/13 §2).
    public static let typingHandModifierKeyCodes: Set<UInt16> = [
        leftCommand, leftOption, leftControl, leftShift, rightShift,
    ]

    public static func isModifier(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    /// True when binding the key on its own would swallow ordinary typing or
    /// editing — letters, digits, punctuation, Space, Tab, Return and both
    /// Delete keys (docs/13 §2). Such keys are only bindable in a chord.
    public static func requiresModifier(_ keyCode: UInt16) -> Bool {
        !isModifier(keyCode) && keyCode != escape && !nonTypingKeyCodes.contains(keyCode)
    }
}

/// Event-flag bits, mirroring `CGEventFlags` (and `NSEvent.ModifierFlags`,
/// which uses the same bit positions). Declared here so the pure hotkey layer
/// never imports CoreGraphics — see `HotkeyKeyCode` for the same rationale.
public enum HotkeyFlagMask {

    public static let capsLock: UInt64 = 1 << 16
    public static let shift: UInt64 = 1 << 17
    public static let control: UInt64 = 1 << 18
    public static let option: UInt64 = 1 << 19
    public static let command: UInt64 = 1 << 20
    public static let numericPad: UInt64 = 1 << 21
    public static let help: UInt64 = 1 << 22
    /// `CGEventFlags.maskSecondaryFn` / `NSEvent.ModifierFlags.function`.
    public static let function: UInt64 = 1 << 23

    /// The only bits a hotkey may require. Everything else — Caps Lock, the
    /// numeric-pad bit, the device-dependent left/right bits, and the
    /// non-coalesced bit — is noise for matching purposes and is masked away.
    public static let significant: UInt64 = shift | control | option | command | function

    /// Reduces raw event flags to the bits a binding may require.
    ///
    /// Beyond dropping the noise bits, this strips `.function` for the arrows
    /// and the F-key range: macOS latches that bit onto their events on some
    /// keyboards and not others, so requiring it would make an F13 binding work
    /// on one keyboard and silently fail on the next.
    public static func normalized(_ flags: UInt64, forKeyCode keyCode: UInt16) -> UInt64 {
        var result = flags & significant
        if HotkeyKeyCode.functionAndArrowKeyCodes.contains(keyCode) {
            result &= ~function
        }
        return result
    }
}
