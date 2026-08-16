import Foundation

/// Fetches the frontmost tab's URL from a supported browser by shelling out to
/// `/usr/bin/osascript` (docs/03 §3.3).
///
/// Callers treat a nil return as "degrade to app-level routing" (docs/05 §4):
/// an unsupported app, a denied Automation permission, no open browser window,
/// and a hung browser all look identical from the outside — routing silently
/// falls back to the `.app` route for the frontmost bundle ID.
///
/// Blocking by design: the call waits up to 1.5 s for osascript (a hung
/// browser must not stall dictation — docs/03 §3.3), then `terminate()`s the
/// child and returns nil. Never call this on the main thread;
/// `FrontmostContext.snapshot()` invokes it from the background context that
/// runs profile resolution.
enum BrowserURLFetcher {

    /// Hard deadline for the osascript round-trip (docs/03 §3.3).
    private static let timeoutSeconds: Double = 1.5

    /// Bundle-ID → AppleScript dialect table (docs/03 §3.3). Safari addresses
    /// the app by name and calls the frontmost tab "current tab"; the Chromium
    /// family shares one dialect ("active tab") addressed by bundle ID so a
    /// renamed app binary still resolves. Firefox is deliberately absent: it
    /// exposes no scriptable tab URL (docs/05 §4, FR-8.2), so Firefox routes
    /// at the app level only.
    private static let scriptsByBundleID: [String: String] = {
        var table: [String: String] = [
            "com.apple.Safari":
                "tell application \"Safari\" to return URL of current tab of front window"
        ]
        let chromiumFamily = [
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",  // Arc
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
        ]
        for bundleID in chromiumFamily {
            table[bundleID] =
                "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        }
        return table
    }()

    /// Whether hostname routing can even be attempted for this app. False for
    /// Firefox and every non-browser; checking first lets `FrontmostContext`
    /// skip the process spawn entirely for ordinary apps.
    static func isSupportedBrowser(bundleID: String) -> Bool {
        scriptsByBundleID[bundleID] != nil
    }

    /// Returns the active tab's URL string for a supported browser, or nil on
    /// any failure (unsupported bundle ID, spawn failure, Automation denial,
    /// non-zero exit, timeout, empty output). Blocks the calling thread for up
    /// to 1.5 s — background threads only.
    static func activeTabURL(browserBundleID: String) -> String? {
        guard let script = scriptsByBundleID[browserBundleID] else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        process.standardOutput = stdout
        // Automation-permission denials print to stderr; discard so nothing
        // can back up a pipe buffer.
        process.standardError = FileHandle.nullDevice

        // The termination handler retains the semaphore, so signaling after a
        // timed-out wait is safe (the semaphore only ever ends above its
        // initial value).
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        // A tab URL is far below the 64 KB pipe buffer, so the child can never
        // have blocked on a full pipe before exiting; reading after
        // termination is safe.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
