import CoreModels
import Foundation
import Testing

// MARK: - Persistence

@Test func modifierOnlySpecCodableRoundTrips() throws {
    let spec = HotkeySpec.rightCommand
    let data = try JSONEncoder().encode(spec)
    #expect(try JSONDecoder().decode(HotkeySpec.self, from: data) == spec)
}

@Test func keyedSpecCodableRoundTrips() throws {
    let spec = HotkeySpec(
        kind: .key(keyCode: HotkeyKeyCode.space, requiredFlags: HotkeyFlagMask.option)
    )
    let data = try JSONEncoder().encode(spec)
    #expect(try JSONDecoder().decode(HotkeySpec.self, from: data) == spec)
}

@Test func specDecodesWithoutAStoredLabel() throws {
    // Forward/backward tolerance: a payload written before labels were stored
    // still decodes, naming itself from the keycap table.
    let json = #"{"type":"key","keyCode":105,"flags":0}"#
    let spec = try JSONDecoder().decode(HotkeySpec.self, from: Data(json.utf8))
    #expect(spec.label == "F13")
    #expect(spec.kind == .key(keyCode: HotkeyKeyCode.f13, requiredFlags: 0))
}

@Test func specRejectsAnUnknownKind() {
    let json = #"{"type":"gesture","keyCode":1,"flags":0}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(HotkeySpec.self, from: Data(json.utf8))
    }
}

// MARK: - Presets

@Test func presetsCoverTheDocumentedDropdown() {
    #expect(HotkeySpec.presetGroups.map(\.title) == ["Recommended", "Modifiers", "Function keys"])
    #expect(
        HotkeySpec.presets.map(\.label) == [
            "🌐 Fn", "Right ⌘",
            "Left ⌘", "Right ⌥", "Left ⌥", "Right ⌃", "Left ⌃", "Right ⇧", "Left ⇧",
            "F13", "F14", "F15",
        ]
    )
}

@Test func everyPresetIsValidAndDistinct() {
    for spec in HotkeySpec.presets {
        #expect(HotkeySpec.validationError(for: spec.kind) == nil, "\(spec.label)")
        #expect(spec.isPreset, "\(spec.label)")
    }
    #expect(Set(HotkeySpec.presets).count == HotkeySpec.presets.count)
}

@Test func everyModifierPresetCarriesItsFlagMask() {
    // A zero mask would produce a binding whose down edge never fires.
    for spec in HotkeySpec.presets {
        if case .modifierOnly(_, let flagMask) = spec.kind {
            #expect(flagMask != 0, "\(spec.label)")
        }
    }
}

@Test func fnGlobeIsTheDefault() {
    #expect(HotkeySpec.default == .fnGlobe)
    #expect(HotkeySpec.default.usesFnKey)
    #expect(HotkeySpec.default.isModifierOnly)
}

@Test func recordedBindingsAreNotMistakenForPresets() {
    let custom = HotkeySpec(
        kind: .key(keyCode: HotkeyKeyCode.space, requiredFlags: HotkeyFlagMask.option)
    )
    #expect(!custom.isPreset)
    // Recording a preset by hand yields the preset itself.
    #expect(
        HotkeySpec(
            kind: .modifierOnly(
                keyCode: HotkeyKeyCode.rightCommand,
                flagMask: HotkeyFlagMask.command
            )
        ) == HotkeySpec.rightCommand
    )
}

// MARK: - Labels

@Test func labelsReadAsKeycaps() {
    #expect(
        HotkeySpec(kind: .key(keyCode: HotkeyKeyCode.space, requiredFlags: HotkeyFlagMask.option))
            .label == "⌥Space"
    )
    #expect(
        HotkeySpec(
            kind: .key(
                keyCode: 0,
                requiredFlags: HotkeyFlagMask.command | HotkeyFlagMask.control
                    | HotkeyFlagMask.shift | HotkeyFlagMask.option
            )
        ).label == "⌃⌥⇧⌘A"
    )
    #expect(HotkeySpec(kind: .key(keyCode: 123, requiredFlags: 0)).label == "←")
}

@Test func unknownKeyCodesStillGetALabel() {
    #expect(KeycapNames.keyName(forKeyCode: 200) == "Key #200")
}

// MARK: - Validation

@Test func bareTypingKeysAreRefused() {
    for keyCode: UInt16 in [0 /* A */, 18 /* 1 */, 47 /* . */, 49 /* Space */, 36 /* Return */,
        51 /* Delete */, 117 /* Forward Delete */, 48 /* Tab */] {
        #expect(
            HotkeySpec.validationError(for: .key(keyCode: keyCode, requiredFlags: 0)) != nil,
            "\(KeycapNames.keyName(forKeyCode: keyCode))"
        )
    }
}

@Test func typingKeysAreAllowedInAChord() {
    #expect(
        HotkeySpec.validationError(
            for: .key(keyCode: HotkeyKeyCode.space, requiredFlags: HotkeyFlagMask.option)
        ) == nil
    )
    #expect(
        HotkeySpec.validationError(for: .key(keyCode: 0, requiredFlags: HotkeyFlagMask.control))
            == nil
    )
}

@Test func escapeIsNeverBindable() {
    #expect(
        HotkeySpec.validationError(for: .key(keyCode: HotkeyKeyCode.escape, requiredFlags: 0))
            == .escapeReserved
    )
    #expect(
        HotkeySpec.validationError(
            for: .key(keyCode: HotkeyKeyCode.escape, requiredFlags: HotkeyFlagMask.command)
        ) == .escapeReserved
    )
}

@Test func capsLockIsNeverBindable() {
    #expect(
        HotkeySpec.validationError(
            for: .modifierOnly(keyCode: HotkeyKeyCode.capsLock, flagMask: HotkeyFlagMask.capsLock)
        ) == .capsLockUnsupported
    )
}

@Test func functionAndNavigationKeysBindWithoutModifiers() {
    for keyCode: UInt16 in [HotkeyKeyCode.f13, 122 /* F1 */, 123 /* ← */, 115 /* Home */] {
        #expect(HotkeySpec.validationError(for: .key(keyCode: keyCode, requiredFlags: 0)) == nil)
    }
}

@Test func refusalMessagesNameTheKey() {
    let error = HotkeySpec.validationError(for: .key(keyCode: 0, requiredFlags: 0))
    #expect(error == .needsModifier(keyLabel: "A"))
    #expect(error?.message.contains("“A”") == true)
}

// MARK: - Advisories

@Test func keyedBindingsWarnAboutSecureInput() {
    let advisories = HotkeySpec(kind: .key(keyCode: HotkeyKeyCode.f13, requiredFlags: 0)).advisories
    #expect(advisories.contains(.secureInput))
    #expect(HotkeySpec.fnGlobe.advisories.contains(.secureInput) == false)
    #expect(HotkeySpec.rightCommand.advisories.isEmpty)
}

@Test func fnBindingWarnsAboutTheDictationShortcut() {
    #expect(HotkeySpec.fnGlobe.advisories == [.fnDoubleTapDictation])
}

@Test func knownConflictsAreFlagged() {
    func advisories(space modifiers: UInt64) -> [HotkeyAdvisory] {
        HotkeySpec(kind: .key(keyCode: HotkeyKeyCode.space, requiredFlags: modifiers)).advisories
    }
    #expect(advisories(space: HotkeyFlagMask.command).contains(.spotlightConflict))
    #expect(advisories(space: HotkeyFlagMask.control).contains(.inputSourceConflict))
    #expect(advisories(space: HotkeyFlagMask.option).contains(.appShortcutConflict))
    #expect(advisories(space: HotkeyFlagMask.shift).count == 1)  // secure input only

    for keyCode in [HotkeyKeyCode.f11, HotkeyKeyCode.f12] {
        #expect(
            HotkeySpec(kind: .key(keyCode: keyCode, requiredFlags: 0)).advisories
                .contains(.systemFunctionKey)
        )
    }
    #expect(
        HotkeySpec(kind: .key(keyCode: 124, requiredFlags: 0)).advisories
            .contains(.navigationKeyShadowed)
    )
    #expect(
        HotkeySpec(kind: .key(keyCode: 124, requiredFlags: HotkeyFlagMask.command)).advisories
            .contains(.navigationKeyShadowed) == false
    )
}

@Test func conflictAdvisoriesAreWarnings() {
    #expect(HotkeyAdvisory.spotlightConflict.severity == .warning)
    #expect(HotkeyAdvisory.secureInput.severity == .warning)
    #expect(HotkeyAdvisory.fnDoubleTapDictation.severity == .info)
}

// MARK: - Flag normalization

@Test func normalizationDropsNoiseBits() {
    let noisy =
        HotkeyFlagMask.option | HotkeyFlagMask.capsLock | HotkeyFlagMask.numericPad
        | HotkeyFlagMask.help | 0x100 | 0x20
    #expect(HotkeyFlagMask.normalized(noisy, forKeyCode: 0) == HotkeyFlagMask.option)
}

@Test func normalizationStripsTheLatchedFnBitFromFunctionAndArrowKeys() {
    for keyCode in HotkeyKeyCode.functionAndArrowKeyCodes {
        #expect(HotkeyFlagMask.normalized(HotkeyFlagMask.function, forKeyCode: keyCode) == 0)
    }
    // …and keeps it everywhere else, so 🌐-chords remain bindable.
    #expect(
        HotkeyFlagMask.normalized(HotkeyFlagMask.function, forKeyCode: 0)
            == HotkeyFlagMask.function
    )
}

@Test func everyBindableModifierMapsToItsFlag() {
    let expected: [UInt16: UInt64] = [
        HotkeyKeyCode.leftCommand: HotkeyFlagMask.command,
        HotkeyKeyCode.rightCommand: HotkeyFlagMask.command,
        HotkeyKeyCode.leftShift: HotkeyFlagMask.shift,
        HotkeyKeyCode.rightShift: HotkeyFlagMask.shift,
        HotkeyKeyCode.leftOption: HotkeyFlagMask.option,
        HotkeyKeyCode.rightOption: HotkeyFlagMask.option,
        HotkeyKeyCode.leftControl: HotkeyFlagMask.control,
        HotkeyKeyCode.rightControl: HotkeyFlagMask.control,
        HotkeyKeyCode.function: HotkeyFlagMask.function,
    ]
    for (keyCode, mask) in expected {
        #expect(HotkeyKeyCode.modifierFlagMask(for: keyCode) == mask)
    }
    #expect(HotkeyKeyCode.modifierFlagMask(for: HotkeyKeyCode.capsLock) == nil)
    #expect(HotkeyKeyCode.modifierFlagMask(for: HotkeyKeyCode.space) == nil)
}

// MARK: - Migration

@Test func legacyHotkeyChoicesMigrateToTheirPresets() {
    #expect(HotkeySpec.migratingLegacyChoice("fnKey") == .fnGlobe)
    #expect(HotkeySpec.migratingLegacyChoice("rightCommand") == .rightCommand)
    #expect(HotkeySpec.migratingLegacyChoice("rightOption") == .rightOption)
    #expect(HotkeySpec.migratingLegacyChoice("somethingElse") == nil)
}
