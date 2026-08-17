import Foundation

/// One voice note handed to Vocal through the share sheet (docs/02 FR-i2.3).
///
/// The manifest is written *after* its audio payload, so the presence of a
/// manifest is the commit record: a share extension killed mid-copy leaves an
/// orphan audio file that ``ImportInbox/sweepOrphans(olderThan:now:)`` reaps,
/// never a half-readable import.
public struct ImportManifest: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Name to show the user and store on the history row.
    public var originalFilename: String
    /// Name of the audio payload inside the inbox directory.
    public var storedFilename: String
    public var receivedAt: Date
    public var byteCount: Int64
    /// Attempts the app has already made. Lets a file that reliably crashes
    /// the decoder be retired instead of retried forever.
    public var attemptCount: Int
    /// Why the last attempt failed, shown in the import list.
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        originalFilename: String,
        storedFilename: String,
        receivedAt: Date,
        byteCount: Int64,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.receivedAt = receivedAt
        self.byteCount = byteCount
        self.attemptCount = attemptCount
        self.lastError = lastError
    }

    /// Give up after three failures rather than looping on a corrupt file.
    public static let maximumAttempts = 3

    public var isExhausted: Bool { attemptCount >= Self.maximumAttempts }
}

/// The share-sheet import queue, as a directory rather than a shared list file.
///
/// Two processes write here — the share extension creates items, the app
/// consumes them — so a single mutable queue file would need cross-process
/// locking. Instead each item is its own pair of files under a fresh UUID:
/// creation never contends, and after intake the app is the only writer of a
/// given manifest. That is what makes this safe without `NSFileCoordinator`.
public struct ImportInbox: Sendable {
    public let container: BridgeContainer
    private let fileManager = FileManager.default

    public init(container: BridgeContainer) {
        self.container = container
    }

    public static func appGroup(in bundle: Bundle = .main) -> ImportInbox? {
        BridgeContainer.appGroup(in: bundle).map(ImportInbox.init(container:))
    }

    private func manifestURL(_ id: UUID) -> URL {
        container.inboxDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// Absolute location of an item's audio payload.
    public func audioURL(for manifest: ImportManifest) -> URL {
        container.inboxDirectory.appendingPathComponent(
            manifest.storedFilename, isDirectory: false
        )
    }

    // MARK: - Producer side (share extension)

    /// Copies `sourceURL` into the inbox and commits a manifest for it.
    ///
    /// `originalFilename` is what the user saw in the sharing app; the stored
    /// name is UUID-derived so two "Audio Message.m4a" imports cannot collide.
    @discardableResult
    public func accept(
        contentsOf sourceURL: URL,
        originalFilename: String,
        now: Date = Date()
    ) throws -> ImportManifest {
        try container.prepare()
        let id = UUID()
        let storedFilename = Self.storedFilename(for: id, originalFilename: originalFilename)
        let destination = container.inboxDirectory.appendingPathComponent(
            storedFilename, isDirectory: false
        )
        do {
            // Copy rather than move: the provider's URL is often a
            // system-owned temporary the extension may not relocate.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw BridgeError.writeFailed("import copy failed: \(error)")
        }

        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let manifest = ImportManifest(
            id: id,
            originalFilename: originalFilename,
            storedFilename: storedFilename,
            receivedAt: now,
            byteCount: byteCount
        )
        do {
            try commit(manifest)
        } catch {
            // Never leave audio without its commit record.
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return manifest
    }

    // MARK: - Consumer side (container app)

    /// Every committed item, oldest first. Unreadable manifests are skipped
    /// rather than failing the whole listing — one bad file must not hide the
    /// rest of the queue.
    public func all() -> [ImportManifest] {
        guard
            let names = try? fileManager.contentsOfDirectory(
                atPath: container.inboxDirectory.path
            )
        else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ImportManifest? in
                let url = container.inboxDirectory.appendingPathComponent(name, isDirectory: false)
                guard let data = fileManager.contents(atPath: url.path), !data.isEmpty else {
                    return nil
                }
                return try? BridgeCodec.decode(ImportManifest.self, from: data)
            }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Items still worth attempting.
    public func pending() -> [ImportManifest] {
        all().filter { !$0.isExhausted }
    }

    /// Items that used up their attempts. Kept on disk so the app can show
    /// what failed and why instead of losing the note silently.
    public func failed() -> [ImportManifest] {
        all().filter(\.isExhausted)
    }

    public func pendingCount() -> Int { pending().count }

    /// Rewrites a manifest — used to record a failed attempt.
    public func commit(_ manifest: ImportManifest) throws {
        try container.prepare()
        let data = try BridgeCodec.encode(manifest)
        do {
            try data.write(to: manifestURL(manifest.id), options: BridgeStore.writeOptions)
        } catch {
            throw BridgeError.writeFailed("import manifest: \(error)")
        }
    }

    /// Records one failed attempt, returning the updated manifest.
    @discardableResult
    public func noteFailure(_ manifest: ImportManifest, reason: String) throws -> ImportManifest {
        var updated = manifest
        updated.attemptCount += 1
        updated.lastError = reason
        try commit(updated)
        return updated
    }

    /// Removes an item and its audio once it has landed in history.
    public func remove(_ manifest: ImportManifest) {
        try? fileManager.removeItem(at: audioURL(for: manifest))
        try? fileManager.removeItem(at: manifestURL(manifest.id))
    }

    /// Deletes audio files that no manifest claims and that are older than
    /// `interval` — the debris of a share extension killed mid-copy.
    ///
    /// The age check matters: a copy in flight right now has no manifest yet
    /// and must not be swept out from under the extension writing it.
    @discardableResult
    public func sweepOrphans(olderThan interval: TimeInterval, now: Date = Date()) -> Int {
        guard
            let names = try? fileManager.contentsOfDirectory(
                atPath: container.inboxDirectory.path
            )
        else { return 0 }

        let claimed = Set(
            names
                .filter { $0.hasSuffix(".json") }
                .compactMap { name -> String? in
                    let url = container.inboxDirectory.appendingPathComponent(
                        name, isDirectory: false
                    )
                    guard let data = fileManager.contents(atPath: url.path) else { return nil }
                    return try? BridgeCodec.decode(ImportManifest.self, from: data).storedFilename
                }
        )

        var removed = 0
        for name in names where !name.hasSuffix(".json") && !claimed.contains(name) {
            let url = container.inboxDirectory.appendingPathComponent(name, isDirectory: false)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard
                let modified = attributes?[.modificationDate] as? Date,
                now.timeIntervalSince(modified) > interval
            else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Naming

    /// UUID-prefixed so names are unique, extension preserved so the audio
    /// decoder can pick a reader from it.
    static func storedFilename(for id: UUID, originalFilename: String) -> String {
        let ext = URL(fileURLWithPath: originalFilename).pathExtension.lowercased()
        let sanitized = ext.filter { $0.isLetter || $0.isNumber }
        return sanitized.isEmpty
            ? "\(id.uuidString).audio"
            : "\(id.uuidString).\(sanitized)"
    }
}
