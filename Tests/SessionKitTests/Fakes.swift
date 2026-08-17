import ASRKit
import CoreModels
import Foundation
import SessionKit

/// Records the `finish`/`cancel` calls made on scripted capture sessions.
actor CaptureLog {
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    func recordFinish() { finishCount += 1 }
    func recordCancel() { cancelCount += 1 }
}

/// `AudioCapturing` fake: `start` always succeeds, the chunk stream is empty
/// (the transcribe-on-release flow never reads it), and `finish` returns the
/// scripted utterance.
struct ScriptedAudioCapturing: AudioCapturing {
    let chunk: PCMChunk
    let log: CaptureLog

    init(chunk: PCMChunk, log: CaptureLog = CaptureLog()) {
        self.chunk = chunk
        self.log = log
    }

    func start() async throws -> CaptureSession {
        let chunk = self.chunk
        let log = self.log
        return CaptureSession(
            chunks: AsyncStream { continuation in
                continuation.finish()
            },
            finish: {
                await log.recordFinish()
                return chunk
            },
            cancel: {
                await log.recordCancel()
            }
        )
    }
}

/// `TextDelivering` fake: records every delivered string and its context, then
/// returns a configurable outcome.
actor RecordingTextDeliverer: TextDelivering {
    private(set) var deliveredTexts: [String] = []
    private(set) var contexts: [DeliveryContext] = []
    private let outcome: DeliveryOutcome

    init(outcome: DeliveryOutcome = .inserted(method: .paste, appBundleID: "com.example.notes")) {
        self.outcome = outcome
    }

    func deliver(_ text: String, context: DeliveryContext) async -> DeliveryOutcome {
        deliveredTexts.append(text)
        contexts.append(context)
        return outcome
    }
}

/// `TranscriptStoring` fake collecting records in memory.
actor InMemoryStore: TranscriptStoring {
    private(set) var records: [TranscriptRecord] = []

    func save(_ record: TranscriptRecord) async throws {
        records.append(record)
    }
}

/// `SessionConfiguring` fake with fixed values.
struct StaticConfig: SessionConfiguring {
    var masterSwitch = false
    var languageMode = LanguageMode.auto
    var stylePrompt = ""
    var timeout = Duration.seconds(5)
    var entries: [DictionaryEntry] = []

    var cleanupMasterSwitch: Bool {
        get async { masterSwitch }
    }

    var globalLanguageMode: LanguageMode {
        get async { languageMode }
    }

    var globalStylePrompt: String {
        get async { stylePrompt }
    }

    var cleanupTimeout: Duration {
        get async { timeout }
    }

    func enabledDictionaryEntries() async -> [DictionaryEntry] {
        entries.filter(\.isEnabled)
    }
}
