# Plan: Customizable Push-to-Talk Hotkey (dropdown + record-your-own)

Goal: replace the fixed 3-option hotkey picker with (a) a dropdown of common presets and
(b) a fully custom "press your keys now" recorder — while preserving every behavior the
current monitor guarantees (hold/tap/double-tap-lock/chord-abort semantics, tap hygiene,
secure-input survival for modifier-only keys).

## 1. Current state (what we're generalizing)

- `SettingsStore.HotkeyChoice: String, CaseIterable { fnKey, rightCommand, rightOption }`
  persisted as a raw string; Picker in SettingsView; `AppDelegate` observes changes →
  `HotkeyMonitor.updateChoice + rearm`.
- `HotkeyMonitor` hard-codes three modifier-only matches: Fn (keyCode 63,
  `.maskSecondaryFn`), Right ⌘ (54, `.maskCommand`), Right ⌥ (61, `.maskAlternate`), with
  the press state machine (0.5 s tap window, 0.35 s double-tap lock, ~1 s chord-abort,
  50 ms debounce, tap re-enable hygiene) interleaved with the matching.

## 2. UX design

**Settings → General → "Push-to-talk key" dropdown:**

| Group | Options |
|---|---|
| Recommended | 🌐 Fn / Globe (default) · Right ⌘ |
| Modifiers | Left ⌘ · Right ⌥ · Left ⌥ · Right ⌃ · Left ⌃ · Right ⇧ · Left ⇧ |
| Function keys | F13 · F14 · F15 (great for external keyboards) |
| — | **Custom…** |

- Selecting **Custom…** opens a recorder sheet: "Press your desired key or combination
  now" → live capture shows the combo as keycap symbols (⌃⌥⇧⌘ + key) → **Use** / Cancel.
- Contextual caveats shown inline per selection:
  - Fn → the "Press 🌐 key to: Do Nothing" system-setting check + deep link (existing
    `FnKeySetup`), plus the press-Fn-twice Dictation shortcut warning.
  - Any **modifier+key chord** (e.g. ⌥Space) → amber note: "Key combinations stop working
    while a password field is focused (macOS secure input); single modifier keys keep
    working." (Research-verified: `flagsChanged` survives secure input, `keyDown` doesn't.)
  - Known conflicts flagged when recorded: ⌘Space (Spotlight), ⌃Space (input source),
    ⌥Space (app-specific), F11/F12 (system volume on some keyboards).
- Validation (recorder refuses, with explanation): plain letter/number/punctuation keys
  with no modifier (would block typing); Escape (reserved for cancel); Delete/Return alone.

## 3. Data model

Replace the enum with a Codable spec, persisted as JSON in UserDefaults under a new key:

```swift
/// CoreModels (pure, Linux-testable)
public struct HotkeySpec: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        /// Fn or a single left/right modifier: matched on flagsChanged edges;
        /// survives secure input; supports chord-abort.
        case modifierOnly(keyCode: UInt16, flagMask: UInt64)
        /// A non-modifier key, optionally with required modifiers held
        /// (exact match): matched on keyDown/keyUp; hold = key held.
        case key(keyCode: UInt16, requiredFlags: UInt64)
    }
    public var kind: Kind
    /// Display string, e.g. "🌐 Fn", "⌥Space", "F13" — computed at record time
    /// from a keyCode→keycap table so the UI never re-derives it.
    public var label: String
}
```

- Presets = a static `HotkeySpec.presets: [HotkeySpec]` table (the dropdown rows).
- **Migration**: on first launch, map the legacy `hotkeyChoice` raw string
  (fnKey/rightCommand/rightOption) to its preset spec, write the new key, keep the old
  key untouched for rollback.

## 4. Monitor refactor (the careful part)

Split `HotkeyMonitor` into two layers so the logic becomes testable in CI:

1. **`HotkeyDecisionCore` (pure struct → lives in `SessionKit` or new `HotkeyKit` target)**
   — the existing state machine extracted verbatim: inputs are plain values
   `(eventKind: keyDown/keyUp/flagsChanged, keyCode: UInt16, flags: UInt64, timestamp: TimeInterval)`
   plus a `HotkeySpec`; outputs are the existing edge decisions
   `(pressBegan / pressEnded / lockToggled / cancelled / passthrough)`. All timing
   constants (0.5 s tap, 0.35 s double-tap, 1 s chord-abort, 50 ms debounce) move here.
   **Unit tests on Linux CI**: tap/hold/double-tap/chord sequences for every preset kind,
   including the F-key/arrow `.maskSecondaryFn` stripping rule and the
   modifier-latch pitfalls documented in docs/03 §3.1.
2. **`HotkeyMonitor` (app target)** keeps only the CGEventTap plumbing: tap creation,
   thread, re-enable hygiene, forwarding events into the core, dispatching decisions to
   the main actor. Matching semantics per kind:
   - `.modifierOnly`: current flagsChanged edge logic, parameterized by
     `(keyCode, flagMask)` instead of the hard-coded trio.
   - `.key`: press = keyDown with exact `requiredFlags` match (device-independent mask,
     ignoring caps-lock); release = matching keyUp **or** any requiredFlags modifier
     releasing first (treat as release, not cancel); autorepeat keyDowns ignored
     (`isARepeat`). Chord-abort does not apply (the chord *is* keyed).

## 5. Recorder UI

- `HotkeyRecorderSheet` (SwiftUI + a local `NSEvent.addLocalMonitorForEvents` while the
  sheet is key — no CGEventTap needed for capture, no extra permissions).
- Capture rule: first stable combination wins — a modifier-only capture finalizes on
  release of the lone modifier; a keyed capture finalizes on keyDown.
- Renders live keycaps; Use → writes `HotkeySpec` to settings → `AppDelegate` sink (already
  exists) calls `updateChoice + rearm`.
- keyCode→keycap table (`KeycapNames.swift`): letters/digits via
  `UCKeyTranslate`-free static table for common codes + fallback "Key #n"; modifier
  symbols ⌃⌥⇧⌘🌐.

## 6. Touch list

| File | Change |
|---|---|
| `Sources/CoreModels/HotkeySpec.swift` | new — spec + presets + validation rules |
| `Sources/SessionKit/HotkeyDecisionCore.swift` | new — extracted pure state machine |
| `Tests/SessionKitTests/HotkeyDecisionCoreTests.swift` | new — sequence tests (the CI win) |
| `apps/MacApp/Sources/HotkeyMonitor.swift` | refactor to plumbing + per-kind matching |
| `apps/MacApp/Sources/SettingsStore.swift` | `hotkeySpec: HotkeySpec` + migration; keep `HotkeyChoice` briefly for rollback |
| `apps/MacApp/Sources/SettingsView.swift` | grouped dropdown + Custom… sheet + caveat labels |
| `apps/MacApp/Sources/HotkeyRecorderSheet.swift` | new — capture UI |
| `apps/MacApp/Sources/KeycapNames.swift` | new — display table |
| `apps/MacApp/Sources/AppDelegate.swift` | observe spec instead of choice (mechanical) |
| `docs/10` | update hotkey section |

No `project.yml` change → **no `make generate`, no signing reset** for users updating.

## 7. Acceptance criteria

1. Every preset in the dropdown works as hold-to-talk AND double-tap-lock, verified
   manually on real hardware (checklist table in the PR).
2. A recorded custom chord (⌥Space) dictates; the secure-input caveat is shown for it;
   a recorded F13 works from an external keyboard.
3. Recorder refuses a bare letter key with a clear message.
4. Legacy settings migrate: an existing rightCommand user updates and keeps Right ⌘
   with zero action.
5. `HotkeyDecisionCore` tests green on Linux CI (the state machine finally becomes
   regression-protected — today it's only field-tested).
6. Switching hotkeys applies immediately (existing sink), including preset → custom →
   preset round-trips.

## 8. Effort & sequencing

~1 focused session: (1) spec + migration + decision-core extraction with tests →
CI green; (2) monitor per-kind matching; (3) dropdown + recorder UI; (4) manual
checklist on the owner's Mac, then `make install` roll-out (and `make share` for the
second Mac).

Risks: the decision-core extraction must not change timing behavior (tests written
against the CURRENT semantics first, then refactor under them); left-vs-right shift/⌃
discrimination is keyCode-based with the both-keys-held caveat already documented in
docs/03; keyed-chord release-order edge cases (release modifier before key) are covered
by the "either releases = press ends" rule above.
