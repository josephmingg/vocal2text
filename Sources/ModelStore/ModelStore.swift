import CoreModels
import Foundation

/// Installation status of a model variant on disk.
public enum InstalledState: Sendable, Hashable {
    case notInstalled
    case partial
    case installed
}

/// Failures thrown by `ModelStore`.
public enum ModelStoreError: Error, Sendable, Equatable {
    /// `delete` refused: the target did not resolve to an exact `<engine>/<id>`
    /// directory strictly inside the store root (docs/09 lesson: never remove
    /// a user path by substring or through a symlink).
    case refusedUnsafePath
}

/// Owns the on-disk model directory tree: `<root>/<engine>/<id>/…`.
/// Install checks implement the docs/09 truncation guard; deletion is hardened
/// against traversal, prefix-collision, and symlink escapes.
public actor ModelStore {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// The install directory for `spec`: `rootDirectory/<engine>/<id>`.
    public nonisolated func directory(for spec: ModelSpec) -> URL {
        rootDirectory
            .appendingPathComponent(spec.engine, isDirectory: true)
            .appendingPathComponent(spec.id, isDirectory: true)
    }

    /// Truncation guard (docs/04 §5, docs/09): installed requires every listed
    /// file present AND total on-disk bytes ≥ 80% of the expected size (summed
    /// file bytes when the spec lists files, otherwise `approximateBytes`).
    public func installedState(of spec: ModelSpec) -> InstalledState {
        let dir = directory(for: spec)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .notInstalled
        }

        let total = onDiskBytes(in: dir)
        let allFilesPresent = spec.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(file.relativePath).path)
        }
        if total == 0 && (spec.files.isEmpty || !allFilesPresent) {
            return .notInstalled
        }
        let expected = expectedBytes(for: spec)
        if allFilesPresent && total * 10 >= expected * 8 {
            return .installed
        }
        return .partial
    }

    /// Total bytes of regular files currently inside the model's directory.
    public func downloadedBytes(of spec: ModelSpec) -> Int64 {
        onDiskBytes(in: directory(for: spec))
    }

    /// Removes the model's directory. Hardened (docs/09 lesson #11): refuses
    /// unless the symlink-resolved target sits strictly inside `rootDirectory`
    /// and its last two path components are exactly `<engine>/<id>` — no
    /// substring matches, no traversal, no symlink escape. Missing directory
    /// is a no-op.
    public func delete(_ spec: ModelSpec) throws {
        guard Self.isSingleSafePathComponent(spec.engine),
            Self.isSingleSafePathComponent(spec.id)
        else {
            throw ModelStoreError.refusedUnsafePath
        }
        let candidate = directory(for: spec)
        // lstat-style existence so a dangling symlink is still vetted below.
        guard FileInfo.attributes(atPath: candidate.path) != nil else { return }

        let resolvedRoot = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootParts = resolvedRoot.pathComponents
        let candidateParts = resolvedCandidate.pathComponents

        guard candidateParts.count == rootParts.count + 2,
            Array(candidateParts.prefix(rootParts.count)) == rootParts,
            candidateParts[candidateParts.count - 2] == spec.engine,
            candidateParts[candidateParts.count - 1] == spec.id
        else {
            throw ModelStoreError.refusedUnsafePath
        }
        try FileManager.default.removeItem(at: candidate)
    }

    private func expectedBytes(for spec: ModelSpec) -> Int64 {
        spec.files.isEmpty
            ? spec.approximateBytes
            : spec.files.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private func onDiskBytes(in directory: URL) -> Int64 {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: directory.path)
        else {
            return 0
        }
        var total: Int64 = 0
        for subpath in subpaths {
            if let size = FileInfo.regularFileSize(atPath: directory.appendingPathComponent(subpath).path) {
                total += size
            }
        }
        return total
    }

    private static func isSingleSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\u{0}")
    }
}

/// lstat-style file metadata helpers shared by the store and downloader
/// (`attributesOfItem` does not follow symlinks).
enum FileInfo {
    static func attributes(atPath path: String) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: path)
    }

    static func regularFileSize(atPath path: String) -> Int64? {
        guard let attrs = attributes(atPath: path),
            attrs[.type] as? FileAttributeType == .typeRegular
        else {
            return nil
        }
        return int64(attrs[.size])
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Int64 { return number }
        if let number = value as? UInt64 { return Int64(clamping: number) }
        if let number = value as? Int { return Int64(number) }
        return nil
    }
}
