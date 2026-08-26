import Foundation

/// Where the container app and its extensions meet.
///
/// Everything the keyboard, the share extension, and the widget need from the
/// main app crosses a shared App Group container (docs/03 §6). This type owns
/// the *layout* of that container so no call site hard-codes a path, and it
/// resolves the group identifier from the bundle rather than a literal so
/// re-signing under a different team is a plist edit, not a code change.
public enum AppGroup {

    /// Info.plist key each Vocal target sets to the shared App Group ID.
    /// Declared in `project.yml` for every target that touches the container,
    /// so the identifier lives in exactly one place.
    public static let identifierInfoKey = "VocalAppGroupIdentifier"

    /// Compiled-in fallback used when the Info.plist key is missing — keeps
    /// unit tests and previews working without a bundle.
    public static let defaultIdentifier = "group.com.vocal.shared"

    /// Sub-directory of the group container holding the bridge slots.
    public static let bridgeDirectoryName = "bridge"

    /// Sub-directory holding audio files dropped in by the share extension.
    public static let inboxDirectoryName = "inbox"

    /// Resolves the group identifier from `bundle`, falling back to
    /// ``defaultIdentifier``.
    public static func identifier(in bundle: Bundle = .main) -> String {
        guard
            let value = bundle.object(forInfoDictionaryKey: identifierInfoKey) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return defaultIdentifier }
        return value
    }

    #if canImport(Darwin)
    /// The shared container URL, or nil when the App Group entitlement is
    /// missing — the honest signal that the keyboard cannot reach the app.
    public static func containerURL(in bundle: Bundle = .main) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier(in: bundle)
        )
    }
    #else
    /// Non-Apple platforms have no App Group containers; tests inject an
    /// explicit directory instead (see `BridgeContainer.init(root:)`).
    public static func containerURL(in bundle: Bundle = .main) -> URL? { nil }
    #endif
}
