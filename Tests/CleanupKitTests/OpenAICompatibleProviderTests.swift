import CoreModels
import Foundation
import Testing
@testable import CleanupKit

/// The endpoint is assembled from a user-typed server root, so the two things
/// worth pinning are: which roots produce a valid endpoint, and which hosts
/// count as on-device for the privacy badge (FR-7.4).
struct OpenAICompatibleProviderTests {

    private func provider(_ base: String, apiKey: String? = nil) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            baseURL: URL(string: base)!, apiKey: apiKey, model: "qwen2.5:3b-instruct"
        )
    }

    // MARK: - Endpoint assembly

    @Test(
        "every spelling of the server root reaches the same endpoint",
        arguments: [
            "http://localhost:11434",
            "http://localhost:11434/",
            // Ollama's own docs give the OpenAI-compatible base URL with /v1
            // already attached; pasting that used to yield /v1/v1/… and 404.
            "http://localhost:11434/v1",
            "http://localhost:11434/v1/",
        ]
    )
    func rootSpellingsNormalizeToOneEndpoint(base: String) {
        #expect(
            provider(base).endpointURL.absoluteString
                == "http://localhost:11434/v1/chat/completions"
        )
    }

    @Test func aPathPrefixIsPreserved() {
        // Reverse proxies commonly mount the API under a subpath; only a
        // trailing "v1" is ours to strip.
        #expect(
            provider("https://gateway.example.com/llm/v1").endpointURL.absoluteString
                == "https://gateway.example.com/llm/v1/chat/completions"
        )
        #expect(
            provider("https://gateway.example.com/v1x").endpointURL.absoluteString
                == "https://gateway.example.com/v1x/v1/chat/completions"
        )
    }

    /// `URL.pathComponents` percent-decodes; rebuilding from it would turn
    /// tenant%2Fteam into tenant/team — a different resource than configured.
    @Test func percentEncodedPathSegmentsSurvive() {
        #expect(
            provider("https://gw.example.com/tenant%2Fteam/v1").endpointURL.absoluteString
                == "https://gw.example.com/tenant%2Fteam/v1/chat/completions"
        )
    }

    // MARK: - Privacy badge

    @Test(
        "loopback hosts are on-device",
        arguments: ["localhost", "LocalHost", "127.0.0.1", "127.0.0.53", "::1"]
    )
    func loopbackHostsAreOnDevice(host: String) {
        #expect(OpenAICompatibleProvider.isLoopbackHost(host))
    }

    @Test(
        "everything else is treated as leaving the device",
        arguments: ["api.openai.com", "192.168.1.10", "127.example.com", "1270.0.0.1", ""]
    )
    func remoteHostsLeaveTheDevice(host: String) {
        #expect(!OpenAICompatibleProvider.isLoopbackHost(host))
    }

    @Test func leavesDeviceFlagFollowsTheHost() {
        #expect(!provider("http://127.0.0.1:11434/v1").leavesDevice)
        #expect(provider("https://api.openai.com/v1").leavesDevice)
    }

    // MARK: - Request body

    @Test func requestCarriesSystemAndUserMessages() {
        let body = provider("http://localhost:11434").makeRequestBody(
            for: CleanupRequest(text: "meet on saturday", language: .english)
        )
        #expect(body.messages.count == 2)
        #expect(body.messages.first?.role == "system")
        #expect(body.messages.last?.role == "user")
        #expect(body.messages.last?.content.contains("meet on saturday") == true)
        #expect(body.stream == false)
    }

    // MARK: - Transport efficiency (docs/15 step 19)

    /// The prewarm must send the same system prompt the take's own request
    /// will send — a server-side prompt cache reuses the longest common token
    /// prefix, and a `"hi"` warmup shares no prefix with anything.
    @Test func prewarmSendsTheRealSystemPrompt() {
        let request = CleanupRequest(
            text: "",
            language: .english,
            stylePrompt: "Use British spelling.",
            protectedTerms: ["Kubernetes"]
        )
        let body = provider("http://localhost:11434").makePrewarmBody(for: request)
        #expect(body.maxTokens == 1)
        #expect(body.messages.first?.role == "system")
        #expect(
            body.messages.first?.content == PromptAssembler().systemPrompt(for: request)
        )
    }

    @Test func ollamaRequestsCarryKeepAlive() throws {
        let ollama = OpenAICompatibleProvider(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "qwen2.5:3b-instruct",
            id: .ollama(model: "qwen2.5:3b-instruct")
        )
        let body = ollama.makeRequestBody(for: CleanupRequest(text: "hello", language: .english))
        #expect(body.keepAlive != nil)
        let json = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(json.contains("\"keep_alive\""))
    }

    /// Strict OpenAI-compatible servers reject unknown arguments, so the
    /// Ollama-only field must vanish from the wire entirely for other ids.
    @Test func nonOllamaRequestsOmitKeepAlive() throws {
        let body = provider("https://api.openai.com/v1").makeRequestBody(
            for: CleanupRequest(text: "hello", language: .english)
        )
        #expect(body.keepAlive == nil)
        let json = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(!json.contains("keep_alive"))
    }

    @Test func maxTokensNeverStarvesAShortDictation() {
        // The floor is what makes reasoning models usable — see
        // `maxTokensLeavesRoomForAReasoningModelToThink` in CleanupPipelineTests
        // for the measurement behind it. Here we only pin that a tiny dictation
        // is never the thing that starves the budget.
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 0) == 1_024)
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 10) == 1_024)
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 500) == 2_000)
    }
}
