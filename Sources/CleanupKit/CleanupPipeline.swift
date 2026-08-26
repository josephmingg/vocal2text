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
    /// `CleanupError.timedOut` if the budget wins — returning *at* the
    /// deadline, not merely relabeling a late failure.
    ///
    /// A `withThrowingTaskGroup` race cannot provide that: the group awaits
    /// every remaining child before the body's error escapes, and
    /// `cancelAll()` only *requests* cancellation — so a provider that does
    /// not cooperate (an in-process model blocked in inference, or a
    /// continuation-based transport with no cancellation handler) would still
    /// park the caller for as long as it pleased, with the user's text
    /// undelivered. FR-7.3 forbids exactly that. Here the loser is abandoned
    /// instead: it gets a cancellation request and its eventual result is
    /// handed to a gate that has already been emptied. The zombie work is the
    /// price of the guarantee, and it is bounded by the provider's own
    /// lifetime, not ours.
    ///
    /// A non-positive budget fails immediately — "no time" must not mean
    /// "unlimited time".
    private func withTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> CleanupResponse
    ) async throws -> CleanupResponse {
        guard timeout > .zero else { throw CleanupError.timedOut }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = FirstResumeGate(continuation)
            let work = Task {
                do {
                    let response = try await operation()
                    gate.take()?.resume(returning: response)
                } catch {
                    gate.take()?.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard let continuation = gate.take() else { return }
                work.cancel()
                continuation.resume(throwing: CleanupError.timedOut)
            }
        }
    }

    /// Hands the continuation to exactly one of the two racers.
    private final class FirstResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CleanupResponse, any Error>?

        init(_ continuation: CheckedContinuation<CleanupResponse, any Error>) {
            self.continuation = continuation
        }

        func take() -> CheckedContinuation<CleanupResponse, any Error>? {
            lock.lock()
            defer {
                continuation = nil
                lock.unlock()
            }
            return continuation
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
