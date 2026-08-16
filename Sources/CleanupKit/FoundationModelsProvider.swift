import CoreModels
import Foundation

// FoundationModels ships in the macOS 26 / iOS 26 SDKs (Xcode 26 / Swift 6.2+);
// older toolchains compile the stub. [verify: M0 spike 0.5 exercises the real
// path on-device — this adapter cannot be compile-checked by today's CI runner.]
#if canImport(FoundationModels) && compiler(>=6.2)
import FoundationModels

/// Apple's on-device ~3B model — the zero-install default local provider on
/// Apple-Intelligence hardware (docs/05 §3.2). Out-of-process, EN/ZH, and the
/// only LLM engine documented to work from a backgrounded iOS app.
@available(macOS 26.0, iOS 26.0, *)
public actor FoundationModelsProvider: CleanupProvider {
    public nonisolated let id: CleanupProviderID = .appleFoundationModels
    public nonisolated let leavesDevice = false

    private let assembler: PromptAssembler

    public init(assembler: PromptAssembler = PromptAssembler()) {
        self.assembler = assembler
    }

    public func isAvailable() async -> Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    public func prewarm() async {
        // Session creation is cheap and the system model is OS-resident;
        // nothing to pre-load beyond touching availability.
        _ = await isAvailable()
    }

    public func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse {
        guard await isAvailable() else {
            throw CleanupError.providerUnavailable("Apple Intelligence model unavailable")
        }
        let session = LanguageModelSession(instructions: assembler.systemPrompt(for: request))
        do {
            let response = try await session.respond(to: assembler.userMessage(for: request))
            return CleanupResponse(
                text: response.content.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: "apple-foundation-3b"
            )
        } catch let error as LanguageModelSession.GenerationError {
            // Guardrail refusals and unsupported languages fall back to
            // stage-2 text upstream (docs/05 §3.3); never fail the dictation.
            switch error {
            case .guardrailViolation:
                throw CleanupError.guardrailRefusal
            case .unsupportedLanguageOrLocale:
                throw CleanupError.unsupportedLanguage
            default:
                throw CleanupError.transport(String(describing: error))
            }
        } catch {
            throw CleanupError.transport(String(describing: error))
        }
    }
}
#else
/// Pre-26 SDKs / non-Apple platforms compile this stub.
public enum FoundationModelsProviderInfo {
    public static let isSupported = false
}
#endif
