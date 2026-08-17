import CoreModels
import Foundation
import Testing

@testable import ModelStore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSpec(
    engine: String = "whisperkit",
    id: String = "model",
    approximateBytes: Int64 = 1_000,
    files: [ModelFileSpec] = []
) -> ModelSpec {
    ModelSpec(
        id: id,
        displayName: "Test Model",
        engine: engine,
        languages: [.english, .chinese],
        approximateBytes: approximateBytes,
        files: files
    )
}

private func fileSpec(
    _ relativePath: String,
    bytes: Int64,
    sha256: String? = nil
) throws -> ModelFileSpec {
    ModelFileSpec(
        relativePath: relativePath,
        url: try #require(URL(string: "https://example.com/\(relativePath)")),
        sha256: sha256,
        bytes: bytes
    )
}

private func writeFile(at url: URL, bytes count: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(repeating: 0xAB, count: count).write(to: url)
}

// MARK: - Catalog

@Test func builtInCatalogListsWhisperKitEnglishChineseModels() {
    let ids = ModelCatalog.builtIn.map(\.id)
    #expect(ids.contains("whisper-large-v3-turbo"))
    #expect(ids.contains("whisper-small"))
    for spec in ModelCatalog.builtIn {
        #expect(spec.engine == "whisperkit")
        #expect(spec.approximateBytes > 0)
        #expect(spec.languages.contains(.english))
        #expect(spec.languages.contains(.chinese))
        // WhisperKit manages its own downloads, so the built-ins list no files.
        #expect(spec.files.isEmpty)
    }
}

@Test func builtInCatalogRoundTripsThroughJSON() throws {
    let data = try JSONEncoder().encode(ModelCatalog.builtIn)
    let decoded = try JSONDecoder().decode([ModelSpec].self, from: data)
    #expect(decoded == ModelCatalog.builtIn)
}

@Test func specWithFilesRoundTripsThroughJSON() throws {
    let spec = makeSpec(
        approximateBytes: 42,
        files: [
            try fileSpec(
                "weights/model.bin",
                bytes: 42,
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        ]
    )
    let data = try JSONEncoder().encode(spec)
    let decoded = try JSONDecoder().decode(ModelSpec.self, from: data)
    #expect(decoded == spec)
}

// MARK: - installedState

@Test func installedStateIsNotInstalledWithoutDirectory() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)

    let state = await store.installedState(of: makeSpec())
    #expect(state == .notInstalled)
}

@Test func installedStateIsNotInstalledForEmptyDirectory() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec()
    try FileManager.default.createDirectory(
        at: store.directory(for: spec),
        withIntermediateDirectories: true
    )

    let state = await store.installedState(of: spec)
    #expect(state == .notInstalled)
}

@Test func byteThresholdSeparatesPartialFromInstalled() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec(approximateBytes: 1_000)
    let weights = store.directory(for: spec).appendingPathComponent("weights.bin")

    try writeFile(at: weights, bytes: 799)
    let below = await store.installedState(of: spec)
    #expect(below == .partial)

    try writeFile(at: weights, bytes: 800)
    let atThreshold = await store.installedState(of: spec)
    #expect(atThreshold == .installed)
}

@Test func listedFilesUseSummedBytesAsThreshold() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)
    // Summed file bytes (1000) override approximateBytes (9999): 80% = 800.
    let spec = makeSpec(
        approximateBytes: 9_999,
        files: [
            try fileSpec("a.bin", bytes: 600),
            try fileSpec("weights/b.bin", bytes: 400),
        ]
    )
    let dir = store.directory(for: spec)

    try writeFile(at: dir.appendingPathComponent("a.bin"), bytes: 600)
    let missingFile = await store.installedState(of: spec)
    #expect(missingFile == .partial)

    try writeFile(at: dir.appendingPathComponent("weights/b.bin"), bytes: 150)
    let truncated = await store.installedState(of: spec)
    #expect(truncated == .partial)

    try writeFile(at: dir.appendingPathComponent("weights/b.bin"), bytes: 250)
    let complete = await store.installedState(of: spec)
    #expect(complete == .installed)
}

@Test func enoughBytesButMissingListedFileIsPartial() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec(
        files: [
            try fileSpec("a.bin", bytes: 500),
            try fileSpec("b.bin", bytes: 500),
        ]
    )

    try writeFile(at: store.directory(for: spec).appendingPathComponent("a.bin"), bytes: 1_000)
    let state = await store.installedState(of: spec)
    #expect(state == .partial)
}

// MARK: - downloadedBytes

@Test func downloadedBytesSumsNestedRegularFiles() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec()
    let dir = store.directory(for: spec)
    try writeFile(at: dir.appendingPathComponent("a.bin"), bytes: 100)
    try writeFile(at: dir.appendingPathComponent("sub/b.bin"), bytes: 250)

    let bytes = await store.downloadedBytes(of: spec)
    #expect(bytes == 350)
}

@Test func downloadedBytesIsZeroWithoutDirectory() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)

    let bytes = await store.downloadedBytes(of: makeSpec())
    #expect(bytes == 0)
}

// MARK: - delete hardening

@Test func deleteRemovesExactDirectoryAndSparesSimilarPrefixSibling() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec(id: "model")
    let target = store.directory(for: spec)
    let sibling = root.appendingPathComponent("whisperkit/model-extra", isDirectory: true)
    try writeFile(at: target.appendingPathComponent("weights.bin"), bytes: 10)
    try writeFile(at: sibling.appendingPathComponent("weights.bin"), bytes: 10)

    try await store.delete(spec)

    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("weights.bin").path))
}

@Test func deleteOfMissingDirectoryIsANoOp() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)

    try await store.delete(makeSpec())
}

@Test func deleteRefusesTraversalIdentifiers() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(rootDirectory: root)

    for id in ["..", "../evil", "models/nested", "", "."] {
        let spec = makeSpec(id: id)
        await #expect(throws: ModelStoreError.refusedUnsafePath) {
            try await store.delete(spec)
        }
    }
    let engineSpec = makeSpec(engine: "../outside")
    await #expect(throws: ModelStoreError.refusedUnsafePath) {
        try await store.delete(engineSpec)
    }
}

@Test func deleteRefusesSymlinkPointingOutsideRoot() async throws {
    let base = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("root", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    try writeFile(at: outside.appendingPathComponent("precious.bin"), bytes: 10)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("whisperkit", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("whisperkit/model"),
        withDestinationURL: outside
    )

    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec(id: "model")
    await #expect(throws: ModelStoreError.refusedUnsafePath) {
        try await store.delete(spec)
    }
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("precious.bin").path))
}

/// A sibling root with a similar prefix ("root-evil" vs "root") must never be
/// treated as inside the store — the classic `hasPrefix` substring trap.
@Test func deleteRefusesSimilarPrefixRootEscape() async throws {
    let base = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("root", isDirectory: true)
    let evilModelDir = base.appendingPathComponent("root-evil/whisperkit/model", isDirectory: true)
    try writeFile(at: evilModelDir.appendingPathComponent("weights.bin"), bytes: 10)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("whisperkit", isDirectory: true),
        withIntermediateDirectories: true
    )
    // Last two components of the resolved target equal <engine>/<id> exactly,
    // so only the strictly-inside-root check can refuse this.
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("whisperkit/model"),
        withDestinationURL: evilModelDir
    )

    let store = ModelStore(rootDirectory: root)
    let spec = makeSpec(id: "model")
    await #expect(throws: ModelStoreError.refusedUnsafePath) {
        try await store.delete(spec)
    }
    #expect(FileManager.default.fileExists(atPath: evilModelDir.appendingPathComponent("weights.bin").path))
}

// MARK: - ModelDownloader request construction (no network)

@Test func partialFileURLIsSiblingWithPartialExtension() {
    let destination = URL(fileURLWithPath: "/models/whisperkit/model/weights.bin")
    let partial = ModelDownloader.partialFileURL(for: destination)
    #expect(partial.lastPathComponent == "weights.bin.partial")
    #expect(partial.deletingLastPathComponent().path == destination.deletingLastPathComponent().path)
}

@Test func requestCarriesRangeHeaderWhenPartialExists() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("weights.bin")
    let partial = ModelDownloader.partialFileURL(for: destination)
    try writeFile(at: partial, bytes: 1_234)

    let resumeOffset = ModelDownloader.existingPartialBytes(at: partial)
    #expect(resumeOffset == 1_234)

    let request = ModelDownloader.makeRequest(
        for: try fileSpec("weights.bin", bytes: 5_000),
        resumingFrom: resumeOffset
    )
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=1234-")
}

@Test func requestOmitsRangeHeaderWithoutPartial() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("weights.bin")
    let partial = ModelDownloader.partialFileURL(for: destination)
    #expect(ModelDownloader.existingPartialBytes(at: partial) == 0)

    let file = try fileSpec("weights.bin", bytes: 5_000)
    let request = ModelDownloader.makeRequest(for: file, resumingFrom: 0)
    #expect(request.value(forHTTPHeaderField: "Range") == nil)
    #expect(request.url == file.url)
}
