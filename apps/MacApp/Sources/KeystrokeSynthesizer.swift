import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Synthesizes the keystrokes for the two active insertion tiers
/// (docs/03 §3.2): ⌘V for the paste path and layout-independent Unicode
/// typing for terminals / clipboard-free mode. Requires the Accessibility
/// grant the hotkey tap already holds (docs/03 §3.1).
enum KeystrokeSynthesizer {

    /// ⌘-down → V-down → V-up → ⌘-up with ~10 ms spacing, posted to
    /// `.cghidEventTap` (docs/03 §3.2: key codes 0x37/0x09).
    static func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let commandKey = CGKeyCode(kVK_Command)  // 0x37
        let vKey = CGKeyCode(kVK_ANSI_V)  // 0x09
        guard
            let commandDown = CGEvent(
                keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            let commandUp = CGEvent(
                keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        else { return }
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        let sequence = [commandDown, vDown, vUp, commandUp]
        for (index, event) in sequence.enumerated() {
            event.post(tap: .cghidEventTap)
            if index < sequence.count - 1 {
                usleep(Self.interKeyDelayMicroseconds)
            }
        }
    }

    /// Type arbitrary text via `keyboardSetUnicodeString` in chunks of at most
    /// 20 UTF-16 units (the CGEvent payload limit) with a small inter-chunk
    /// delay so slow terminals keep up. Layout-independent; works for CJK
    /// (docs/03 §3.2 tier 2).
    static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + Self.maxChunkUTF16Units, units.count)
            // Never split a surrogate pair across chunks — the halves would
            // arrive as two events and decode as garbage. (end stays > index:
            // the chunk limit is 20, so backing off one unit never empties it.)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            var chunk = Array(units[index..<end])
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            // Clear inherited modifier flags — a still-latched Fn/⌘ from the
            // hotkey must not turn typed characters into shortcuts.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            index = end
            if index < units.count {
                usleep(Self.interChunkDelayMicroseconds)
            }
        }
    }

    // MARK: - Timing constants (docs/03 §3.2)

    private static let interKeyDelayMicroseconds: UInt32 = 10_000  // ~10 ms
    private static let interChunkDelayMicroseconds: UInt32 = 5_000  // 5 ms
    private static let maxChunkUTF16Units = 20
}
