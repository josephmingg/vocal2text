import CoreModels
import Foundation
import Testing

@testable import BridgeKit

private func makeContainer() throws -> BridgeContainer {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BridgeKitTests-\(UUID().uuidString)", isDirectory: true)
    let container = BridgeContainer(root: root)
    try container.prepare()
    return container
}

@Suite("Bridge codec")
struct BridgeCodecTests {

    @Test("Payloads round-trip through the envelope")
    func roundTrip() throws {
        let request = BridgeRequest(
            command: .startRecording,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            requestedProfileName: "Chat"
        )
        let decoded = try BridgeCodec.decode(
            BridgeRequest.self, from: BridgeCodec.encode(request)
        )
        #expect(decoded == request)
        // Sub-second precision survives — dates are seconds-since-1970 doubles,
        // not ISO-8601 strings.
        #expect(decoded.issuedAt.timeIntervalSince1970 == 1_700_000_000.25)
    }

    @Test("A newer protocol version is refused, not misread")
    func rejectsFutureSchema() throws {
        let future = Data(
            #"{"schemaVersion":99,"payload":{"unknown":true}}"#.utf8
        )
        do {
            _ = try BridgeCodec.decode(BridgeStatus.self, from: future)
            Issue.record("expected an unsupportedSchema failure")
        } catch let error as BridgeError {
            #expect(
                error
                    == .unsupportedSchema(
                        found: 99,
                        supported: BridgeSchema.minimumSupported...BridgeSchema.current
                    )
            )
        }
    }

    @Test("A payload without a version stamp is a decode failure")
    func rejectsUnstampedPayload() throws {
        let unstamped = Data(#"{"payload":{}}"#.utf8)
        do {
            _ = try BridgeCodec.decode(BridgeStatus.self, from: unstamped)
            Issue.record("expected a decodeFailed failure")
        } catch let error as BridgeError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test("Encoding stamps the current version")
    func stampsCurrentVersion() throws {
        let data = try BridgeCodec.encode(
            BridgeStatus(updatedAt: Date(timeIntervalSince1970: 0))
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == BridgeSchema.current)
    }
}

@Suite("Bridge store")
struct BridgeStoreTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Each slot round-trips independently")
    func slotsRoundTrip() throws {
        let store = BridgeStore(container: try makeContainer())
        let session = CaptureSessionState.armed(
            window: .fiveMinutes, profileName: "Chat", now: epoch
        )
        let status = BridgeStatus(
            updatedAt: epoch,
            session: session,
            phase: .recording,
            activeRequestID: UUID(),
            availableProfileNames: ["Chat", "Email"],
            pendingImportCount: 2
        )
        try store.writeStatus(status)
        #expect(try store.readStatus() == status)

        let request = BridgeRequest(command: .stopRecording, issuedAt: epoch)
        try store.writeRequest(request)
        #expect(try store.readRequest() == request)

        let reply = BridgeReply(
            requestID: request.id,
            producedAt: epoch,
            outcome: .text("你好，世界"),
            language: .chinese,
            profileName: "Chat"
        )
        try store.writeReply(reply)
        #expect(try store.readReply() == reply)
        // Slots do not interfere with each other.
        #expect(try store.readStatus() == status)
    }

    @Test("Missing slots read as nil rather than throwing")
    func missingSlotsAreNil() throws {
        let store = BridgeStore(container: try makeContainer())
        #expect(try store.readStatus() == nil)
        #expect(try store.readRequest() == nil)
        #expect(try store.readReply() == nil)
        // Clearing what was never written is a no-op, not an error.
        try store.clear(.reply)
    }

    @Test("A zero-byte slot reads as absent")
    func truncatedSlotIsAbsent() throws {
        let container = try makeContainer()
        let store = BridgeStore(container: container)
        try Data().write(to: container.url(for: .status))
        #expect(try store.readStatus() == nil)
    }

    @Test("consumeReply clears the slot so text is inserted at most once")
    func consumeReplyIsSingleShot() throws {
        let store = BridgeStore(container: try makeContainer())
        let reply = BridgeReply(
            requestID: UUID(),
            producedAt: epoch,
            outcome: .text("hello"),
            language: .english,
            profileName: "Default"
        )
        try store.writeReply(reply)
        #expect(try store.consumeReply() == reply)
        #expect(try store.consumeReply() == nil)
        #expect(try store.readReply() == nil)
    }

    @Test("Writes create the bridge directory on demand")
    func writesCreateDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeKitTests-\(UUID().uuidString)", isDirectory: true)
        // Deliberately not prepared: a first launch must not need a prior one.
        let store = BridgeStore(container: BridgeContainer(root: root))
        try store.writeStatus(BridgeStatus(updatedAt: epoch))
        #expect(try store.readStatus()?.updatedAt == epoch)
    }

    @Test("Reply outcomes distinguish text, cancelled, and failed")
    func replyOutcomes() throws {
        let store = BridgeStore(container: try makeContainer())
        let id = UUID()

        try store.writeReply(
            BridgeReply(
                requestID: id, producedAt: epoch, outcome: .cancelled, profileName: "Default"
            )
        )
        #expect(try store.readReply()?.insertableText == nil)

        try store.writeReply(
            BridgeReply(
                requestID: id,
                producedAt: epoch,
                outcome: .failed(reason: "model not installed"),
                profileName: "Default"
            )
        )
        let failed = try #require(store.readReply())
        #expect(failed.insertableText == nil)
        #expect(failed.outcome == .failed(reason: "model not installed"))

        try store.writeReply(
            BridgeReply(
                requestID: id, producedAt: epoch, outcome: .text("ok"), profileName: "Default"
            )
        )
        #expect(try store.readReply()?.insertableText == "ok")
    }
}

@Suite("Bridge status readiness")
struct BridgeStatusTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A new recording needs an armed session and an idle app")
    func acceptsNewRecording() {
        let armed = CaptureSessionState.armed(
            window: .fiveMinutes, profileName: "Chat", now: epoch
        )
        #expect(
            BridgeStatus(updatedAt: epoch, session: armed, phase: .idle)
                .acceptsNewRecording(at: epoch)
        )
        #expect(
            !BridgeStatus(updatedAt: epoch, session: armed, phase: .recording)
                .acceptsNewRecording(at: epoch)
        )
        #expect(
            !BridgeStatus(updatedAt: epoch, session: nil, phase: .idle)
                .acceptsNewRecording(at: epoch)
        )
        #expect(
            !BridgeStatus(updatedAt: epoch, session: armed, phase: .idle)
                .acceptsNewRecording(at: epoch.addingTimeInterval(600))
        )
    }
}

@Suite("App Group layout")
struct AppGroupTests {

    @Test("The identifier falls back when no bundle key is set")
    func identifierFallsBack() {
        // The test bundle carries no VocalAppGroupIdentifier key.
        #expect(AppGroup.identifier(in: .main) == AppGroup.defaultIdentifier)
    }

    @Test("Container paths derive from the root")
    func containerLayout() {
        let container = BridgeContainer(root: URL(fileURLWithPath: "/tmp/group", isDirectory: true))
        #expect(container.bridgeDirectory.lastPathComponent == AppGroup.bridgeDirectoryName)
        #expect(container.inboxDirectory.lastPathComponent == AppGroup.inboxDirectoryName)
        #expect(container.url(for: .status).lastPathComponent == "status.json")
        #expect(container.url(for: .request).lastPathComponent == "request.json")
        #expect(container.url(for: .reply).lastPathComponent == "reply.json")
        #expect(BridgeSlot.allCases.count == 3)
    }

    @Test("Signal names are distinct and reverse-DNS")
    func signalNames() {
        let names = Set(BridgeSignal.allCases.map(\.rawValue))
        #expect(names.count == BridgeSignal.allCases.count)
        #expect(names.allSatisfy { $0.hasPrefix("com.vocal.bridge.") })
    }
}
