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
    /// The request this keyboard instance issued, and when.
    ///
    /// Deliberately never adopted from the app's published status. Each host
    /// app gets its own keyboard process with its own fresh model, so a
    /// keyboard that "recovered" an in-flight request ID would happily insert
    /// a transcript dictated in Messages into a Mail field. Losing the insert
    /// after a mid-take teardown is the cheaper failure — the transcript is
    /// still in History and on the clipboard.
    private var awaitingRequestID: UUID?
    private var awaitingSince: Date?
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
        // A preview belongs to the field it was dictated into; it must not
        // outlive this appearance of the keyboard.
        pendingInsert = nil
        #if canImport(Darwin)
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        #endif
    }

    /// The host app changed the text or moved the cursor.
    ///
    /// The keyboard cannot identify text fields — `textDocumentProxy` always
    /// addresses whatever is first responder *now* — so a pending preview is
    /// discarded the moment the input context moves. Otherwise tapping ✓ after
    /// switching from Mail's body to its To: field would file the paragraph in
    /// the wrong one.
    func inputContextChanged() {
        pendingInsert = nil
        refresh()
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

        expireStaleWait(at: moment)
        consumeReplyIfReady(autoInsert: status?.autoInsert ?? false, at: moment)
    }

    /// Stop waiting on a request the app will never answer.
    ///
    /// The app drops requests it was suspended through without replying, and
    /// it can be killed mid-take. Without this the keyboard would poll every
    /// 350 ms forever inside a jetsam-capped process and keep showing
    /// "Listening…".
    private func expireStaleWait(at moment: Date) {
        guard let since = awaitingSince,
            moment.timeIntervalSince(since) > KeyboardBridgePolicy.replyFreshnessWindow
        else { return }
        awaitingRequestID = nil
        awaitingSince = nil
        notice = "Vocal didn't answer. Open it once and try again."
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
        awaitingSince = nil
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

    /// Throw the current take away. Driven by its own key rather than a
    /// long-press on the mic: a `simultaneousGesture` does not suppress a
    /// `Button`'s action, so a long press would fire cancel *and then* stop,
    /// and the stop would overwrite the cancel in the single-slot request file.
    func cancelRecording() {
        guard case .stopRecording(let requestID) = micAction else { return }
        post(command: .cancelRecording, id: requestID)
        awaitingRequestID = nil
        awaitingSince = nil
        pendingInsert = nil
        notice = "Cancelled"
    }

    /// True while a take is running, so the view can offer the cancel key.
    var isRecording: Bool {
        if case .stopRecording = micAction { return true }
        return false
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
        let issuedAt = now()
        let request = BridgeRequest(
            id: id,
            command: command,
            issuedAt: issuedAt,
            requestedProfileName: chosenProfileName
        )
        do {
            try store.writeRequest(request)
        } catch {
            notice = "Could not reach Vocal. Open the app once and try again."
            return
        }
        if command == .cancelRecording {
            awaitingRequestID = nil
            awaitingSince = nil
        } else {
            awaitingRequestID = id
            awaitingSince = issuedAt
        }
        notice = command == .startRecording ? "Listening…" : nil
        #if canImport(Darwin)
        DarwinSignalCenter.shared.post(.requestPosted)
        #endif
        // Reflect the press immediately rather than waiting a poll cycle.
        refresh()
    }
}
