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
        do {
            response = try await provider.cleanup(request, timeout: timeout)
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
