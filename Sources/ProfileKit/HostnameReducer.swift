import Foundation

/// Reduces browser tab URLs to bare hostnames for `.website` routing
/// (docs/05 §4). Only the hostname ever leaves this type — never the path,
/// query, fragment, or title — and it is used in memory only, never persisted
/// (FR-8.4).
public enum HostnameReducer: Sendable {
    /// Extracts the routing hostname from a full tab URL.
    ///
    /// Returns the lowercased host with a single leading "www." label removed,
    /// or nil when the string is not an http(s) URL with a non-empty host.
    public static func hostname(fromTabURL urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.isEmpty
        else { return nil }

        var reduced = host.lowercased()
        if reduced.hasPrefix("www.") {
            reduced = String(reduced.dropFirst("www.".count))
        }
        return reduced.isEmpty ? nil : reduced
    }

    /// Label-boundary-aware suffix match on domain labels (docs/05 §4):
    /// route "google.com" matches "google.com" and "mail.google.com" but
    /// never "notgoogle.com" — a subdomain match requires a "." immediately
    /// before the route suffix. Case-insensitive; empty inputs never match.
    public static func matches(routeHostname: String, actual: String) -> Bool {
        let route = routeHostname.lowercased()
        let host = actual.lowercased()
        guard !route.isEmpty, !host.isEmpty else { return false }
        return host == route || host.hasSuffix("." + route)
    }
}
