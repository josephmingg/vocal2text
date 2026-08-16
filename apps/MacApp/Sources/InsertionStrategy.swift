import Foundation

/// How text reaches the target app. Tier selection is configuration-driven,
/// not failure-driven — a synthesized ⌘V produces no reliable success signal,
/// so descent through the ladder cannot be detected at runtime (docs/03 §3.2).
enum InsertionStrategy: String, CaseIterable {
    /// Pasteboard + synthesized ⌘V with full snapshot/restore (primary tier).
    case paste
    /// CGEvent Unicode typing — terminals that intercept ⌘V, and the
    /// "never touch my clipboard" mode (FR-3.5).
    case unicodeTyping
    /// Clipboard + "Copied — ⌘V to paste" notification only (last resort /
    /// explicit user setting, FR-3.4).
    case clipboardOnly
}

/// Per-bundle-ID strategy table with sane built-in defaults; user overrides
/// from Advanced settings win over the built-ins (docs/03 §3.2).
struct InsertionStrategyTable {

    /// Parsed user overrides (bundle ID → strategy). Unknown raw values are
    /// dropped rather than mis-mapped.
    private let overrides: [String: InsertionStrategy]

    init(overrides: [String: String]) {
        var parsed: [String: InsertionStrategy] = [:]
        for (bundleID, rawValue) in overrides {
            guard let strategy = InsertionStrategy(rawValue: rawValue) else { continue }
            parsed[bundleID] = strategy
        }
        self.overrides = parsed
    }

    func strategy(forBundleID bundleID: String?) -> InsertionStrategy {
        guard let bundleID else { return .paste }
        if let override = overrides[bundleID] {
            return override
        }
        if Self.terminalBundleIDs.contains(bundleID) {
            return .unicodeTyping
        }
        // Known Electron apps still paste — they just need longer delays
        // (see pasteDelayMillis). Default tier is paste (docs/03 §3.2 tier 1).
        return .paste
    }

    /// Delays around the synthesized ⌘V: `prePaste` between the pasteboard
    /// write and the keystroke, `preRestore` between the keystroke and the
    /// snapshot restore. Electron/Chromium targets read the pasteboard late,
    /// so they get extended delays (docs/03 §3.2; Handy's shipped values).
    func pasteDelayMillis(forBundleID bundleID: String?) -> (prePaste: Int, preRestore: Int) {
        guard let bundleID else { return (prePaste: 100, preRestore: 250) }
        if Self.electronBundleIDs.contains(bundleID) {
            return (prePaste: 250, preRestore: 400)
        }
        return (prePaste: 100, preRestore: 250)
    }

    // MARK: - Built-in defaults (docs/03 §3.2)

    /// Terminals intercept ⌘V or run raw-mode UIs — Unicode typing is the
    /// reliable path there.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
    ]

    /// Electron apps paste fine but poll the pasteboard slowly; restoring the
    /// snapshot too early makes them paste the *restored* contents.
    private static let electronBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.hnc.Discord",
    ]
}
