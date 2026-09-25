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
        temperature: Double = 0,
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
    /// Works on the percent-ENCODED path throughout. `URL.pathComponents`
    /// percent-decodes, and rebuilding from decoded segments re-splits any
    /// segment containing an encoded slash — `/tenant%2Fteam/v1` would come
    /// back as `/tenant/team`, a different resource than the user configured.
    static func normalizedRoot(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var segments = parts.percentEncodedPath
            .split(separator: "/")
            .filter { !$0.isEmpty }
        // "v1" contains no percent-encodable characters, so comparing the
        // encoded segment directly is exact.
        if segments.last?.lowercased() == "v1" {
            segments.removeLast()
        }
        parts.percentEncodedPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
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
    ///
    /// Kept for explicit probes (onboarding, a settings change). Deliberately
    /// NOT called on the hotkey press path: the press-time prewarm already
    /// ignores every error, so a preflight probe there was a pure extra HTTP
    /// round-trip before the useful request (docs/15 step 19).
    public func isAvailable() async -> Bool {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1").appendingPathComponent("models")
        )
        request.httpMethod = "GET"
        request.timeoutInterval = Self.seconds(from: .seconds(2))
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            _ = try await perform(request)
            return true
        } catch {
            return false
        }
    }

    /// Sends a 1-max_token request so the served model is loaded before the
    /// dictation finishes; all errors are ignored (fire-and-forget warmup).
    /// Uses a representative English request — see `prewarm(for:)` for the
    /// caller-shaped variant.
    public func prewarm() async {
        await prewarm(for: CleanupRequest(text: "", language: .english))
    }

    /// Prewarm shaped like the requests that will follow (docs/15 step 19).
    ///
    /// The old warmup sent `"hi"`, which loads the model but caches nothing
    /// useful: servers with prompt caching (Ollama included) reuse the longest
    /// common token prefix between requests, and the ~700-token system prompt
    /// is byte-identical on every take for a given language + style + terms.
    /// Sending the real system prompt here means the expensive prefix is
    /// already in the server's KV cache when the dictation's own request
    /// arrives — the cleanup call then only pays for the transcript tokens.
    public func prewarm(for request: CleanupRequest) async {
        guard
            let urlRequest = try? makeURLRequest(
                body: makePrewarmBody(for: request), timeout: .seconds(5)
            )
        else { return }
        _ = try? await perform(urlRequest)
    }

    public func cleanup(
        _ request: CleanupRequest, timeout: Duration
    ) async throws -> CleanupResponse {
        let urlRequest = try makeURLRequest(body: makeRequestBody(for: request), timeout: timeout)
        let reply = try await perform(urlRequest)
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

    /// How long Ollama keeps the model resident after a request. Sent
    /// explicitly so the server's default (5 minutes) cannot silently unload
    /// the model between dictations — a cold reload is a multi-second stall
    /// on the very take that follows a coffee break (docs/15 step 19). Only
    /// Ollama understands the field; strict OpenAI-compatible servers reject
    /// unknown arguments, so it is omitted for every other provider id.
    static let ollamaKeepAlive = "30m"

    nonisolated var keepAliveValue: String? {
        if case .ollama = id { return Self.ollamaKeepAlive }
        return nil
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
            stream: false,
            keepAlive: keepAliveValue
        )
    }

    nonisolated func makePrewarmBody() -> ChatCompletionRequest {
        makePrewarmBody(for: CleanupRequest(text: "", language: .english))
    }

    /// The prewarm request: the real system prompt (so the server's prompt
    /// cache holds the reusable prefix), an empty transcript, and a 1-token
    /// budget so the reply costs nothing.
    nonisolated func makePrewarmBody(for request: CleanupRequest) -> ChatCompletionRequest {
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
            temperature: 0,
            maxTokens: 1,
            stream: false,
            keepAlive: keepAliveValue
        )
    }

    /// 2× the input token estimate (chars/3 heuristic), floored at 16 so tiny
    /// dictations still leave the model room to answer.
    static func maxTokens(forInputCharacterCount count: Int) -> Int {
        // max_tokens is a cap, not a target; overshoot is free on local
        // endpoints. Chinese tokenizes near 1–2 tokens per character, so a
        // chars/3 estimate silently truncated ZH output mid-sentence.
        //
        // Reasoning models (qwen3, deepseek-r1) spend the budget *thinking*
        // before emitting any answer, and Ollama returns that thinking in a
        // separate `reasoning` field — so a budget that runs out mid-thought
        // yields an empty `content`, the validator rejects it, and the app
        // silently delivers the stage-2 text on every single dictation
        // (FR-7.3). Measured: a 48-character dictation cost qwen3:8b 231
        // completion tokens, where the old max(64, 2 * count) allowed 96.
        // The floor is what makes reasoning models usable at all; the cap
        // still exists only to bound a runaway generation, and the validator's
        // ratio ceiling is the real guard against a model that rambles.
        max(1024, 4 * count)
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

    /// One session for every provider instance (docs/15 step 19). Providers
    /// are rebuilt per take (a few string copies, by design — docs/11 G15),
    /// so a per-instance session meant a fresh session, connection pool, and
    /// TLS/TCP handshake on every single request. A shared session keeps the
    /// server connection alive across takes; per-request timeouts come from
    /// `URLRequest.timeoutInterval`, which overrides the configuration.
    /// URLSession is documented thread-safe; the `unsafe` spelling only
    /// covers platforms whose Foundation predates its Sendable annotation.
    private nonisolated(unsafe) static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Ceiling for a whole transfer; each request sets its own (much
        // shorter) timeout on the URLRequest.
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    private func perform(_ request: URLRequest) async throws -> HTTPReply {
        let session = Self.sharedSession

        // Without a cancellation handler, a continuation-based transport is
        // deaf to cancellation: CleanupPipeline's deadline race would abandon
        // this request but the network work would run to its own timeout.
        // The box forwards the cancellation to the URLSession task, closing
        // the one gap between "requested" and "actually stopped".
        let box = DataTaskBox()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
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
                    box.store(task)
                    task.resume()
                }
            } onCancel: {
                box.cancel()
            }
        } catch let error as CleanupError {
            throw error
        } catch {
            if let urlError = error as? URLError,
                urlError.code == .timedOut || urlError.code == .cancelled {
                // .cancelled: the only canceller is the stage-3 deadline race.
                throw CleanupError.timedOut
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
                nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorCancelled {
                throw CleanupError.timedOut
            }
            throw CleanupError.transport(String(describing: error))
        }
    }

    /// Carries the in-flight `URLSessionDataTask` across the cancellation
    /// handler boundary. `onCancel` can fire before `store` (cancelled while
    /// the task is being created), so the box remembers and cancels late.
    private final class DataTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var isCancelled = false

        func store(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let cancelNow = isCancelled
            lock.unlock()
            if cancelNow { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
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
    /// Ollama extension: how long the served model stays resident after this
    /// request (docs/15 step 19). nil (the non-Ollama case) omits the field
    /// entirely — strict OpenAI-compatible servers reject unknown arguments.
    var keepAlive: String? = nil

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
        case keepAlive = "keep_alive"
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
