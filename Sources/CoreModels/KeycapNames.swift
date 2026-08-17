import Foundation

/// keyCode → keycap text, and the composition rules that turn a hotkey binding
/// into the string shown in menus and the HUD ("🌐 Fn", "Right ⌘", "⌥Space").
///
/// Deliberately a static table rather than a `UCKeyTranslate` lookup: the label
/// must be stable across input-source switches (a binding recorded on a Dvorak
/// layout should not re-read as a different letter under Pinyin), and the table
/// is pure, so it is unit-tested on Linux alongside the rest of the hotkey model.
/// Unknown codes degrade to "Key #n" instead of vanishing.
public enum KeycapNames {

    /// Symbol for a modifier key, side included — the left/right distinction is
    /// the whole point of the modifier presets (docs/13 §2).
    public static func modifierName(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case HotkeyKeyCode.function: return "🌐 Fn"
        case HotkeyKeyCode.leftCommand: return "Left ⌘"
        case HotkeyKeyCode.rightCommand: return "Right ⌘"
        case HotkeyKeyCode.leftShift: return "Left ⇧"
        case HotkeyKeyCode.rightShift: return "Right ⇧"
        case HotkeyKeyCode.leftOption: return "Left ⌥"
        case HotkeyKeyCode.rightOption: return "Right ⌥"
        case HotkeyKeyCode.leftControl: return "Left ⌃"
        case HotkeyKeyCode.rightControl: return "Right ⌃"
        case HotkeyKeyCode.capsLock: return "Caps Lock"
        default: return nil
        }
    }

    /// Keycap text for a non-modifier key, e.g. "Space", "F13", "A", "←".
    public static func keyName(forKeyCode keyCode: UInt16) -> String {
        table[keyCode] ?? "Key #\(keyCode)"
    }

    /// Modifier symbols in Apple's canonical order (🌐⌃⌥⇧⌘), for the bits set
    /// in `flags`. Returns "" when no modifier is required.
    public static func modifierSymbols(for flags: UInt64) -> String {
        var symbols = ""
        if flags & HotkeyFlagMask.function != 0 { symbols += "🌐" }
        if flags & HotkeyFlagMask.control != 0 { symbols += "⌃" }
        if flags & HotkeyFlagMask.option != 0 { symbols += "⌥" }
        if flags & HotkeyFlagMask.shift != 0 { symbols += "⇧" }
        if flags & HotkeyFlagMask.command != 0 { symbols += "⌘" }
        return symbols
    }

    /// The display string for a binding. Computed once at record time and then
    /// persisted with the spec, so the UI never re-derives it (docs/13 §3).
    public static func label(for kind: HotkeySpec.Kind) -> String {
        switch kind {
        case .modifierOnly(let keyCode, _):
            return modifierName(forKeyCode: keyCode) ?? keyName(forKeyCode: keyCode)
        case .key(let keyCode, let requiredFlags):
            return modifierSymbols(for: requiredFlags) + keyName(forKeyCode: keyCode)
        }
    }

    // MARK: - Table

    /// ANSI-layout virtual keycodes. Letters and digits are named by their
    /// US-layout legend; that is what the physical keycap says on the keyboards
    /// this app is built for, and it never shifts under the user's feet.
    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear",
        75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -", 79: "F18", 80: "F19",
        81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20",
        91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
