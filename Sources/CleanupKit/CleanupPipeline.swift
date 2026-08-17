import CoreModels
import Foundation

/// Orchestrates stage 3 (docs/05 §3): provider call → think-block stripping →
/// output validation → protected-terms verification. Never throws — any
/// failure falls back with a reason so the caller delivers the stage-2 text
/// (docs/05 §0).
public struct CleanupPipeline: Sendable {
    public enum Outcome: Sendable, Hashable {
        case cleaned(String, model: String)
        case fellBack(reason: String)
    }

    let provider: any CleanupProvider

    public init(provider: any CleanupProvider) {
        self.provider = provider
    }

    public func run(_ request: CleanupRequest, timeout: Duration) async -> Outcome {
        let response: CleanupResponse
        let provider = self.provider
        do {
            response = try await withTimeout(timeout) {
                try await provider.cleanup(request, timeout: timeout)
            }
        } catch let error as CleanupError {
            return .fellBack(reason: Self.reason(for: error))
        } catch {
            return .fellBack(reason: "provider-error")
        }

        let stripped = OutputValidator.strippingThinkBlocks(response.text)
        switch OutputValidator.validate(
            output: stripped, input: request.text, language: request.language
        ) {
        case .rejected(let rule):
            return .fellBack(reason: "validator: \(rule)")
        case .accepted(let cleaned):
            guard
                ProtectedTermsVerifier.verify(
                    output: cleaned, input: request.text, protectedTerms: request.protectedTerms
                )
            else {
                return .fellBack(reason: "protected-terms")
            }
            return .cleaned(cleaned, model: response.modelName)
        }
    }

    /// Races `operation` against the stage-3 budget and throws
    /// `CleanupError.timedOut` if the budget wins.
    ///
    /// The timeout is enforced here rather than left to each provider:
    /// `OpenAICompatibleProvider` can honor it through `URLRequest`, but an
    /// in-process provider (Apple Foundation Models) has no such hook, and a
    /// stalled local model would otherwise park the session in `.cleaning`
    /// forever with the user's text undelivered. FR-7.3 requires cleanup
    /// failure — including "never answered" — to fall back, not to hang.
    /// Providers still receive the same `timeout` so they can fail earlier and
    /// with a more specific reason.
    private func withTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> CleanupResponse
    ) async throws -> CleanupResponse {
        guard timeout > .zero else { return try await operation() }
        return try await withThrowingTaskGroup(of: CleanupResponse?.self) { group in
            group.addTask { try await operation() }
            // nil means "the budget elapsed" — or that this sleeper lost the
            // race and was cancelled, in which case nobody reads its result.
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            // First to finish decides; `cancelAll` stops the loser.
            let first: CleanupResponse?? = try await group.next()
            guard let winner = first.flatMap({ $0 }) else {
                throw CleanupError.timedOut
            }
            return winner
        }
    }

    static func reason(for error: CleanupError) -> String {
        switch error {
        case .providerUnavailable(let detail):
            return "provider-unavailable: \(detail)"
        case .timedOut:
            return "timed-out"
        case .transport(let detail):
            return "transport: \(detail)"
        case .unsupportedLanguage:
            return "unsupported-language"
        case .guardrailRefusal:
            return "guardrail-refusal"
        case .malformedOutput(let detail):
            return "malformed-output: \(detail)"
        }
    }
}
