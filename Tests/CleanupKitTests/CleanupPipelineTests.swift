import CoreModels
import Foundation
import Testing
@testable import CleanupKit

private struct MockProvider: CleanupProvider {
    let id: CleanupProviderID = .openAICompatible(name: "Mock")
    let leavesDevice = false
    let result: Result<CleanupResponse, CleanupError>

    func isAvailable() async -> Bool { true }
    func prewarm() async {}
    func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse {
        try result.get()
    }
}

private struct ExplodingProvider: CleanupProvider {
    struct Boom: Error {}

    let id: CleanupProviderID = .openAICompatible(name: "Exploding")
    let leavesDevice = false

    func isAvailable() async -> Bool { true }
    func prewarm() async {}
    func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse {
        throw Boom()
    }
}

/// A provider that cannot be interrupted: it parks on a continuation that is
/// never resumed — the async analogue of an inference call stuck in native
/// code. This is deliberately NOT a `Task.sleep` fake: sleep is
/// cancellation-cooperative and returns the instant the deadline race cancels
/// it, which lets a timeout that merely relabels a late failure pass the test
/// without ever bounding anything. (This test's first version made exactly
/// that mistake.)
private struct NonCooperativeProvider: CleanupProvider {
    let id: CleanupProviderID = .appleFoundationModels
    let leavesDevice = false

    func isAvailable() async -> Bool { true }
    func prewarm() async {}
    func cleanup(_ request: CleanupRequest, timeout: Duration) async throws -> CleanupResponse {
        // Ignores the timeout parameter AND cancellation. The hung task leaks
        // for the life of the test process; that is the point.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return CleanupResponse(text: "unreachable", modelName: "hung")
    }
}

struct CleanupPipelineTests {

    /// FR-7.3: a provider that never returns — and never honours cancellation
    /// — must not park the dictation in `.cleaning`. The pipeline has to come
    /// back at its own deadline and deliver the stage-2 text. The time limit
    /// is the real assertion: a regression here hangs, it does not fail.
    @Test(.timeLimit(.minutes(1)))
    func providerThatIgnoresCancellationStillFallsBackOnTime() async {
        let pipeline = CleanupPipeline(provider: NonCooperativeProvider())
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await pipeline.run(
            CleanupRequest(text: "meet on saturday", language: .english),
            timeout: .milliseconds(100)
        )
        let elapsed = clock.now - start
        #expect(outcome == .fellBack(reason: "timed-out"))
        // Generous CI margin; the point is that it returns near the budget,
        // not after the provider deigns to.
        #expect(elapsed < .seconds(30))
    }

    /// "No time" must mean fail-now, not run-unbounded.
    @Test(.timeLimit(.minutes(1)))
    func zeroTimeoutFailsImmediately() async {
        let pipeline = CleanupPipeline(provider: NonCooperativeProvider())
        let outcome = await pipeline.run(
            CleanupRequest(text: "meet on saturday", language: .english),
            timeout: .zero
        )
        #expect(outcome == .fellBack(reason: "timed-out"))
    }

    @Test func successPathDeliversCleanedTextAndModel() async {
        let provider = MockProvider(
            result: .success(CleanupResponse(text: "Saturday works.", modelName: "mock-1"))
        )
        let pipeline = CleanupPipeline(provider: provider)
        let outcome = await pipeline.run(
            CleanupRequest(text: "um, uh, so… Saturday works", language: .english),
            timeout: .seconds(5)
        )
        #expect(outcome == .cleaned("Saturday works.", model: "mock-1"))
    }

    @Test func thinkBlocksAreStrippedOnSuccess() async {
        let provider = MockProvider(
            result: .success(
                CleanupResponse(text: "<think>drop the false start</think>周六", modelName: "mock-zh")
            )
        )
        let pipeline = CleanupPipeline(provider: provider)
        let outcome = await pipeline.run(
            CleanupRequest(text: "周五，啊不对，周六", language: .chinese),
            timeout: .seconds(5)
        )
        #expect(outcome == .cleaned("周六", model: "mock-zh"))
    }

    @Test func validatorRejectionFallsBack() async {
        let provider = MockProvider(
            result: .success(
                CleanupResponse(
                    text: "Here is your cleaned text: Saturday works.", modelName: "mock-1"
                )
            )
        )
        let pipeline = CleanupPipeline(provider: provider)
        let outcome = await pipeline.run(
            CleanupRequest(text: "um, uh, so… Saturday works", language: .english),
            timeout: .seconds(5)
        )
        #expect(outcome == .fellBack(reason: "validator: meta-text"))
    }

    @Test func protectedTermMutationFallsBack() async {
        let provider = MockProvider(
            result: .success(CleanupResponse(text: "ask Cluade to review it", modelName: "mock-1"))
        )
        let pipeline = CleanupPipeline(provider: provider)
        let outcome = await pipeline.run(
            CleanupRequest(
                text: "ask Claude to review it",
                language: .english,
                protectedTerms: ["Claude"]
            ),
            timeout: .seconds(5)
        )
        #expect(outcome == .fellBack(reason: "protected-terms"))
    }

    @Test func providerErrorFallsBackWithReason() async {
        let provider = MockProvider(result: .failure(.providerUnavailable("connection refused")))
        let pipeline = CleanupPipeline(provider: provider)
        let outcome = await pipeline.run(
            CleanupRequest(text: "meet on saturday", language: .english),
            timeout: .seconds(5)
        )
        #expect(outcome == .fellBack(reason: "provider-unavailable: connection refused"))
    }

    @Test func timeoutFallsBack() async {
        let provider = MockProvider(result: .failure(.timedOut))
        let pipeline = CleanupPipeline(provider: provider)
        let outcome = await pipeline.run(
            CleanupRequest(text: "meet on saturday", language: .english),
            timeout: .milliseconds(10)
        )
        #expect(outcome == .fellBack(reason: "timed-out"))
    }

    @Test func nonCleanupErrorFallsBack() async {
        let pipeline = CleanupPipeline(provider: ExplodingProvider())
        let outcome = await pipeline.run(
            CleanupRequest(text: "meet on saturday", language: .english),
            timeout: .seconds(5)
        )
        #expect(outcome == .fellBack(reason: "provider-error"))
    }
}

// No-network request-building coverage for the HTTP provider (docs/05 §3.2);
// transport paths are exercised only against a live server, never in CI.
struct OpenAICompatibleProviderRequestTests {

    private func makeProvider(urlString: String = "http://localhost:11434") throws
        -> OpenAICompatibleProvider {
        let baseURL = try #require(URL(string: urlString))
        return OpenAICompatibleProvider(baseURL: baseURL, model: "qwen2.5:7b-instruct")
    }

    @Test func requestBodyCarriesPromptsModelAndLimits() throws {
        let provider = try makeProvider()
        let body = provider.makeRequestBody(
            for: CleanupRequest(
                text: "meet on friday sorry saturday",
                language: .english,
                profilePrompt: "Casual tone.",
                protectedTerms: ["Claude"]
            )
        )

        #expect(body.model == "qwen2.5:7b-instruct")
        #expect(body.temperature == 0.2)
        #expect(body.stream == false)
        // 29 chars → 2× char cap, floored at 64 (ZH-safe budget).
        #expect(body.maxTokens == 64)
        #expect(body.messages.count == 2)
        #expect(body.messages.first?.role == "system")
        #expect(body.messages.first?.content.contains("Claude") == true)
        #expect(body.messages.first?.content.contains("Casual tone.") == true)
        #expect(body.messages.last?.role == "user")
        #expect(
            body.messages.last?.content
                == "<TRANSCRIPT>\nmeet on friday sorry saturday\n</TRANSCRIPT>"
        )
    }

    @Test func maxTokensHeuristicIsTwiceCharsWithFloor() {
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 300) == 600)
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 3) == 64)
    }

    @Test func prewarmBodyRequestsSingleToken() throws {
        let provider = try makeProvider()
        #expect(provider.makePrewarmBody().maxTokens == 1)
    }

    @Test func endpointAppendsChatCompletionsPath() throws {
        let provider = try makeProvider()
        #expect(provider.endpointURL.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func localhostEndpointsDoNotLeaveDevice() throws {
        let local = try makeProvider(urlString: "http://localhost:11434")
        #expect(local.leavesDevice == false)

        let loopback = try makeProvider(urlString: "http://127.0.0.1:8080")
        #expect(loopback.leavesDevice == false)

        let remote = try makeProvider(urlString: "https://api.groq.com")
        #expect(remote.leavesDevice == true)

        let overriddenURL = try #require(URL(string: "https://my-mac.example:8080"))
        let overridden = OpenAICompatibleProvider(
            baseURL: overriddenURL, model: "m", leavesDevice: false
        )
        #expect(overridden.leavesDevice == false)
    }

    @Test func bodyEncodesSnakeCaseMaxTokens() throws {
        let provider = try makeProvider()
        let body = provider.makeRequestBody(
            for: CleanupRequest(text: "hello there", language: .english)
        )
        let data = try JSONEncoder().encode(body)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"max_tokens\""))
        #expect(!json.contains("maxTokens"))
    }
}
