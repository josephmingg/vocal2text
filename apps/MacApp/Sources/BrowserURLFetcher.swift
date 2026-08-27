import Foundation

/// Fetches the frontmost tab's URL from a supported browser by shelling out to
/// `/usr/bin/osascript` (docs/03 §3.3).
///
/// Callers treat a nil return as "degrade to app-level routing" (docs/05 §4):
/// an unsupported app, a denied Automation permission, no open browser window,
/// and a hung browser all look identical from the outside — routing silently
/// falls back to the `.app` route for the frontmost bundle ID.
///
/// Async, non-blocking: the call awaits the osascript child for up to 1.5 s
/// (a hung browser must not stall dictation — docs/03 §3.3), then
/// `terminate()`s it and returns nil. No thread is parked while waiting; the
/// session overlaps this await with recording.
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
    /// non-zero exit, timeout, empty output). Suspends — never blocks a
    /// thread — for at most 1.5 s.
    static func activeTabURL(browserBundleID: String) async -> String? {
        guard let script = scriptsByBundleID[browserBundleID] else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        process.standardOutput = stdout
        // Automation-permission denials print to stderr; discard so nothing
        // can back up a pipe buffer.
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            // Exactly one resume: the termination handler and the timeout
            // race, and `terminate()` fires the handler again.
            let once = ResumeOnce(continuation)

            process.terminationHandler = { finished in
                guard finished.terminationStatus == 0 else {
                    once.resume(returning: nil)
                    return
                }
                // A tab URL is far below the 64 KB pipe buffer, so the child
                // can never have blocked on a full pipe before exiting;
                // reading after termination is safe.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                once.resume(returning: (output?.isEmpty ?? true) ? nil : output)
            }

            do {
                try process.run()
            } catch {
                once.resume(returning: nil)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeoutSeconds
            ) {
                if once.resume(returning: nil) {
                    // A hung browser must not stall dictation (docs/03 §3.3);
                    // the handler this fires is swallowed by `once`.
                    process.terminate()
                }
            }
        }
    }
}

/// Wraps a continuation so racing completion paths resume it exactly once.
/// `resume` reports whether this call was the one that resumed.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: String?) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: value)
        return true
    }
}
