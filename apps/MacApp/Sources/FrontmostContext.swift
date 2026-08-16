import AppKit
import Foundation
import ProfileKit

/// Snapshots the dictation context at hotkey press: the frontmost app and,
/// when that app is a supported browser, the active tab's hostname
/// (docs/03 §3.3, docs/05 §4 routing algorithm).
///
/// Deliberately NOT @MainActor (deviation from the shared AppState contract,
/// flagged for the integrator): the browser-URL fetch can block for up to
/// 1.5 s, which must never happen on the main thread. The class is therefore
/// nonisolated and Sendable, and `snapshot()` is a blocking call meant for the
/// background async context of AppState's `profileResolution` closure. Only
/// the tiny `NSWorkspace.frontmostApplication` read hops (synchronously) to
/// the main thread.
///
/// Privacy (docs/05 §4, FR-8.4): the tab URL is reduced to a bare hostname
/// immediately via `HostnameReducer` and used in memory only for this one
/// resolution — neither the URL nor the hostname is ever persisted; history
/// stores profile name + route type.
final class FrontmostContext: Sendable {

    init() {}

    /// Blocking snapshot of press-time context; call from a background thread
    /// only (up to ~1.5 s inside the osascript fetch). A nil `tabHostname`
    /// means "not a browser / URL unavailable" and degrades to app-level
    /// routing (docs/05 §4).
    func snapshot() -> (bundleID: String?, appName: String?, tabHostname: String?) {
        let app = Self.frontmostApplicationInfo()
        guard let bundleID = app.bundleID else {
            return (bundleID: nil, appName: app.name, tabHostname: nil)
        }

        var tabHostname: String?
        if BrowserURLFetcher.isSupportedBrowser(bundleID: bundleID),
            let tabURL = BrowserURLFetcher.activeTabURL(browserBundleID: bundleID)
        {
            tabHostname = HostnameReducer.hostname(fromTabURL: tabURL)
        }
        return (bundleID: bundleID, appName: app.name, tabHostname: tabHostname)
    }

    /// NSWorkspace state is read on the main thread (AppKit convention,
    /// docs/03 §3.3); the hop is synchronous but tiny — only two strings cross
    /// back. Guarded so a main-thread caller reads directly instead of
    /// deadlocking in `DispatchQueue.main.sync`.
    private static func frontmostApplicationInfo() -> (bundleID: String?, name: String?) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { readFrontmostApplication() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { readFrontmostApplication() }
        }
    }

    @MainActor
    private static func readFrontmostApplication() -> (bundleID: String?, name: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.localizedName)
    }
}
