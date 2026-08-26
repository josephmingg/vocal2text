import Foundation

/// The `vocal://` deep links the keyboard and widgets use to reach the app.
///
/// Building and parsing live together so a link can never be produced in a
/// shape the app does not accept — the two sides ship in different binaries.
public enum VocalURL: Sendable, Hashable {
    /// Open the app and start a take immediately.
    case dictate
    /// Open the app and arm a capture session, so later mic-key presses stay
    /// inside the host app (docs/02 §3.1, the one-bounce-per-session path).
    case arm(window: CaptureWindow, profileName: String?)
    /// Open the app on the share-sheet import queue.
    case imports

    public static let scheme = "vocal"

    private enum Host: String {
        case dictate
        case arm
        case imports
    }

    private enum QueryKey: String {
        case window
        case profile
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .dictate:
            components.host = Host.dictate.rawValue
        case .imports:
            components.host = Host.imports.rawValue
        case .arm(let window, let profileName):
            components.host = Host.arm.rawValue
            var items = [URLQueryItem(name: QueryKey.window.rawValue, value: window.rawValue)]
            if let profileName, !profileName.isEmpty {
                items.append(URLQueryItem(name: QueryKey.profile.rawValue, value: profileName))
            }
            components.queryItems = items
        }
        // Every case above yields a valid absolute URL; the force-unwrap would
        // only fire on a programming error in this file.
        guard let url = components.url else {
            preconditionFailure("VocalURL produced invalid components: \(components)")
        }
        return url
    }

    /// Parses a link the app was opened with. Returns nil for anything that is
    /// not a Vocal link, so the caller can pass other URLs on untouched.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // `vocal://arm` puts "arm" in `host`; `vocal:arm` puts it in `path`.
        // Accepting both keeps hand-typed and widget-built links equivalent.
        let rawHost = components?.host ?? url.host
        let candidate = rawHost?.lowercased()
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let host = Host(rawValue: candidate) else { return nil }

        switch host {
        case .dictate:
            self = .dictate
        case .imports:
            self = .imports
        case .arm:
            let items = components?.queryItems ?? []
            let windowRaw = items.first { $0.name == QueryKey.window.rawValue }?.value
            let profile = items.first { $0.name == QueryKey.profile.rawValue }?.value
            let window = windowRaw.flatMap(CaptureWindow.init(rawValue:)) ?? .default
            self = .arm(
                window: window,
                profileName: (profile?.isEmpty ?? true) ? nil : profile
            )
        }
    }
}
