import Foundation

/// Reads and writes the three bridge slots.
///
/// Concurrency is handled by construction rather than by locking: each slot
/// has exactly one writer (app → `status`/`reply`, keyboard → `request`) and
/// every write is atomic, so a reader always sees a whole previous value or a
/// whole new one — never a torn file. No cross-process lock is needed, which
/// matters because a keyboard extension cannot afford to block.
public struct BridgeStore: Sendable {
    public let container: BridgeContainer
    private let fileManager = FileManager.default

    public init(container: BridgeContainer) {
        self.container = container
    }

    /// Convenience for shipping targets; nil when the App Group is unreachable.
    public static func appGroup(in bundle: Bundle = .main) -> BridgeStore? {
        BridgeContainer.appGroup(in: bundle).map(BridgeStore.init(container:))
    }

    // MARK: - Slots

    public func readStatus() throws -> BridgeStatus? {
        try read(BridgeStatus.self, from: .status)
    }

    public func writeStatus(_ status: BridgeStatus) throws {
        try write(status, to: .status)
    }

    public func readRequest() throws -> BridgeRequest? {
        try read(BridgeRequest.self, from: .request)
    }

    public func writeRequest(_ request: BridgeRequest) throws {
        try write(request, to: .request)
    }

    public func readReply() throws -> BridgeReply? {
        try read(BridgeReply.self, from: .reply)
    }

    public func writeReply(_ reply: BridgeReply) throws {
        try write(reply, to: .reply)
    }

    /// Reads the reply and clears the slot in one step, so a transcript is
    /// inserted at most once even if the keyboard is re-shown mid-insert.
    ///
    /// The slot is cleared first: an insert that fails afterwards loses one
    /// transcript, whereas a slot that outlives its insert would duplicate
    /// text into the user's chat. History still holds the raw text either way.
    public func consumeReply() throws -> BridgeReply? {
        guard let reply = try readReply() else { return nil }
        try clear(.reply)
        return reply
    }

    public func clear(_ slot: BridgeSlot) throws {
        let url = container.url(for: slot)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw BridgeError.writeFailed("clear \(slot.rawValue): \(error)")
        }
    }

    // MARK: - Primitives

    private func read<Payload: Codable & Sendable>(
        _ type: Payload.Type,
        from slot: BridgeSlot
    ) throws -> Payload? {
        let url = container.url(for: slot)
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        // A zero-byte file is a write that never completed; treat it as absent
        // rather than surfacing a decode error the caller cannot act on.
        guard !data.isEmpty else { return nil }
        return try BridgeCodec.decode(type, from: data)
    }

    private func write<Payload: Codable & Sendable>(
        _ payload: Payload,
        to slot: BridgeSlot
    ) throws {
        let data = try BridgeCodec.encode(payload)
        try container.prepare()
        do {
            try data.write(to: container.url(for: slot), options: Self.writeOptions)
        } catch {
            throw BridgeError.writeFailed("write \(slot.rawValue): \(error)")
        }
    }

    /// Atomic everywhere; on iOS also pinned to a data-protection class the
    /// keyboard can still read on a device that has been unlocked once. The
    /// file-protection options do not exist on macOS or Linux, hence the
    /// narrow `os(iOS)` guard rather than a Darwin one.
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}
