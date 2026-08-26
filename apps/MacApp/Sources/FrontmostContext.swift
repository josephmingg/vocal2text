import AppKit
import Foundation
import ProfileKit

/// Snapshots the dictation context at hotkey press: the frontmost app and,
/// when that app is a supported browser, the active tab's hostname
/// (docs/03 §3.3, docs/05 §4 routing algorithm).
///
/// `snapshot()` is async: the NSWorkspace read hops to the main actor with an
/// ordinary await (the old `DispatchQueue.main.sync` seam was a latent
/// deadlock that held only by an undocumented caller invariant), and the
/// browser-URL fetch awaits the osascript child instead of blocking a thread.
/// The session spawns resolution concurrently at press and awaits it at
/// release, so the ~1.5 s worst case overlaps recording.
///
/// Privacy (docs/05 §4, FR-8.4): the tab URL is reduced to a bare hostname
/// immediately via `HostnameReducer` and used in memory only for this one
/// resolution — neither the URL nor the hostname is ever persisted; history
/// stores profile name + route type.
final class FrontmostContext: Sendable {

    init() {}

    /// Press-time context. A nil `tabHostname` means "not a browser / URL
    /// unavailable" and degrades to app-level routing (docs/05 §4).
    func snapshot() async -> (bundleID: String?, appName: String?, tabHostname: String?) {
        let app = await MainActor.run {
            let frontmost = NSWorkspace.shared.frontmostApplication
            return (bundleID: frontmost?.bundleIdentifier, name: frontmost?.localizedName)
        }
        guard let bundleID = app.bundleID else {
            return (bundleID: nil, appName: app.name, tabHostname: nil)
        }

        var tabHostname: String?
        if BrowserURLFetcher.isSupportedBrowser(bundleID: bundleID),
            let tabURL = await BrowserURLFetcher.activeTabURL(browserBundleID: bundleID)
        {
            tabHostname = HostnameReducer.hostname(fromTabURL: tabURL)
        }
        return (bundleID: bundleID, appName: app.name, tabHostname: tabHostname)
    }
}
