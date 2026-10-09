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
        guard let before = readableValue(of: element) else { return false }
        // Replacing a selection with identical text leaves the value as it
        // was — that is success, not a silent no-op, and falling through to
        // paste would insert a second copy (command mode's "fix the grammar"
        // on text that was already fine).
        var selectedRef: CFTypeRef?
        var selectedBefore: String?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
            == .success {
            selectedBefore = selectedRef as? String
        }

        guard
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
            ) == .success
        else { return false }

        // The verification read. Whitespace-insensitive containment: a
        // single-line field may fold the newlines out of a multi-line
        // insertion, and reporting that landed-but-transformed write as a
        // failure would paste the text a second time.
        //
        // The value must also have *changed*: dictating "Thanks!" into a
        // field that already says "Thanks!" passed containment even when the
        // app ACKed the write and ignored it — reported as inserted, nothing
        // pasted, text silently lost (docs/17 §4.4 #4).
        guard let after = readableValue(of: element) else { return false }
        if after == before {
            return selectedBefore == text
        }
        let needle = text.filter { !$0.isWhitespace }
        if needle.isEmpty { return true }
        return after.filter { !$0.isWhitespace }.contains(needle)
    }

    // MARK: - Helpers

    /// Bound for every AX message (docs/17 §4.4 #5). These calls run on the
    /// main actor, and the system default (~6 s) let a beachballing target
    /// freeze the HUD, menu and hotkey for that long. Long enough that a slow
    /// but successful write is not misread as a failure and pasted twice.
    static let messagingTimeout: Float = 1.0

    static func focusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element this sets the process-wide default.
        _ = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        let result = AXUIElementCopyAttributeValue(
            systemWide,
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
        guard let element = focusedElement() else { return nil }
        // A read-only lookup that only refines spacing: a slow target should
        // cost a quarter second, not the whole messaging budget.
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        guard let value = readableValue(of: element) else { return nil }
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

extension AXInserter {
    /// The focused element's selected text, for command mode (docs/17 G4):
    /// what "make this shorter" acts on. nil when nothing is selected, the
    /// element is a secure field, or AX exposes no selection.
    static func selectedText() -> String? {
        guard !SecureInputProbe.isSecureInputActive(), let element = focusedElement() else {
            return nil
        }
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            == .success,
            let subrole = subroleRef as? String,
            subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        var selectedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &selectedRef
            ) == .success,
            let selected = selectedRef as? String,
            !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selected
    }

    /// The text around the caret for opt-in context-aware cleanup (docs/17
    /// G3.2): up to `before` UTF-16 units before the selection and `after`
    /// beyond it. nil for secure fields, while secure input is on, or where
    /// AX exposes no value and selection. The caller holds it for one cleanup
    /// request; nothing here stores it.
    static func surroundingText(before: Int = 240, after: Int = 80) -> (before: String, after: String)? {
        guard !SecureInputProbe.isSecureInputActive(), let element = focusedElement() else {
            return nil
        }
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            == .success,
            let subrole = subroleRef as? String,
            subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        guard let value = readableValue(of: element) else { return nil }
        var rangeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
            ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &cfRange)
        else { return nil }
        let haystack = value as NSString
        let selectionStart = min(max(0, cfRange.location), haystack.length)
        let selectionEnd = min(max(selectionStart, cfRange.location + cfRange.length), haystack.length)
        let start = max(0, selectionStart - before)
        let end = min(haystack.length, selectionEnd + after)
        return (
            haystack.substring(with: NSRange(location: start, length: selectionStart - start)),
            haystack.substring(with: NSRange(location: selectionEnd, length: end - selectionEnd))
        )
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
