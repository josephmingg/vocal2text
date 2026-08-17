import ASRKit
import AudioPipeline
import BridgeKit
import Combine
import CoreModels
import Foundation
import PersistenceKit
import ProfileKit
import TextPipeline

/// Turns share-sheet voice notes into history rows (docs/02 FR-i2.3, FR-i3.5,
/// AC-i5).
///
/// The share extension only ever copies bytes across the App Group boundary;
/// all decoding and transcription happen here, where the app has the memory
/// budget and the model. Long files decode in bounded passes so progress is
/// real and cancelling actually stops work.
///
/// Stage 3 (AI cleanup) is deliberately not run on imports: the iOS build
/// injects no cleanup pipeline yet, and the history row says so rather than
/// implying a provider ran.
@MainActor
final class ImportProcessor: ObservableObject {

    @Published private(set) var items: [ImportManifest] = []
    @Published private(set) var active: ImportManifest?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isRunning = false

    /// Orphan audio older than this is debris from a share extension that was
    /// killed mid-copy.
    private static let orphanGracePeriod: TimeInterval = 60 * 60

    private let inbox: ImportInbox?
    private let appState: IOSAppState
    private var work: Task<Void, Never>?

    init(appState: IOSAppState, inbox: ImportInbox? = ImportInbox.appGroup()) {
        self.appState = appState
        self.inbox = inbox
    }

    // MARK: - Queue

    func refresh() {
        guard let inbox else {
            items = []
            return
        }
        items = inbox.all()
    }

    func delete(_ manifest: ImportManifest) {
        inbox?.remove(manifest)
        refresh()
    }

    /// Retries an item that used up its attempts.
    func retry(_ manifest: ImportManifest) {
        guard let inbox else { return }
        var reset = manifest
        reset.attemptCount = 0
        reset.lastError = nil
        try? inbox.commit(reset)
        refresh()
    }

    func cancel() {
        work?.cancel()
        work = nil
        isRunning = false
        active = nil
        progress = 0
    }

    // MARK: - Processing

    /// Drains every pending item, oldest first. Safe to call repeatedly; a
    /// second call while running is a no-op.
    func processPending() {
        guard !isRunning, let inbox else { return }
        isRunning = true
        lastError = nil
        work = Task { [weak self] in
            defer {
                self?.isRunning = false
                self?.active = nil
                self?.progress = 0
                self?.refresh()
            }
            _ = inbox.sweepOrphans(olderThan: Self.orphanGracePeriod)
            while !Task.isCancelled {
                guard let self, let next = inbox.pending().first else { return }
                self.active = next
                self.progress = 0
                do {
                    try await self.process(next, inbox: inbox)
                    inbox.remove(next)
                } catch is CancellationError {
                    return
                } catch {
                    let reason = Self.message(for: error)
                    _ = try? inbox.noteFailure(next, reason: reason)
                    self.lastError = "\(next.originalFilename): \(reason)"
                }
                self.refresh()
            }
        }
    }

    private func process(_ manifest: ImportManifest, inbox: ImportInbox) async throws {
        let url = inbox.audioURL(for: manifest)
        let languageMode = appState.languageMode
        let profile = resolvedProfile()
        // Imports get the same dictionary corrections as live dictation
        // (docs/02 AC-i8).
        var entries: [DictionaryEntry] = []
        if let database = appState.database {
            entries = (try? database.dictionaryEntries().filter(\.isEnabled)) ?? []
        }

        // Coarse updates only — a progress bar does not need every buffer, and
        // each one costs an actor hop.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, fraction - self.progress >= 0.02 || fraction >= 1 else { return }
                self.progress = fraction
            }
        }

        // Decoding is CPU-bound and must not block the UI; the decoder polls
        // its own task for cancellation through the progress callback.
        let decoded = try await Task.detached(priority: .userInitiated) {
            try AudioFileDecoder.decode(url: url) { fraction in
                if Task.isCancelled { return false }
                report(fraction)
                return true
            }
        }.value

        try Task.checkCancellation()
        guard decoded.audio.durationSeconds > 0 else {
            throw AudioFileDecodeError.unreadable("no audio samples")
        }

        let result = try await appState.transcriptionEngine.transcribe(
            decoded.audio,
            languageMode: languageMode,
            dictionaryTerms: entries.map(\.written)
        )
        try Task.checkCancellation()

        let language = result.detectedLanguage
        let normalized = Stage1Normalizer.normalize(
            result.text, language: language, formatting: profile.formatting
        )
        let corrected = DictionaryEngine.apply(normalized, entries: entries, language: language).text
        let formatted = Stage4Formatter.format(
            corrected, language: language, formatting: profile.formatting, precedingContext: nil
        )

        let record = TranscriptRecord(
            createdAt: Date(),
            source: .fileImport,
            language: language,
            rawText: result.text,
            deliveredText: formatted,
            durationSeconds: decoded.audio.durationSeconds,
            profileName: profile.name,
            routeKind: .manualPin,
            cleanup: .skipped(reason: .providerUnavailable),
            importedFilename: manifest.originalFilename
        )
        try appState.database?.save(record)
    }

    private func resolvedProfile() -> Profile {
        let resolver = ProfileResolver(profiles: appState.profiles)
        let manual = appState.profiles.first { $0.name == appState.selectedProfileName }
        return resolver.resolve(
            frontmostBundleID: nil, tabHostname: nil, manualPinProfileID: manual?.id
        ).profile
    }

    private static func message(for error: Error) -> String {
        if let decode = error as? AudioFileDecodeError {
            switch decode {
            case .unreadable: return "Could not read that audio file"
            case .formatUnavailable: return "Unsupported audio format"
            case .conversionFailed: return "Audio conversion failed"
            case .cancelled: return "Cancelled"
            }
        }
        if let transcription = error as? TranscriptionError {
            switch transcription {
            case .modelNotInstalled: return "Speech model not installed — warm up in Settings"
            case .engineUnavailable: return "Transcription engine unavailable"
            case .audioUnreadable: return "Could not read the imported audio"
            case .cancelled: return "Cancelled"
            }
        }
        return String(describing: error)
    }
}
