import Foundation

/// A push-to-talk hotkey binding: what to match, and what to call it.
///
/// Two kinds, because macOS treats them differently in ways the user can feel
/// (docs/13 §3):
///
/// - `.modifierOnly` is edge-detected on `flagsChanged`. It keeps working while
///   a password field holds secure input, and a foreign keyDown right after it
///   means the user wanted a shortcut, not dictation (chord-abort).
/// - `.key` is matched on `keyDown`/`keyUp`. Secure input silences it, and no
///   chord-abort applies — the chord *is* the binding.
///
/// The label is stored, not derived at display time, so a binding recorded by
/// one build always reads back the same way (docs/13 §3).
public struct HotkeySpec: Codable, Sendable, Hashable {

    public enum Kind: Sendable, Hashable {
        /// Fn or a single left/right modifier, matched on `flagsChanged` edges.
        case modifierOnly(keyCode: UInt16, flagMask: UInt64)
        /// A non-modifier key with an exact set of required modifiers (possibly
        /// none), matched on `keyDown`/`keyUp`.
        case key(keyCode: UInt16, requiredFlags: UInt64)
    }

    public var kind: Kind
    /// Display string, e.g. "🌐 Fn", "Right ⌘", "⌥Space", "F13".
    public var label: String

    /// Builds a spec, naming it from the keycap table unless a label is given.
    public init(kind: Kind, label: String? = nil) {
        self.kind = kind
        self.label = label ?? KeycapNames.label(for: kind)
    }

    // MARK: - Traits the UI and the monitor branch on

    public var isModifierOnly: Bool {
        if case .modifierOnly = kind { return true }
        return false
    }

    /// True when the binding is matched on key events, which macOS withholds
    /// while secure input is active (docs/03 §3.1). Drives the amber caveat.
    public var requiresKeyEvents: Bool { !isModifierOnly }

    /// True when pressing the binding presses the Fn / 🌐 Globe key, whose
    /// system action Vocal cannot suppress (docs/03 §3.1).
    public var usesFnKey: Bool {
        switch kind {
        case .modifierOnly(let keyCode, _):
            return keyCode == HotkeyKeyCode.function
        case .key(_, let requiredFlags):
            return requiredFlags & HotkeyFlagMask.function != 0
        }
    }

    // MARK: - Codable
    //
    // Hand-written rather than synthesized: this shape is persisted in
    // UserDefaults, so it must survive future case renames and reject anything
    // it does not understand (the store then falls back to the default).

    private enum CodingKeys: String, CodingKey {
        case type, keyCode, flags, label
    }

    private enum KindType: String, Codable {
        case modifierOnly, key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(KindType.self, forKey: .type)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let flags = try container.decode(UInt64.self, forKey: .flags)
        let decodedKind: Kind
        switch type {
        case .modifierOnly:
            decodedKind = .modifierOnly(keyCode: keyCode, flagMask: flags)
        case .key:
            decodedKind = .key(keyCode: keyCode, requiredFlags: flags)
        }
        kind = decodedKind
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? KeycapNames.label(for: decodedKind)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .modifierOnly(let keyCode, let flagMask):
            try container.encode(KindType.modifierOnly, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(flagMask, forKey: .flags)
        case .key(let keyCode, let requiredFlags):
            try container.encode(KindType.key, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(requiredFlags, forKey: .flags)
        }
        try container.encode(label, forKey: .label)
    }
}

// MARK: - Presets

/// One labelled group of the push-to-talk dropdown (docs/13 §2).
public struct HotkeyPresetGroup: Sendable, Hashable {
    public let title: String
    public let specs: [HotkeySpec]

    public init(title: String, specs: [HotkeySpec]) {
        self.title = title
        self.specs = specs
    }
}

extension HotkeySpec {

    private static func modifier(_ keyCode: UInt16) -> HotkeySpec {
        // Every entry here is a real modifier, so the mask lookup cannot fail;
        // falling back to 0 would silently produce a binding that never fires,
        // and the preset test asserts none of them do.
        HotkeySpec(
            kind: .modifierOnly(
                keyCode: keyCode,
                flagMask: HotkeyKeyCode.modifierFlagMask(for: keyCode) ?? 0
            )
        )
    }

    private static func functionKey(_ keyCode: UInt16) -> HotkeySpec {
        HotkeySpec(kind: .key(keyCode: keyCode, requiredFlags: 0))
    }

    /// The shipping default (docs/01 FR-1.1: hold Fn to talk).
    public static let fnGlobe = modifier(HotkeyKeyCode.function)
    public static let rightCommand = modifier(HotkeyKeyCode.rightCommand)
    public static let rightOption = modifier(HotkeyKeyCode.rightOption)

    public static let `default` = fnGlobe

    public static let presetGroups: [HotkeyPresetGroup] = [
        HotkeyPresetGroup(title: "Recommended", specs: [fnGlobe, rightCommand]),
        HotkeyPresetGroup(
            title: "Modifiers",
            specs: [
                modifier(HotkeyKeyCode.leftCommand),
                rightOption,
                modifier(HotkeyKeyCode.leftOption),
                modifier(HotkeyKeyCode.rightControl),
                modifier(HotkeyKeyCode.leftControl),
                modifier(HotkeyKeyCode.rightShift),
                modifier(HotkeyKeyCode.leftShift),
            ]
        ),
        HotkeyPresetGroup(
            title: "Function keys",
            specs: [
                functionKey(HotkeyKeyCode.f13),
                functionKey(HotkeyKeyCode.f14),
                functionKey(HotkeyKeyCode.f15),
            ]
        ),
    ]

    public static let presets: [HotkeySpec] = presetGroups.flatMap(\.specs)

    /// True when the binding is one of the dropdown rows. Compared on `kind`
    /// only: a hand-recorded Right ⌘ is the same binding as the preset even if
    /// a future build words the label differently.
    public var isPreset: Bool {
        Self.presets.contains { $0.kind == kind }
    }
}

// MARK: - Validation

/// Why the recorder refused a combination (docs/13 §2).
public enum HotkeyValidationError: Error, Sendable, Hashable {
    /// A letter/digit/punctuation/Space/Return/Delete key with no modifier —
    /// binding it would swallow ordinary typing.
    case needsModifier(keyLabel: String)
    /// Escape is how an in-flight take is cancelled, so it cannot be the key
    /// that starts one.
    case escapeReserved
    /// Caps Lock latches instead of reporting hold/release edges.
    case capsLockUnsupported

    public var message: String {
        switch self {
        case .needsModifier(let keyLabel):
            return """
                “\(keyLabel)” on its own would stop you typing it. Hold it with \
                ⌃, ⌥, ⇧ or ⌘, or pick a modifier key instead.
                """
        case .escapeReserved:
            return "Escape is reserved for cancelling a recording in progress."
        case .capsLockUnsupported:
            return "Caps Lock toggles instead of reporting hold and release, so it can’t be held to talk."
        }
    }
}

/// A note shown next to the current binding: things that still work but the
/// user should know about (docs/13 §2).
public enum HotkeyAdvisory: Sendable, Hashable {
    case secureInput
    case fnDoubleTapDictation
    case spotlightConflict
    case inputSourceConflict
    case appShortcutConflict
    case systemFunctionKey
    case navigationKeyShadowed
    /// A modifier the user also holds constantly while typing.
    case typingHandModifier

    public enum Severity: Sendable, Hashable {
        case info
        case warning
    }

    public var severity: Severity {
        switch self {
        case .fnDoubleTapDictation: return .info
        default: return .warning
        }
    }

    public var message: String {
        switch self {
        case .secureInput:
            return """
                Anything other than a single modifier key stops working while a \
                password field is focused (macOS secure input). Fn and the \
                ⌘/⌥/⌃/⇧ keys keep working there.
                """
        case .fnDoubleTapDictation:
            return """
                If “Press 🌐 twice for Dictation” is on in System Settings → \
                Keyboard, turn it off so a double-tap locks Vocal hands-free instead.
                """
        case .spotlightConflict:
            return "⌘Space normally opens Spotlight."
        case .inputSourceConflict:
            return "⌃Space normally switches the input source."
        case .appShortcutConflict:
            return "⌥Space is used as a shortcut by some apps."
        case .systemFunctionKey:
            return """
                On most Macs F1–F12 are brightness and media keys, and only \
                reach apps when “Use F1, F2, etc. as standard function keys” is \
                on in System Settings → Keyboard. F13–F15 always work.
                """
        case .navigationKeyShadowed:
            return "Holding this key to talk means it no longer moves the cursor."
        case .typingHandModifier:
            return """
                You also hold this key for ordinary shortcuts and capitals, so \
                Vocal arms on every press. A right-hand ⌘, ⌥ or ⌃ is steadier.
                """
        }
    }
}

extension HotkeySpec {

    /// Why this combination cannot be bound, or nil when it can. The recorder
    /// calls this before building a spec (docs/13 §5); every preset is asserted
    /// to return nil.
    public static func validationError(for kind: Kind) -> HotkeyValidationError? {
        switch kind {
        case .modifierOnly(let keyCode, _):
            return keyCode == HotkeyKeyCode.capsLock ? .capsLockUnsupported : nil
        case .key(let keyCode, let requiredFlags):
            if keyCode == HotkeyKeyCode.escape {
                return .escapeReserved
            }
            if requiredFlags == 0 && HotkeyKeyCode.requiresModifier(keyCode) {
                return .needsModifier(keyLabel: KeycapNames.keyName(forKeyCode: keyCode))
            }
            return nil
        }
    }

    /// Notes to show beside this binding. Ordered most-important first; the
    /// Globe *system action* note is not here because it depends on a live
    /// system preference the app reads (`FnKeySetup`).
    public var advisories: [HotkeyAdvisory] {
        var notes: [HotkeyAdvisory] = []
        if requiresKeyEvents {
            notes.append(.secureInput)
        }
        if usesFnKey {
            notes.append(.fnDoubleTapDictation)
        }
        if case .modifierOnly(let keyCode, _) = kind,
            HotkeyKeyCode.typingHandModifierKeyCodes.contains(keyCode) {
            notes.append(.typingHandModifier)
        }
        if case .key(let keyCode, let requiredFlags) = kind {
            let modifiers = requiredFlags & HotkeyFlagMask.significant
            if keyCode == HotkeyKeyCode.space {
                switch modifiers {
                case HotkeyFlagMask.command: notes.append(.spotlightConflict)
                case HotkeyFlagMask.control: notes.append(.inputSourceConflict)
                case HotkeyFlagMask.option: notes.append(.appShortcutConflict)
                default: break
                }
            }
            if HotkeyKeyCode.fnLatchingKeyCodes.subtracting(HotkeyKeyCode.arrowKeyCodes)
                .contains(keyCode) {
                notes.append(.systemFunctionKey)
            }
            if modifiers == 0, HotkeyKeyCode.arrowKeyCodes.contains(keyCode) {
                notes.append(.navigationKeyShadowed)
            }
        }
        return notes
    }
}

// MARK: - Legacy migration

extension HotkeySpec {

    /// Maps the pre-spec `SettingsStore.HotkeyChoice` raw string onto its preset
    /// so an existing user keeps their key with zero action (docs/13 §3).
    /// Unknown strings return nil and the store falls back to the default.
    public static func migratingLegacyChoice(_ rawValue: String) -> HotkeySpec? {
        switch rawValue {
        case "fnKey": return .fnGlobe
        case "rightCommand": return .rightCommand
        case "rightOption": return .rightOption
        default: return nil
        }
    }
}
