import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stage-3 adapter for any OpenAI-compatible chat-completions endpoint —
/// OpenAI, Groq, DeepSeek, LM Studio, llama.cpp server, or Ollama's
/// OpenAI-compatible surface (docs/05 §3.2). `baseURL` is the server root
/// (e.g. `http://localhost:11434`); `/v1/chat/completions` is appended.
public actor OpenAICompatibleProvider: CleanupProvider {
    public nonisolated let id: CleanupProviderID
    /// True when requests leave the device — drives the HUD privacy badge
    /// (FR-7.4). Defaults to loopback detection on `baseURL`.
    public nonisolated let leavesDevice: Bool

    nonisolated let baseURL: URL
    nonisolated let apiKey: String?
    nonisolated let model: String
    nonisolated let temperature: Double
    nonisolated let assembler: PromptAssembler

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        model: String,
        temperature: Double = 0.2,
        id: CleanupProviderID? = nil,
        leavesDevice: Bool? = nil,
        promptAssembler: PromptAssembler = PromptAssembler()
    ) {
        let host = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.host ?? ""
        let isLoopback = Self.isLoopbackHost(host)
        self.baseURL = Self.normalizedRoot(baseURL)
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.id = id ?? .openAICompatible(name: host.isEmpty ? "custom" : host)
        self.leavesDevice = leavesDevice ?? !isLoopback
        self.assembler = promptAssembler
    }

    // MARK: - Base-URL normalization

    /// Trims the server root to what `endpointURL` expects.
    ///
    /// The documented base URL for several servers — Ollama's OpenAI-compatible
    /// surface among them — already *includes* `/v1`, and that is what users
    /// paste into the settings field. Appending our own `v1` to it produced
    /// `/v1/v1/chat/completions`, a 404 that looks exactly like "the server is
    /// down": cleanup silently fell back on every dictation. Accept both
    /// spellings by reducing either to the bare root. Trailing slashes go too,
    /// since they otherwise yield an empty path component.
    static func normalizedRoot(_ url: URL) -> URL {
        var components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if components.last?.lowercased() == "v1" {
            components.removeLast()
        }
        guard
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.path = components.isEmpty ? "" : "/" + components.joined(separator: "/")
        return parts.url ?? url
    }

    /// Loopback detection for the privacy badge (FR-7.4). Covers IPv6 and the
    /// whole 127.0.0.0/8 block, not just the two spellings people usually type.
    static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".localhost") { return true }
        if lowered == "::1" || lowered == "[::1]" { return true }
        // 127.0.0.0/8 — any address in the block is loopback.
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets[0] == "127",
            octets.allSatisfy({ UInt8($0) != nil })
        {
            return true
        }
        return false
    }

    // MARK: - CleanupProvider

    /// True when the server answers HTTP at all (any status) within 2 s.
    public func isAvailable() async -> Bool {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1").appendingPathComponent("models")
        )
        request.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            _ = try await perform(request, timeout: .seconds(2))
            return true
        } catch {
            return false
        }
    }

    /// Sends a 1-max_token request so the served model is loaded before the
    /// dictation finishes; all errors are ignored (fire-and-forget warmup).
    public func prewarm() async {
        guard let request = try? makeURLRequest(body: makePrewarmBody(), timeout: .seconds(5))
        else { return }
        _ = try? await perform(request, timeout: .seconds(5))
    }

    public func cleanup(
        _ request: CleanupRequest, timeout: Duration
    ) async throws -> CleanupResponse {
        let urlRequest = try makeURLRequest(body: makeRequestBody(for: request), timeout: timeout)
        let reply = try await perform(urlRequest, timeout: timeout)
        guard (200..<300).contains(reply.statusCode) else {
            throw CleanupError.providerUnavailable("HTTP \(reply.statusCode)")
        }
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: reply.body)
        } catch {
            throw CleanupError.malformedOutput("undecodable chat completion response")
        }
        guard let content = decoded.choices.first?.message.content else {
            throw CleanupError.malformedOutput("response contained no choices")
        }
        return CleanupResponse(text: content, modelName: decoded.model ?? model)
    }

    // MARK: - Request building (internal for tests)

    nonisolated var endpointURL: URL {
        baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }

    nonisolated func makeRequestBody(for request: CleanupRequest) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model,
            messages: [
                ChatCompletionRequest.Message(
                    role: "system", content: assembler.systemPrompt(for: request)
                ),
                ChatCompletionRequest.Message(
                    role: "user", content: assembler.userMessage(for: request)
                ),
            ],
            temperature: temperature,
            maxTokens: Self.maxTokens(forInputCharacterCount: request.text.count),
            stream: false
        )
    }

    nonisolated func makePrewarmBody() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model,
            messages: [ChatCompletionRequest.Message(role: "user", content: "hi")],
            temperature: 0,
            maxTokens: 1,
            stream: false
        )
    }

    /// 2× the input token estimate (chars/3 heuristic), floored at 16 so tiny
    /// dictations still leave the model room to answer.
    static func maxTokens(forInputCharacterCount count: Int) -> Int {
        // max_tokens is a cap, not a target; overshoot is free on local
        // endpoints. Chinese tokenizes near 1–2 tokens per character, so a
        // chars/3 estimate silently truncated ZH output mid-sentence.
        max(64, 2 * count)
    }

    nonisolated func makeURLRequest(
        body: ChatCompletionRequest, timeout: Duration
    ) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.seconds(from: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw CleanupError.transport("failed to encode request body")
        }
        return request
    }

    static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    // MARK: - Transport

    private struct HTTPReply: Sendable {
        var statusCode: Int
        var body: Data
    }

    private func perform(_ request: URLRequest, timeout: Duration) async throws -> HTTPReply {
        let configuration = URLSessionConfiguration.ephemeral
        let interval = Self.seconds(from: timeout)
        configuration.timeoutIntervalForRequest = interval
        configuration.timeoutIntervalForResource = interval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<HTTPReply, any Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(
                            returning: HTTPReply(statusCode: http.statusCode, body: data ?? Data())
                        )
                    } else {
                        continuation.resume(
                            throwing: CleanupError.transport("non-HTTP response")
                        )
                    }
                }
                task.resume()
            }
        } catch let error as CleanupError {
            throw error
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw CleanupError.timedOut
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                throw CleanupError.timedOut
            }
            throw CleanupError.transport(String(describing: error))
        }
    }
}

/// OpenAI chat-completions request payload (the subset this provider sends).
struct ChatCompletionRequest: Codable, Sendable, Equatable {
    struct Message: Codable, Sendable, Equatable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var temperature: Double
    var maxTokens: Int
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

/// OpenAI chat-completions response payload (the subset this provider reads).
struct ChatCompletionResponse: Codable, Sendable {
    struct Choice: Codable, Sendable {
        var message: ChatCompletionRequest.Message
    }

    var choices: [Choice]
    var model: String?
}
