import BridgeKit
import Combine
import CoreModels
import Foundation
import SwiftUI

/// The container app's half of the keyboard bridge (docs/02 §3.1, design D2b).
///
/// The keyboard is a delivery surface; this is the thing that actually
/// records, transcribes, and answers. It:
///
/// - arms a time-boxed capture session and holds audio residency for it,
/// - publishes a status file the keyboard reads,
/// - answers `request.json` doorbells by driving the ordinary
///   `DictationSession` — the keyboard path and the in-app path run the exact
///   same pipeline, so there is no second code path to keep correct,
/// - writes the transcript back as `reply.json`,
/// - and drives the Live Activity for *every* take, keyboard-initiated or not.
///
/// All of its decisions come from `BridgeKit`, which Linux CI tests; what
/// lives here is the wiring those decisions drive.
@MainActor
final class CaptureSessionCoordinator: ObservableObject {

    @Published private(set) var session: CaptureSessionState?
    @Published private(set) var lastNotice: String?
    @Published private(set) var pendingImportCount = 0
    /// FR-i2.2: skip the keyboard's ✓/✗ review row.
    @Published var autoInsert: Bool {
        didSet {
            UserDefaults.standard.set(autoInsert, forKey: Self.autoInsertKey)
            publishStatus()
        }
    }

    private static let autoInsertKey = "keyboardAutoInsert"
    /// Republish often enough that the keyboard's 90 s freshness window never
    /// lapses while the app is genuinely alive.
    private static let heartbeatInterval: TimeInterval = 30

    private let store: BridgeStore?
    private let inbox: ImportInbox?
    private let liveActivity = LiveActivityController()
    private let residency = CaptureResidency()
    private weak var appState: IOSAppState?

    private var phase: BridgeStatus.Phase = .idle
    private var activeRequestID: UUID?
    private var handledRequest: BridgeRequest?
    private var takeStartedAt: Date?
    private var takeID = UUID()
    private var heartbeat: Task<Void, Never>?
    #if canImport(Darwin)
    private var subscription: DarwinSignalCenter.Subscription?
    #endif

    /// True when the App Group is reachable — false means the keyboard cannot
    /// be reached at all, which the settings screen explains rather than
    /// letting the user wonder why the mic key bounces.
    var isBridgeAvailable: Bool { store != nil }

    init(store: BridgeStore? = BridgeStore.appGroup(), inbox: ImportInbox? = ImportInbox.appGroup()) {
        self.store = store
        self.inbox = inbox
        self.autoInsert = UserDefaults.standard.bool(forKey: Self.autoInsertKey)
    }

    // MARK: - Wiring

    func attach(to appState: IOSAppState) {
        guard self.appState == nil else { return }
        self.appState = appState

        appState.onDelivered = { [weak self] text, language in
            self?.takeCompleted(text: text, language: language)
        }
        appState.onDisplayChanged = { [weak self] display in
            self?.displayChanged(display)
        }

        #if canImport(Darwin)
        subscription = DarwinSignalCenter.shared.observe(.requestPosted) { [weak self] in
            Task { @MainActor in self?.handlePendingRequest() }
        }
        #endif

        try? store?.container.prepare()
        refreshImportCount()
        // A request may have been posted while the app was suspended.
        handlePendingRequest()
        publishStatus()
    }

    // MARK: - Arming

    /// Arms a capture session. Returns false with `lastNotice` set when the
    /// microphone or the App Group is unavailable — arming that silently does
    /// nothing would be worse than saying why.
    @discardableResult
    func arm(window: CaptureWindow, profileName: String?) -> Bool {
        guard let store else {
            lastNotice = "Vocal's shared storage is unavailable — check the App Group entitlement."
            return false
        }
        do {
            try AudioSessionManager.activate()
        } catch {
            lastNotice = "Microphone unavailable: \(error.localizedDescription)"
            return false
        }

        let requested = profileName ?? ""
        session = .armed(
            window: window,
            profileName: requested.isEmpty
                ? (appState?.effectiveProfileName ?? "Default") : requested,
            now: Date()
        )
        if phase == .idle {
            residency.beginIdleHold()
        }
        lastNotice = nil
        publishStatus()
        startHeartbeat()
        return true
    }

    func disarm() {
        session = nil
        heartbeat?.cancel()
        heartbeat = nil
        residency.endIdleHold()
        // Only release the session when nothing is actively recording.
        if phase == .idle {
            AudioSessionManager.deactivate()
        }
        publishStatus()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                let remaining = session.remaining(at: Date())
                guard remaining > 0 else {
                    self.disarm()
                    return
                }
                let sleep = min(Self.heartbeatInterval, remaining)
                try? await Task.sleep(for: .seconds(max(1, sleep)))
                guard !Task.isCancelled else { return }
                self.publishStatus()
            }
        }
    }

    // MARK: - Status publishing

    private func publishStatus() {
        guard let store else { return }
        let live = session.flatMap { $0.isArmed(at: Date()) ? $0 : nil }
        let status = BridgeStatus(
            updatedAt: Date(),
            session: live,
            phase: phase,
            activeRequestID: activeRequestID,
            availableProfileNames: appState?.profiles.map(\.name) ?? [],
            pendingImportCount: pendingImportCount,
            autoInsert: autoInsert
        )
        try? store.writeStatus(status)
        #if canImport(Darwin)
        DarwinSignalCenter.shared.post(.statusChanged)
        #endif
    }

    // MARK: - Request handling

    /// Reads whatever the keyboard left in the request slot and acts on it.
    func handlePendingRequest() {
        guard let store, let appState else { return }
        guard let request = (try? store.readRequest()) ?? nil else { return }
        // Darwin notifications coalesce, so the same request can be delivered
        // twice; acting on it twice would start two takes.
        guard handledRequest != request else { return }
        handledRequest = request
        try? store.clear(.request)

        // A request the app was suspended through is history, not an
        // instruction: acting on it would start a take nobody asked for, and
        // answering it would surface an error long after the fact.
        guard
            Date().timeIntervalSince(request.issuedAt)
                <= KeyboardBridgePolicy.replyFreshnessWindow
        else { return }

        guard let session, session.isArmed(at: Date()) else {
            reply(to: request.id, outcome: .failed(reason: "Vocal's capture session expired"))
            return
        }

        switch request.command {
        case .startRecording:
            guard phase == .idle else {
                // Answer rather than drop it: an unanswered request leaves the
                // keyboard waiting on a take that will never arrive.
                reply(to: request.id, outcome: .failed(reason: "Vocal is busy with another take"))
                return
            }
            activeRequestID = request.id
            takeID = request.id
            appState.keyboardProfileOverride = request.requestedProfileName
            self.session = session.extended(to: Date())
            // Hand the microphone from the residency tap to the real capture
            // engine before the session actor asks for it.
            residency.endIdleHold()
            appState.startDictation()

        case .stopRecording:
            guard request.id == activeRequestID else { return }
            appState.stopDictation()

        case .cancelRecording:
            guard request.id == activeRequestID else { return }
            appState.cancelDictation()
        }
    }

    private func reply(to requestID: UUID, outcome: BridgeReply.Outcome, language: Language? = nil) {
        guard let store else { return }
        let reply = BridgeReply(
            requestID: requestID,
            producedAt: Date(),
            outcome: outcome,
            language: language,
            profileName: session?.profileName ?? ""
        )
        try? store.writeReply(reply)
        #if canImport(Darwin)
        DarwinSignalCenter.shared.post(.replyPosted)
        #endif
    }

    // MARK: - Take lifecycle

    private func displayChanged(_ display: DictationDisplay) {
        switch display.mode {
        case .listening(let startedAt):
            let wasIdle = phase == .idle
            phase = .recording
            takeStartedAt = startedAt
            if wasIdle {
                // A take started in the app has no request behind it; give it
                // its own activity identity.
                if activeRequestID == nil { takeID = UUID() }
                startActivity(startedAt: startedAt, profileName: display.profileName)
            }
        case .processing:
            phase = .transcribing
            updateActivity(.transcribing, profileName: display.profileName)
        case .result:
            // The delivered callback owns the transition; it carries the text.
            break
        case .error(let message):
            phase = .idle
            finishActivity(
                stage: .failed, profileName: display.profileName, failureReason: message
            )
            if let requestID = activeRequestID {
                reply(to: requestID, outcome: .failed(reason: message))
                activeRequestID = nil
            }
            resumeResidencyIfArmed()
        case .idle:
            if phase != .idle {
                phase = .idle
                // Reaching idle without a result or an error means the take
                // was cancelled or discarded as an accidental tap.
                if let requestID = activeRequestID {
                    reply(to: requestID, outcome: .cancelled)
                    activeRequestID = nil
                }
                Task { await liveActivity.dismiss() }
                resumeResidencyIfArmed()
            }
        }
        publishStatus()
    }

    private func takeCompleted(text: String, language: Language) {
        phase = .idle
        if let requestID = activeRequestID {
            reply(to: requestID, outcome: .text(text), language: language)
            activeRequestID = nil
        }
        appState?.keyboardProfileOverride = nil
        // A take that lands is evidence the session is in use — push expiry
        // back so it does not die between two sentences.
        if let session, session.isArmed(at: Date()) {
            self.session = session.extended(to: Date())
        }
        finishActivity(
            stage: .finished,
            profileName: appState?.display.profileName ?? "",
            preview: text,
            language: language
        )
        resumeResidencyIfArmed()
        publishStatus()
    }

    private func resumeResidencyIfArmed() {
        guard let session, session.isArmed(at: Date()) else {
            residency.endIdleHold()
            return
        }
        residency.beginIdleHold()
    }

    // MARK: - Live Activity

    private func startActivity(startedAt: Date, profileName: String) {
        liveActivity.start(
            takeID: takeID.uuidString,
            state: RecordingActivityState(
                stage: .recording, startedAt: startedAt, profileName: profileName
            )
        )
    }

    private func updateActivity(
        _ stage: RecordingActivityState.Stage,
        profileName: String
    ) {
        let state = RecordingActivityState(
            stage: stage, startedAt: takeStartedAt ?? Date(), profileName: profileName
        )
        Task { await liveActivity.update(state) }
    }

    private func finishActivity(
        stage: RecordingActivityState.Stage,
        profileName: String,
        preview: String? = nil,
        language: Language? = nil,
        failureReason: String? = nil
    ) {
        var state = RecordingActivityState(
            stage: stage,
            startedAt: takeStartedAt ?? Date(),
            profileName: profileName,
            failureReason: failureReason
        )
        if let preview {
            state = state.withPreview(preview, language: language)
        }
        Task { await liveActivity.finish(with: state) }
    }

    // MARK: - Imports

    func refreshImportCount() {
        pendingImportCount = inbox?.pendingCount() ?? 0
    }

    // MARK: - Deep links

    /// Handles a `vocal://` link. Returns true when it was ours.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let link = VocalURL(url) else { return false }
        switch link {
        case .dictate:
            appState?.startDictation()
        case .arm(let window, let profileName):
            arm(window: window, profileName: profileName)
        case .imports:
            refreshImportCount()
        }
        return true
    }
}
