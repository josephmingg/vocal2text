import CoreModels
import Foundation

/// Resolves which profile handles the current dictation (docs/05 §4 routing
/// algorithm). Evaluated at hotkey press so the profile is known before
/// cleanup starts. Precedence: manual pin → `.website` routes (when a tab
/// hostname is available) → `.app` routes → the `.defaultRoute` owner → a
/// synthesized "Default" profile.
public struct ProfileResolver: Sendable {
    /// The outcome of routing: the winning profile plus the route kind that
    /// history records (profile name + route type only, never a hostname —
    /// FR-8.4).
    public struct Resolution: Sendable, Hashable {
        public var profile: Profile
        public var routeKind: TranscriptRecord.RouteKind

        public init(profile: Profile, routeKind: TranscriptRecord.RouteKind) {
            self.profile = profile
            self.routeKind = routeKind
        }
    }

    private let profiles: [Profile]

    public init(profiles: [Profile]) {
        self.profiles = profiles
    }

    /// Resolves the active profile for one dictation.
    ///
    /// - Parameters:
    ///   - frontmostBundleID: bundle ID of the app frontmost at hotkey press.
    ///   - tabHostname: reduced browser-tab hostname (see `HostnameReducer`);
    ///     nil when the frontmost app is not a browser or the URL is
    ///     unavailable (permission not granted, Firefox), which silently
    ///     degrades to app-level routing.
    ///   - manualPinProfileID: user-pinned profile; wins over all routing when
    ///     it names a known profile, and is ignored otherwise.
    public func resolve(
        frontmostBundleID: String?,
        tabHostname: String?,
        manualPinProfileID: UUID?
    ) -> Resolution {
        if let pinID = manualPinProfileID,
           let pinned = profiles.first(where: { $0.id == pinID }) {
            return Resolution(profile: pinned, routeKind: .manualPin)
        }
        if let hostname = tabHostname, let match = websiteMatch(hostname: hostname) {
            return Resolution(profile: match, routeKind: .website)
        }
        if let bundleID = frontmostBundleID, let match = appMatch(bundleID: bundleID) {
            return Resolution(profile: match, routeKind: .app)
        }
        if let owner = best(profiles.filter { $0.routes.contains(.defaultRoute) }) {
            return Resolution(profile: owner, routeKind: .defaultRoute)
        }
        return Resolution(profile: Self.synthesizedDefault, routeKind: .defaultRoute)
    }

    private func websiteMatch(hostname: String) -> Profile? {
        best(profiles.filter { profile in
            profile.routes.contains { route in
                guard case .website(let routeHost) = route else { return false }
                return HostnameReducer.matches(routeHostname: routeHost, actual: hostname)
            }
        })
    }

    private func appMatch(bundleID: String) -> Profile? {
        let target = bundleID.lowercased()
        return best(profiles.filter { profile in
            profile.routes.contains { route in
                guard case .app(let routeBundle) = route else { return false }
                return routeBundle.lowercased() == target
            }
        })
    }

    /// Deterministic winner among matching profiles: priority descending,
    /// then name ascending (docs/05 §4 explicit conflict ordering).
    private func best(_ candidates: [Profile]) -> Profile? {
        candidates.min { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.name < b.name
        }
    }

    /// Fallback when no profile owns `.defaultRoute` (e.g. an empty or
    /// hand-edited profile store). Fixed id so repeated resolutions compare
    /// equal.
    private static let synthesizedDefault = Profile(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        name: "Default",
        cleanupEnabled: false,
        formatting: FormattingOptions(),
        routes: [.defaultRoute]
    )
}
