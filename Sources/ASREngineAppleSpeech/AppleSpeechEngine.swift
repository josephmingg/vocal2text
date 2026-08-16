import ASRKit
import CoreModels
import Foundation

// SpeechAnalyzer/DictationTranscriber ship in the macOS 26 / iOS 26 SDKs, which
// require the Swift 6.2+ compiler (Xcode 26). Older SDKs compile the stub, so
// every CI runner and Linux build stays green while real hardware gets the
// fast-path engine. [verify: M0 spike 0.2 exercises this adapter on-device.]
#if canImport(Speech) && compiler(>=6.2)
import Speech

/// Apple's on-device dictation engine (docs/04 §1): fast path for pinned-language
/// EN/ZH. DictationTranscriber is the only Apple module honoring custom-vocabulary
/// contextual strings, so the adapter routes through it whenever dictionary terms
/// are present.
@available(macOS 26.0, iOS 26.0, *)
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let id = "apple-speech"
    public nonisolated let displayName = "Apple Speech (on-device)"

    public init() {}

    private func locale(for language: Language) -> Locale {
        switch language {
        case .english: Locale(identifier: "en_US")
        case .chinese: Locale(identifier: "zh_CN")
        }
    }

    public func availability(for language: Language) async -> EngineAvailability {
        let locale = locale(for: language)
        let supported = await DictationTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            return .unsupported(reason: "Locale \(locale.identifier) not supported by Apple Speech")
        }
        let installed = await DictationTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return .ready
        }
        return .needsDownload(bytes: 0) // OS-managed asset; size not exposed.
    }

    public func prepare(languageMode: LanguageMode) async throws {
        guard case .pinned(let language) = languageMode else { return }
        let transcriber = DictationTranscriber(
            locale: locale(for: language),
            preset: .shortDictation
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    public func transcribe(
        _ audio: PCMChunk,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) async throws -> TranscriptionResult {
        // Apple's engine is single-language per session (docs/04 §1): auto mode
        // is resolved by a cheap script heuristic before choosing the locale —
        // callers wanting true code-switching use the WhisperKit engine.
        let language: Language
        switch languageMode {
        case .pinned(let l): language = l
        case .auto: language = .english
        }

        let transcriber = DictationTranscriber(
            locale: locale(for: language),
            preset: .shortDictation
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let (inputStream, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(PCMChunk.sampleRate),
            channels: 1,
            interleaved: false
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(audio.samples.count)
              )
        else {
            throw TranscriptionError.audioUnreadable("could not build PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress, let dst = buffer.floatChannelData?[0] {
                dst.update(from: base, count: audio.samples.count)
            }
        }
        inputBuilder.yield(AnalyzerInput(buffer: buffer))
        inputBuilder.finish()

        try await analyzer.start(inputSequence: inputStream)

        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: language
        )
    }

    public nonisolated func transcribeStream(
        _ audio: AsyncStream<PCMChunk>,
        languageMode: LanguageMode,
        dictionaryTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var samples: [Float] = []
                for await chunk in audio {
                    samples.append(contentsOf: chunk.samples)
                }
                do {
                    let result = try await self.transcribe(
                        PCMChunk(samples: samples),
                        languageMode: languageMode,
                        dictionaryTerms: dictionaryTerms
                    )
                    continuation.yield(.init(kind: .final, text: result.text, detectedLanguage: result.detectedLanguage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {}
}
#else
/// Older SDKs / non-Apple platforms compile this stub.
public enum AppleSpeechEngineInfo {
    public static let isSupported = false
}
#endif
