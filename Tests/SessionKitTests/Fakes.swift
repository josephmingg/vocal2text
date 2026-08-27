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

/// A one-shot gate: `waitForOpen` suspends until someone calls `open`.
/// Used to assert ordering between the press path's concurrent steps.
actor CaptureGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }

    func waitForOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// `AudioCapturing` fake: `start` always succeeds, the chunk stream is empty
/// (the transcribe-on-release flow never reads it), and `finish` returns the
/// scripted utterance.
struct ScriptedAudioCapturing: AudioCapturing {
    let chunk: PCMChunk
    let log: CaptureLog
    /// Fired inside `start()`, so tests can observe when capture went live.
    let onStart: @Sendable () async -> Void

    init(
        chunk: PCMChunk,
        log: CaptureLog = CaptureLog(),
        onStart: @escaping @Sendable () async -> Void = {}
    ) {
        self.chunk = chunk
        self.log = log
        self.onStart = onStart
    }

    func start() async throws -> CaptureSession {
        let chunk = self.chunk
        let log = self.log
        await onStart()
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

/// `AudioCapturing` fake whose chunk stream is fed externally — the streaming
/// preview (docs/15 step 22) consumes it live, so tests must be able to push
/// chunks while the take is recording.
struct StreamingAudioCapturing: AudioCapturing {
    let finishChunk: PCMChunk
    let feed: ChunkFeed

    func start() async throws -> CaptureSession {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PCMChunk.self, bufferingPolicy: .unbounded
        )
        await feed.store(continuation)
        let chunk = finishChunk
        return CaptureSession(
            chunks: stream,
            finish: {
                continuation.finish()
                return chunk
            },
            cancel: {
                continuation.finish()
            }
        )
    }
}

/// Holds the live stream's continuation so a test can push chunks mid-take.
actor ChunkFeed {
    private var continuation: AsyncStream<PCMChunk>.Continuation?

    func store(_ continuation: AsyncStream<PCMChunk>.Continuation) {
        self.continuation = continuation
    }

    func push(_ chunk: PCMChunk) {
        continuation?.yield(chunk)
    }
}

/// Serves preview hypotheses one at a time; the last one repeats, so a loop
/// that outpaces the script sees a stable hypothesis rather than nil.
actor ScriptedHypotheses {
    private var remaining: [String]
    private var last: String?

    init(_ hypotheses: [String]) {
        self.remaining = hypotheses
    }

    func next() -> String? {
        if remaining.isEmpty { return last }
        let value = remaining.removeFirst()
        last = value
        return value
    }
}

/// Thread-safe string recorder for synchronous callback seams (`onPartial`).
final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
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

/// Polls `condition` until it holds, failing loudly on timeout — for tests
/// that must observe work done by an interval-driven loop.
func waitUntil(
    _ label: String,
    timeout: Duration = .seconds(3),
    condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            throw TimeoutError(label: label)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    var label: String
    var description: String { "timed out waiting for \(label)" }
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

/// Records the profiles a per-take cleanup selector was handed (docs/11 G3).
actor ProfileRecorder {
    private(set) var profiles: [Profile] = []

    func record(_ profile: Profile) {
        profiles.append(profile)
    }
}
