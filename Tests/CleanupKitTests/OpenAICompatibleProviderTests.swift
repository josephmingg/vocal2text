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

    @Test func maxTokensNeverStarvesAShortDictation() {
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 0) == 64)
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 10) == 64)
        #expect(OpenAICompatibleProvider.maxTokens(forInputCharacterCount: 500) == 1_000)
    }
}
