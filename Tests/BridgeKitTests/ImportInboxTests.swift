import Foundation
import Testing

@testable import BridgeKit

@Suite("Share-sheet import inbox")
struct ImportInboxTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeInbox() throws -> ImportInbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportInboxTests-\(UUID().uuidString)", isDirectory: true)
        let container = BridgeContainer(root: root)
        try container.prepare()
        return ImportInbox(container: container)
    }

    private func makeSourceFile(named name: String, bytes: Int = 32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)", isDirectory: false)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test("Accepting a voice note copies the audio and commits a manifest")
    func acceptCopiesAndCommits() throws {
        let inbox = try makeInbox()
        let source = try makeSourceFile(named: "Audio Message.m4a", bytes: 64)

        let manifest = try inbox.accept(
            contentsOf: source, originalFilename: "Audio Message.m4a", now: epoch
        )

        #expect(manifest.originalFilename == "Audio Message.m4a")
        #expect(manifest.storedFilename.hasSuffix(".m4a"))
        #expect(manifest.byteCount == 64)
        #expect(manifest.attemptCount == 0)
        #expect(FileManager.default.fileExists(atPath: inbox.audioURL(for: manifest).path))
        // The source is copied, never moved — the provider owns that URL.
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(inbox.pending().map(\.id) == [manifest.id])
    }

    @Test("Same-named notes never collide")
    func identicalNamesDoNotCollide() throws {
        let inbox = try makeInbox()
        let first = try inbox.accept(
            contentsOf: try makeSourceFile(named: "note.m4a"),
            originalFilename: "note.m4a",
            now: epoch
        )
        let second = try inbox.accept(
            contentsOf: try makeSourceFile(named: "note.m4a"),
            originalFilename: "note.m4a",
            now: epoch.addingTimeInterval(1)
        )
        #expect(first.storedFilename != second.storedFilename)
        #expect(inbox.pending().count == 2)
    }

    @Test("Pending items come back oldest first")
    func pendingIsOrdered() throws {
        let inbox = try makeInbox()
        let later = try inbox.accept(
            contentsOf: try makeSourceFile(named: "b.m4a"),
            originalFilename: "b.m4a",
            now: epoch.addingTimeInterval(60)
        )
        let earlier = try inbox.accept(
            contentsOf: try makeSourceFile(named: "a.m4a"),
            originalFilename: "a.m4a",
            now: epoch
        )
        #expect(inbox.pending().map(\.id) == [earlier.id, later.id])
    }

    @Test("Removing an item takes its audio with it")
    func removeDeletesBothFiles() throws {
        let inbox = try makeInbox()
        let manifest = try inbox.accept(
            contentsOf: try makeSourceFile(named: "note.m4a"),
            originalFilename: "note.m4a",
            now: epoch
        )
        inbox.remove(manifest)
        #expect(inbox.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: inbox.audioURL(for: manifest).path))
    }

    @Test("A file that keeps failing is retired instead of retried forever")
    func failuresExhaust() throws {
        let inbox = try makeInbox()
        var manifest = try inbox.accept(
            contentsOf: try makeSourceFile(named: "corrupt.m4a"),
            originalFilename: "corrupt.m4a",
            now: epoch
        )
        for attempt in 1...ImportManifest.maximumAttempts {
            manifest = try inbox.noteFailure(manifest, reason: "decode failed")
            #expect(manifest.attemptCount == attempt)
        }
        #expect(manifest.isExhausted)
        #expect(inbox.pending().isEmpty)
        // It stays on disk and visible so the user learns why it failed.
        #expect(inbox.failed().map(\.id) == [manifest.id])
        #expect(inbox.failed().first?.lastError == "decode failed")
    }

    @Test("One unreadable manifest does not hide the rest of the queue")
    func corruptManifestIsSkipped() throws {
        let inbox = try makeInbox()
        let good = try inbox.accept(
            contentsOf: try makeSourceFile(named: "good.m4a"),
            originalFilename: "good.m4a",
            now: epoch
        )
        try Data("not json".utf8).write(
            to: inbox.container.inboxDirectory.appendingPathComponent("\(UUID().uuidString).json")
        )
        #expect(inbox.pending().map(\.id) == [good.id])
    }

    @Test("Orphan audio is swept only once it is old enough")
    func orphanSweepRespectsAge() throws {
        let inbox = try makeInbox()
        let claimed = try inbox.accept(
            contentsOf: try makeSourceFile(named: "kept.m4a"),
            originalFilename: "kept.m4a",
            now: epoch
        )
        let orphan = inbox.container.inboxDirectory
            .appendingPathComponent("orphan.m4a", isDirectory: false)
        try Data(repeating: 1, count: 16).write(to: orphan)

        // A copy that may still be in flight is left alone.
        #expect(inbox.sweepOrphans(olderThan: 3_600) == 0)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        // Once it is clearly abandoned it goes, and the claimed audio stays.
        let later = Date().addingTimeInterval(7_200)
        #expect(inbox.sweepOrphans(olderThan: 3_600, now: later) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: inbox.audioURL(for: claimed).path))
        #expect(inbox.pending().map(\.id) == [claimed.id])
    }

    @Test("Stored names keep a usable extension, or fall back to one")
    func storedFilenameNaming() {
        let id = UUID()
        // The extension survives (the decoder picks a reader from it) and is
        // normalised to lower case.
        #expect(
            ImportInbox.storedFilename(for: id, originalFilename: "a.M4A") == "\(id.uuidString).m4a"
        )
        #expect(
            ImportInbox.storedFilename(for: id, originalFilename: "Audio Message.wav")
                == "\(id.uuidString).wav"
        )
        // No extension still yields a name the file system accepts.
        #expect(
            ImportInbox.storedFilename(for: id, originalFilename: "voice")
                == "\(id.uuidString).audio"
        )
        // Names are UUID-derived, so two imports can never overwrite each other.
        let other = UUID()
        #expect(
            ImportInbox.storedFilename(for: id, originalFilename: "note.m4a")
                != ImportInbox.storedFilename(for: other, originalFilename: "note.m4a")
        )
    }
}
