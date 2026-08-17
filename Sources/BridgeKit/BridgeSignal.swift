import Foundation

/// The wake-ups that cross the process boundary.
///
/// Darwin notifications carry no payload and are coalesced by the kernel, so
/// they are used strictly as doorbells: the data always travels through the
/// App Group file the signal refers to. That also makes them safe to drop —
/// a missed ping costs a poll, never a transcript.
public enum BridgeSignal: String, Sendable, CaseIterable, Hashable {
    /// Keyboard → app: a new `request.json` is on disk.
    case requestPosted = "com.vocal.bridge.request"
    /// App → keyboard: a new `reply.json` is on disk.
    case replyPosted = "com.vocal.bridge.reply"
    /// App → keyboard: `status.json` changed (armed, expired, phase change).
    case statusChanged = "com.vocal.bridge.status"
}

#if canImport(Darwin)
import CoreFoundation

/// Posts and observes ``BridgeSignal``s over the Darwin notify centre.
///
/// A singleton because the underlying C callback cannot capture context: it
/// resolves the signal by name and fans out to the handlers registered here.
/// Handlers run on the notify centre's delivery thread — callers that touch UI
/// hop to the main actor themselves.
public final class DarwinSignalCenter: @unchecked Sendable {
    public static let shared = DarwinSignalCenter()

    /// Cancels one subscription. Held by the caller; deinit is not enough
    /// because the notify centre outlives every observer.
    public struct Subscription: Sendable {
        let signal: BridgeSignal
        let id: UUID
        public func cancel() {
            DarwinSignalCenter.shared.removeHandler(id: id, signal: signal)
        }
    }

    private let lock = NSLock()
    private var handlers: [BridgeSignal: [UUID: @Sendable () -> Void]] = [:]
    private var registered: Set<BridgeSignal> = []

    private init() {}

    /// Rings the doorbell for `signal`. Cheap and non-blocking; safe to call
    /// from any thread.
    public func post(_ signal: BridgeSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.rawValue as CFString),
            nil,
            nil,
            true
        )
    }

    /// Runs `handler` whenever `signal` arrives, until the returned
    /// subscription is cancelled.
    public func observe(
        _ signal: BridgeSignal,
        handler: @escaping @Sendable () -> Void
    ) -> Subscription {
        let id = UUID()
        lock.lock()
        handlers[signal, default: [:]][id] = handler
        let needsRegistration = registered.insert(signal).inserted
        lock.unlock()

        if needsRegistration {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                darwinSignalCallback,
                signal.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }
        return Subscription(signal: signal, id: id)
    }

    fileprivate func fire(rawName: String) {
        guard let signal = BridgeSignal(rawValue: rawName) else { return }
        lock.lock()
        let matching = Array((handlers[signal] ?? [:]).values)
        lock.unlock()
        for handler in matching { handler() }
    }

    private func removeHandler(id: UUID, signal: BridgeSignal) {
        lock.lock()
        handlers[signal]?[id] = nil
        lock.unlock()
        // The CF observer stays registered: re-registering costs more than the
        // no-op fan-out to an empty handler set, and signals are rare.
    }
}

/// C-ABI trampoline — cannot capture, so it resolves the singleton by name.
private let darwinSignalCallback: CFNotificationCallback = { _, _, name, _, _ in
    guard let rawName = name?.rawValue else { return }
    DarwinSignalCenter.shared.fire(rawName: rawName as String)
}

#endif
