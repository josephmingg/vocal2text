import AppKit
import ApplicationServices

/// Tier 0 of the insertion ladder (docs/15 step 17, superseded form):
/// insert at the caret through the Accessibility API — no clipboard
/// round-trip, no synthesized keystroke, no fixed sleeps — and read the
/// focused element back to *know* it landed. That read is the success signal
/// the paste tier never had, so failure here descends to paste instead of
/// being silently lost.
///
/// Deliberately conservative about when it claims the insertion: the attempt
/// is only made when the focused element both accepts a selected-text write
/// AND exposes a readable string value, because a "successful" AX write with
/// no way to verify it is indistinguishable from a silent no-op — and
/// descending to paste after an unverifiable write that actually landed
/// would deliver the text twice. Unsupported and unverifiable elements go
/// straight to paste, which is exactly today's behavior.
@MainActor
enum AXInserter {

    /// Attempts the AX insertion. `true` means the text verifiably landed in
    /// the focused element; `false` means nothing was inserted and the caller
    /// must fall through to the next tier.
    static func insertAndVerify(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let element = focusedElement() else { return false }

        // Only elements that accept a selected-text write are candidates —
        // writing kAXSelectedTextAttribute replaces the selection, or inserts
        // at the caret when the selection is empty.
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element, kAXSelectedTextAttribute as CFString, &settable
            ) == .success,
            settable.boolValue
        else { return false }

        // Insist on verifiability BEFORE writing (see type comment): an
        // element with no readable value cannot confirm the write, and a
        // paste after an unconfirmed-but-landed write duplicates the text.
        guard readableValue(of: element) != nil else { return false }

        guard
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
            ) == .success
        else { return false }

        // The verification read. Whitespace-insensitive containment: a
        // single-line field may fold the newlines out of a multi-line
        // insertion, and reporting that landed-but-transformed write as a
        // failure would paste the text a second time.
        guard let after = readableValue(of: element) else { return false }
        let needle = text.filter { !$0.isWhitespace }
        if needle.isEmpty { return true }
        return after.filter { !$0.isWhitespace }.contains(needle)
    }

    // MARK: - Helpers

    static func focusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        // CF references have identical layout; the type is checked above.
        // (A plain cast would be force_cast, which this repo bans.)
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    /// The element's string value, when it exposes one.
    static func readableValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef
            ) == .success
        else { return nil }
        return valueRef as? String
    }
}

extension AXInserter {
    /// The text immediately before the caret in the focused element (docs/15
    /// step 29): the preceding-context read that finally makes smart spacing
    /// and joining real (FR-3.3). nil where AX exposes no value or selection
    /// — the caller falls back or formats for a fresh insertion point.
    static func precedingContext(maxLength: Int = 64) -> String? {
        guard
            let element = focusedElement(),
            let value = readableValue(of: element)
        else { return nil }
        var rangeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
            ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var cfRange = CFRange()
        // Layout-compatible reference; the type id is checked above.
        guard AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &cfRange)
        else { return nil }
        let haystack = value as NSString
        let caret = min(max(0, cfRange.location), haystack.length)
        let start = max(0, caret - maxLength)
        return haystack.substring(with: NSRange(location: start, length: caret - start))
    }
}

/// The undo half of docs/15 step 28: the safety net that makes aggressive
/// cleanup acceptable. Selects the last occurrence of the delivered text in
/// the focused element via the Accessibility API and replaces it — with the
/// raw transcription, or with nothing. Only where AX exposes a readable
/// value and a settable selection; anywhere else the caller reports that
/// undo isn't available rather than guessing with synthesized keystrokes.
@MainActor
enum AXUndo {

    /// Replaces the last occurrence of `needle` in the focused element with
    /// `replacement` ("" removes it). Returns false when the element cannot
    /// be read, the text is not found, or the selection is not settable —
    /// nothing was changed in that case.
    static func replaceLastOccurrence(of needle: String, with replacement: String) -> Bool {
        guard !needle.isEmpty, let element = AXInserter.focusedElement() else { return false }
        guard let value = AXInserter.readableValue(of: element) else { return false }
        // AX text ranges are UTF-16 offsets, exactly NSString's currency.
        let haystack = value as NSString
        let range = haystack.range(of: needle, options: [.backwards])
        guard range.location != NSNotFound else { return false }

        // Both attributes must be settable up front: a selectable-but-not-
        // editable element (a read-only viewer) accepts the range set — which
        // visibly moves the user's caret — and then rejects the text set,
        // breaking this function's "nothing was changed on false" contract.
        for attribute in [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute] {
            var settable = DarwinBoolean(false)
            guard
                AXUIElementIsAttributeSettable(
                    element, attribute as CFString, &settable
                ) == .success,
                settable.boolValue
            else { return false }
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        guard
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, axRange
            ) == .success
        else { return false }
        // Read the selection back before writing: some AX layers (Electron
        // web areas) ACK a range set without applying it, and the text write
        // would then land at the caret instead of over the found occurrence.
        var verifyRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &verifyRef
            ) == .success,
            let verifyRef,
            CFGetTypeID(verifyRef) == AXValueGetTypeID()
        else { return false }
        var appliedRange = CFRange()
        guard
            AXValueGetValue(unsafeBitCast(verifyRef, to: AXValue.self), .cfRange, &appliedRange),
            appliedRange.location == cfRange.location,
            appliedRange.length == cfRange.length
        else { return false }
        guard
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef
            ) == .success
        else { return false }
        return true
    }
}
