import BridgeKit
import Combine
import Foundation
import SwiftUI

/// Everything the Vocal keyboard knows, and nothing it does.
///
/// The extension is an insert-only surface (docs/02 §3.1 D2b): it never
/// records, never loads a model, and never touches the network. It reads the
/// app's published status, posts requests, and inserts what comes back —
/// with the decisions themselves living in `KeyboardBridgePolicy`, where
/// Linux CI can test them.
@MainActor
final class KeyboardModel: ObservableObject {

    /// Result waiting for the user's ✓ / ✗ when auto-insert is off.
    struct PendingInsert: Equatable {
        var text: String
        var profileName: String
    }

    @Published private(set) var micAction: MicKeyAction = .busy(message: "Connecting…")
    @Published private(set) var statusLine = ""
    @Published private(set) var pendingInsert: PendingInsert?
    /// Transient one-line message (errors, "transcribing…").
    @Published private(set) var notice: String?
    @Published private(set) var profileNames: [String] = []
    /// Profile chosen on the keyboard, overriding the armed session's default
    /// (FR-i2.2 — iOS exposes no host-app identity to route on).
    @Published var chosenProfileName: String?

    /// UIKit actions, injected by the view controller so this type stays
    /// testable and free of UIInputViewController.
    var insertText: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }

    private let store: BridgeStore?
    private let hasFullAccess: () -> Bool
    private let now: () -> Date
    private var awaitingRequestID: UUID?
    private var pollTask: Task<Void, Never>?
    #if canImport(Darwin)
    private var subscriptions: [DarwinSignalCenter.Subscription] = []
    #endif

    /// How often the keyboard re-reads the status file when nothing is in
    /// flight. Darwin signals do the real work; this only covers a coalesced
    /// or missed ping.
    private static let idlePollInterval = Duration.seconds(2)
    /// Tighter cadence while a transcript is expected.
    private static let activePollInterval = Duration.milliseconds(350)

    init(
        store: BridgeStore? = BridgeStore.appGroup(),
        hasFullAccess: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.hasFullAccess = hasFullAccess
        self.now = now
    }

    // MARK: - Lifecycle

    func start() {
        #if canImport(Darwin)
        if subscriptions.isEmpty {
            for signal in [BridgeSignal.statusChanged, .replyPosted] {
                subscriptions.append(
                    DarwinSignalCenter.shared.observe(signal) { [weak self] in
                        // Signals arrive on the notify centre's own thread.
                        Task { @MainActor in self?.refresh() }
                    }
                )
            }
        }
        #endif
        refresh()
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        #if canImport(Darwin)
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        #endif
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval =
                    self.awaitingRequestID == nil
                    ? Self.idlePollInterval : Self.activePollInterval
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    // MARK: - Reading

    /// A failed read is indistinguishable from "nothing published yet" for the
    /// keyboard's purposes: both mean it must not assume a live session.
    private func currentStatus() -> BridgeStatus? {
        guard let store else { return nil }
        return (try? store.readStatus()) ?? nil
    }

    func refresh() {
        let moment = now()
        let status = currentStatus()

        profileNames = status?.availableProfileNames ?? []
        if let chosen = chosenProfileName, !profileNames.contains(chosen) {
            chosenProfileName = nil
        }
        statusLine = KeyboardBridgePolicy.statusLine(for: status, at: moment)
        micAction = KeyboardBridgePolicy.micKeyAction(
            status: status,
            hasFullAccess: hasFullAccess(),
            containerReachable: store != nil,
            now: moment
        )

        // Recover the in-flight take after the keyboard was torn down and
        // rebuilt mid-dictation (iOS does that freely).
        if awaitingRequestID == nil, let active = status?.activeRequestID {
            awaitingRequestID = active
        }

        consumeReplyIfReady(autoInsert: status?.autoInsert ?? false, at: moment)
    }

    private func consumeReplyIfReady(autoInsert: Bool, at moment: Date) {
        guard let store, let reply = (try? store.readReply()) ?? nil else { return }

        // Gate on "is this ours and recent", not on "is it insertable" — a
        // cancellation or a failure is ours too, and the user should hear
        // about it now rather than when it ages out of the slot.
        guard
            KeyboardBridgePolicy.isCurrent(
                reply: reply, awaitingRequestID: awaitingRequestID, now: moment
            )
        else {
            // Not ours (or not yet). Reap it once it can no longer be anyone's,
            // so a dead reply cannot sit in the slot forever.
            if moment.timeIntervalSince(reply.producedAt)
                > KeyboardBridgePolicy.replyFreshnessWindow
            {
                try? store.clear(.reply)
            }
            return
        }

        try? store.clear(.reply)
        awaitingRequestID = nil
        guard
            KeyboardBridgePolicy.shouldInsert(
                reply: reply, awaitingRequestID: reply.requestID, now: moment
            ),
            let text = reply.insertableText
        else {
            surfaceNonTextOutcome(reply)
            return
        }

        notice = nil
        if autoInsert {
            insertText(text)
        } else {
            pendingInsert = PendingInsert(text: text, profileName: reply.profileName)
        }
    }

    private func surfaceNonTextOutcome(_ reply: BridgeReply) {
        switch reply.outcome {
        case .failed(let reason): notice = reason
        case .cancelled: notice = "Dictation cancelled"
        case .text: break
        }
    }

    // MARK: - Actions

    func micKeyTapped() {
        switch micAction {
        case .startRecording:
            post(command: .startRecording, id: UUID())
        case .stopRecording(let requestID):
            post(command: .stopRecording, id: requestID)
        case .openApp(let url):
            openURL(url)
        case .busy(let message), .unavailable(let message):
            notice = message
        }
    }

    /// Long-press on the mic key while recording: throw the take away.
    func cancelRecording() {
        guard case .stopRecording(let requestID) = micAction else { return }
        post(command: .cancelRecording, id: requestID)
        awaitingRequestID = nil
        pendingInsert = nil
        notice = "Cancelled"
    }

    func confirmPendingInsert() {
        guard let pending = pendingInsert else { return }
        insertText(pending.text)
        pendingInsert = nil
    }

    func discardPendingInsert() {
        pendingInsert = nil
    }

    func dismissNotice() {
        notice = nil
    }

    private func post(command: BridgeCommand, id: UUID) {
        guard let store else {
            notice = KeyboardBridgePolicy.fullAccessMessage
            return
        }
        let request = BridgeRequest(
            id: id,
            command: command,
            issuedAt: now(),
            requestedProfileName: chosenProfileName
        )
        do {
            try store.writeRequest(request)
        } catch {
            notice = "Could not reach Vocal. Open the app once and try again."
            return
        }
        awaitingRequestID = command == .cancelRecording ? nil : id
        notice = command == .startRecording ? "Listening…" : nil
        #if canImport(Darwin)
        DarwinSignalCenter.shared.post(.requestPosted)
        #endif
        // Reflect the press immediately rather than waiting a poll cycle.
        refresh()
    }
}
