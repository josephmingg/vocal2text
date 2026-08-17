import Foundation

/// The shared directory tree, resolved once and passed around.
///
/// Construct with ``appGroup(in:)`` in a shipping target, or with `init(root:)`
/// pointing at a temporary directory in tests — every path below is derived,
/// so the same code runs identically on Linux CI and on a phone.
public struct BridgeContainer: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The App Group container, or nil when the entitlement is missing.
    public static func appGroup(in bundle: Bundle = .main) -> BridgeContainer? {
        AppGroup.containerURL(in: bundle).map(BridgeContainer.init(root:))
    }

    public var bridgeDirectory: URL {
        root.appendingPathComponent(AppGroup.bridgeDirectoryName, isDirectory: true)
    }

    public var inboxDirectory: URL {
        root.appendingPathComponent(AppGroup.inboxDirectoryName, isDirectory: true)
    }

    public func url(for slot: BridgeSlot) -> URL {
        bridgeDirectory.appendingPathComponent(slot.filename, isDirectory: false)
    }

    /// Creates the directory tree. Idempotent; safe to call from every process
    /// on every launch.
    public func prepare() throws {
        for directory in [bridgeDirectory, inboxDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
    }
}
