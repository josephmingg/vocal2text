import Foundation
import Testing
@testable import AudioPipeline

/// A scratch directory that cleans itself up.
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reaper-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@discardableResult
private func makeFile(
    in directory: URL, named name: String, modified: Date
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data([0, 1, 2, 3]).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

struct RecoveryFileReaperTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func keepsRecoveryFilesInsideTheRetentionWindow() throws {
        try withTemporaryDirectory { directory in
            let fresh = try makeFile(
                in: directory,
                named: "vocal-capture-\(UUID().uuidString).pcmf32",
                modified: now.addingTimeInterval(-60 * 60)  // 1 h old
            )
            RecoveryFileReaper.reapExpiredRecoveryFiles(in: directory, now: now)
            #expect(exists(fresh))
        }
    }

    @Test func deletesRecoveryFilesPastTheRetentionWindow() throws {
        try withTemporaryDirectory { directory in
            let stale = try makeFile(
                in: directory,
                named: "vocal-capture-\(UUID().uuidString).pcmf32",
                modified: now.addingTimeInterval(-(RecoveryFileReaper.recoveryRetention + 60))
            )
            RecoveryFileReaper.reapExpiredRecoveryFiles(in: directory, now: now)
            #expect(!exists(stale))
        }
    }

    /// The sweep must be surgical: it runs against the shared temp directory,
    /// where everything else on the machine also keeps files.
    @Test func leavesUnrelatedFilesAlone() throws {
        try withTemporaryDirectory { directory in
            let ancient = now.addingTimeInterval(-(RecoveryFileReaper.recoveryRetention * 10))
            let otherPrefix = try makeFile(
                in: directory, named: "someone-elses.pcmf32", modified: ancient
            )
            let otherExtension = try makeFile(
                in: directory, named: "vocal-capture-notes.txt", modified: ancient
            )
            RecoveryFileReaper.reapExpiredRecoveryFiles(in: directory, now: now)
            #expect(exists(otherPrefix))
            #expect(exists(otherExtension))
        }
    }

    @Test func missingDirectoryIsANoOp() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-there-\(UUID().uuidString)", isDirectory: true)
        RecoveryFileReaper.reapExpiredRecoveryFiles(in: absent, now: now)
    }
}
