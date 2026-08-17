import ASRKit
import ASREngineWhisperKit
import AudioPipeline
import CleanupKit
import Combine
import CoreModels
import Foundation
import PersistenceKit
import ProfileKit
import SessionKit
import SwiftUI
import UIKit

/// What the dictation screen renders.
struct DictationDisplay: Equatable {
    enum Mode: Equatable {
        case idle
        case listening(startedAt: Date)
        case processing
        case result(String)
        case error(String)
    }

    var mode: Mode = .idle
    var profileName: String = ""
}

/// iOS composition root — mirrors the Mac AppState but delivers via the
/// clipboard (docs/02 mode D1: auto-copy + share).
@MainActor
final class IOSAppState: ObservableObject {

    let session: DictationSession
    let database: DatabaseStore?
    let profiles: [Profile]
    @Published var display = DictationDisplay() {
        didSet {
            guard display != oldValue else { return }
            onDisplayChanged?(display)
        }
    }

    /// Called on every display transition. The capture-session coordinator
    /// uses it to mirror take state into the keyboard bridge and the Live
    /// Activity without this type having to know either exists.
    var onDisplayChanged: ((DictationDisplay) -> Void)?
    /// Called once per delivered take, with the language the take resolved to
    /// (the display carries only the text).
    var onDelivered: ((String, Language) -> Void)?
    /// Profile the keyboard picked for the current take; nil falls back to the
    /// user's own selection (docs/02 FR-i3.3 — iOS cannot route by host app).
    var keyboardProfileOverride: String?
    /// Runs immediately before capture starts, whichever entry point began the
    /// take. The capture-session coordinator uses it to release the residency
    /// tap, so two AVAudioEngines never contend for the same input node.
    var willStartCapture: (() -> Void)?

    // Persisted scalar settings (FR-i parity subset). Plain @Published with
    // UserDefaults persistence — @AppStorage only publishes inside Views.
    @Published var cleanupMasterSwitch: Bool {
        didSet { UserDefaults.standard.set(cleanupMasterSwitch, forKey: "cleanupMasterSwitch") }
    }
    @Published var languageModeRaw: String {
        didSet { UserDefaults.standard.set(languageModeRaw, forKey: "languageModeRaw") }
    }
    @Published var stylePrompt: String {
        didSet { UserDefaults.standard.set(stylePrompt, forKey: "stylePrompt") }
    }
    @Published var autoCopy: Bool {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") }
    }
    @Published var selectedProfileName: String {
        didSet { UserDefaults.standard.set(selectedProfileName, forKey: "selectedProfileName") }
    }

    private let engine: WhisperKitEngine
    private let config: IOSSessionConfig

    /// The loaded ASR engine, for paths that transcribe outside a dictation
    /// take — share-sheet imports run through the same model rather than a
    /// second one (docs/02 FR-i2.3).
    var transcriptionEngine: any TranscriptionEngine { engine }
    private var phaseTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?

    var languageMode: LanguageMode {
        get {
            switch languageModeRaw {
            case "en": .pinned(.english)
            case "zh": .pinned(.chinese)
            default: .auto
            }
        }
        set {
            switch newValue {
            case .auto: languageModeRaw = "auto"
            case .pinned(.english): languageModeRaw = "en"
            case .pinned(.chinese): languageModeRaw = "zh"
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        cleanupMasterSwitch = defaults.bool(forKey: "cleanupMasterSwitch")
        languageModeRaw = defaults.string(forKey: "languageModeRaw") ?? "auto"
        stylePrompt = defaults.string(forKey: "stylePrompt") ?? ""
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        selectedProfileName = defaults.string(forKey: "selectedProfileName") ?? ""

        let database = Self.makeDatabase()
        let profiles = Self.loadProfiles(database: database)
        let engine = WhisperKitEngine()
        let config = IOSSessionConfig(database: database)
        let deliverer = ClipboardDelivering()
        let relay = IOSResolutionRelay()

        // On iOS the profile is chosen manually (no frontmost-app detection —
        // docs/02 FR-i3.3); default = the profile owning the default route.
        let selectedName = UserDefaults.standard.string(forKey: "selectedProfileName") ?? ""
        let dependencies = DictationSession.Dependencies(
            audio: IOSCaptureAdapter(microphone: MicrophoneCapture()),
            engine: engine,
            cleanup: nil,
            cleanupProviderID: .appleFoundationModels,
            deliverer: deliverer,
            store: IOSTranscriptStore(database: database),
            config: config,
            profileResolution: {
                // A keyboard-chosen profile wins for that take only; otherwise
                // the user's own pick stands (docs/02 FR-i2.2).
                let name = await MainActor.run { () -> String in
                    if let override = relay.appState?.keyboardProfileOverride, !override.isEmpty {
                        return override
                    }
                    return UserDefaults.standard.string(forKey: "selectedProfileName")
                        ?? selectedName
                }
                let resolver = ProfileResolver(profiles: profiles)
                let manual = profiles.first { $0.name == name }
                let resolution = resolver.resolve(
                    frontmostBundleID: nil,
                    tabHostname: nil,
                    manualPinProfileID: manual?.id
                )
                await relay.noteResolved(profileName: resolution.profile.name)
                return (
                    profile: resolution.profile,
                    routeKind: manual != nil ? .manualPin : resolution.routeKind,
                    pressTimeBundleID: nil
                )
            }
        )

        self.database = database
        self.profiles = profiles
        self.engine = engine
        self.config = config
        self.session = DictationSession(dependencies: dependencies)

        relay.appState = self
        deliverer.appState = self
        startPhaseMirror()
    }

    /// Loads (downloading on first run) the ASR model (FR-i1.4).
    func warmUp() async throws {
        try await engine.prepare(languageMode: languageMode)
    }

    /// The profile a take would run under right now — the same routing the
    /// session performs at press time, so the keyboard and the arming UI can
    /// name it before anyone speaks.
    var effectiveProfileName: String {
        let resolver = ProfileResolver(profiles: profiles)
        let manual = profiles.first { $0.name == selectedProfileName }
        return resolver.resolve(
            frontmostBundleID: nil, tabHostname: nil, manualPinProfileID: manual?.id
        ).profile.name
    }

    // MARK: - Dictation controls

    func startDictation() {
        willStartCapture?()
        do {
            try AudioSessionManager.activate()
        } catch {
            display.mode = .error("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        config.masterSwitch = cleanupMasterSwitch
        config.stylePromptValue = stylePrompt
        config.languageModeValue = languageMode
        enqueueControl { session in await session.pressBegan() }
    }

    func stopDictation() {
        enqueueControl { session in await session.pressEnded(isLockMode: false) }
    }

    func cancelDictation() {
        enqueueControl { session in await session.cancel() }
    }

    /// Called by the deliverer with the final text (already on the clipboard
    /// when auto-copy is on).
    func showResult(_ text: String) {
        display.mode = .result(text)
    }

    private func enqueueControl(
        _ operation: @escaping @Sendable (DictationSession) async -> Void
    ) {
        let session = session
        let previous = controlTask
        controlTask = Task {
            await previous?.value
            await operation(session)
        }
    }

    private func startPhaseMirror() {
        phaseTask = Task { [weak self] in
            guard let session = self?.session else { return }
            let phases = await session.phases
            for await phase in phases {
                guard let self else { return }
                await self.handle(phase: phase, session: session)
            }
        }
    }

    private func handle(phase: DictationSession.Phase, session: DictationSession) async {
        switch phase {
        case .arming, .recording:
            display.mode = .listening(startedAt: Date())
        case .transcribing, .cleaning, .delivering:
            display.mode = .processing
        case .cancelled:
            display.mode = .idle
        case .idle:
            // A `.result` set by the deliverer sticks; otherwise surface errors.
            if case .result = display.mode { break }
            if case .processing = display.mode {
                if let error = await session.lastError {
                    display.mode = .error(Self.message(for: error))
                } else {
                    display.mode = .idle
                }
            } else if let error = await session.lastError {
                display.mode = .error(Self.message(for: error))
            }
        }
    }

    // MARK: - Composition helpers

    private static func makeDatabase() -> DatabaseStore? {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let directory = appSupport.appendingPathComponent("Vocal", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try DatabaseStore(path: directory.appendingPathComponent("vocal.sqlite").path)
        } catch {
            return nil
        }
    }

    private static func loadProfiles(database: DatabaseStore?) -> [Profile] {
        if let database, let stored = try? database.profiles(), !stored.isEmpty {
            return stored
        }
        return BuiltInProfiles.makeAll()
    }

    private static func message(for error: TranscriptionError) -> String {
        switch error {
        case .modelNotInstalled: "Speech model not installed — warm up in Settings"
        case .engineUnavailable: "Transcription engine unavailable"
        case .audioUnreadable: "Could not capture microphone audio"
        case .cancelled: "Dictation cancelled"
        }
    }
}

// MARK: - Seam adapters

@MainActor
private final class IOSResolutionRelay {
    weak var appState: IOSAppState?

    func noteResolved(profileName: String) {
        appState?.display.profileName = profileName
    }
}

private struct IOSCaptureAdapter: AudioCapturing {
    let microphone: MicrophoneCapture

    func start() async throws -> CaptureSession {
        let session = try await microphone.start()
        return CaptureSession(
            chunks: session.chunks,
            finish: session.finish,
            cancel: session.cancel
        )
    }
}

/// Mode D1 delivery: the transcript lands on the clipboard (when auto-copy is
/// on) and the result card offers Share (docs/02 FR-i2.1).
private final class ClipboardDelivering: TextDelivering, @unchecked Sendable {
    // Written once from IOSAppState.init on the main actor before any
    // dictation can run; read via MainActor hops only.
    weak var appState: IOSAppState?

    func deliver(_ text: String, context: DeliveryContext) async -> DeliveryOutcome {
        let language = context.language
        await MainActor.run { [weak appState] in
            if appState?.autoCopy ?? true {
                UIPasteboard.general.string = text
            }
            appState?.showResult(text)
            // After the result is on screen, so anything reacting to this sees
            // a consistent display state.
            appState?.onDelivered?(text, language)
        }
        return .copiedToClipboard(reason: .userSetting)
    }
}

private actor IOSTranscriptStore: TranscriptStoring {
    private let database: DatabaseStore?

    init(database: DatabaseStore?) {
        self.database = database
    }

    func save(_ record: TranscriptRecord) async throws {
        guard let database else { return }
        try database.save(record)
    }
}

/// SessionConfiguring backed by simple properties the app state refreshes
/// before each dictation (UserDefaults reads must stay off the session actor).
private final class IOSSessionConfig: SessionConfiguring, @unchecked Sendable {
    // Mutated only from the main actor between takes; read by the session.
    var masterSwitch = false
    var languageModeValue: LanguageMode = .auto
    var stylePromptValue = ""
    private let database: DatabaseStore?

    init(database: DatabaseStore?) {
        self.database = database
    }

    var cleanupMasterSwitch: Bool {
        get async { masterSwitch }
    }

    var globalLanguageMode: LanguageMode {
        get async { languageModeValue }
    }

    var globalStylePrompt: String {
        get async { stylePromptValue }
    }

    var cleanupTimeout: Duration {
        get async { .seconds(6) }
    }

    func enabledDictionaryEntries() async -> [DictionaryEntry] {
        guard let database else { return [] }
        return (try? database.dictionaryEntries().filter(\.isEnabled)) ?? []
    }
}
