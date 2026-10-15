import Foundation

/// OpenAI 兼容的 Chat Completions 客户端。
///
/// 只做一件事：把消息发出去、把增量流回来。不掺业务逻辑，
/// 因此 BookKnowledge 预处理和问答可以共用同一个客户端。
///
/// 兼容性：DeepSeek 官方 API 与 OpenAI 的 `/chat/completions` 请求/响应结构一致，
/// 所以同一个客户端也能指向 OpenAI、Ollama 等兼容端点（Base URL 可配）。
public struct ChatClient: Sendable {
    public enum ClientError: Error, CustomStringConvertible, LocalizedError {
        public var errorDescription: String? { description }
        case invalidBaseURL(String)
        case missingAPIKey
        case http(status: Int, body: String)
        case decoding(String)
        case transport(String)

        public var description: String {
            switch self {
            case .invalidBaseURL(let raw): "接口地址无效：\(raw)"
            case .missingAPIKey: "未配置 API Key"
            case .http(let status, let body):
                "服务端返回 \(status)：\(Self.summarize(body))"
            case .decoding(let why): "响应解析失败：\(why)"
            case .transport(let why): "网络错误：\(why)"
            }
        }

        /// 服务端的错误体通常很长，截取关键部分。
        private static func summarize(_ body: String) -> String {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return String(trimmed.prefix(300))
        }
    }

    public let baseURL: String
    public let apiKey: String
    public let requiresAPIKey: Bool
    public let sendsThinking: Bool
    public let timeout: TimeInterval

    public init(baseURL: String, apiKey: String, timeout: TimeInterval = 120, requiresAPIKey: Bool = true, sendsThinking: Bool = true) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.requiresAPIKey = requiresAPIKey; self.sendsThinking = sendsThinking
    }

    // MARK: - 请求构造

    /// Base URL is explicit: preserve custom gateway prefixes instead of guessing /v1.
    public func endpointURL() throws -> URL { try endpoint("chat/completions") }
    public func endpoint(_ suffix: String) throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let parts = URLComponents(string: raw), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { throw ClientError.invalidBaseURL(baseURL) }
        if raw.hasSuffix("/chat/completions") { raw = String(raw.dropLast("/chat/completions".count)) }
        return URL(string: raw + "/" + suffix)!
    }
    public func listModels() async throws -> [String] {
        guard !requiresAPIKey || !apiKey.isEmpty else { throw ClientError.missingAPIKey }
        var request = URLRequest(url: try endpoint("models")); request.timeoutInterval = 15
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data,response) = try await send(request); try validate(response,data)
        struct Listing: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        return Array(Set(try JSONDecoder().decode(Listing.self, from: data).data.map(\.id))).sorted()
    }

    struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let temperature: Double?
        let maxTokens: Int?
        let thinking: [String: String]?
        let streamOptions: StreamOptions?

        struct StreamOptions: Encodable {
            /// 让最后一个 chunk 带上用量统计。
            let includeUsage = true
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature, thinking
            case maxTokens = "max_tokens"
            case streamOptions = "stream_options"
        }
    }

    func makeRequest(
        model: String,
        messages: [ChatMessage],
        thinking: ThinkingMode,
        temperature: Double?,
        maxTokens: Int?,
        stream: Bool
    ) throws -> URLRequest {
        guard !requiresAPIKey || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ClientError.missingAPIKey
        }
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")

        let body = RequestBody(
            model: model,
            messages: messages,
            stream: stream,
            temperature: temperature,
            maxTokens: maxTokens,
            thinking: sendsThinking ? thinking.payload : nil,
            streamOptions: stream ? RequestBody.StreamOptions() : nil
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - 非流式

    /// 一次性取回完整回答。预处理这类"不需要逐字展示"的场景用它更省事。
    public func complete(
        model: String,
        messages: [ChatMessage],
        thinking: ThinkingMode = .disabled,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        requireComplete: Bool = false
    ) async throws -> (text: String, usage: TokenUsage?) {
        let request = try makeRequest(
            model: model, messages: messages, thinking: thinking,
            temperature: temperature, maxTokens: maxTokens, stream: false
        )
        let (data, response) = try await send(request)
        try validate(response, data)

        return try Self.decodeCompletion(data, requireComplete: requireComplete)
    }

    static func decodeCompletion(_ data: Data, requireComplete: Bool) throws -> (text: String, usage: TokenUsage?) {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finishReason: String?
                enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]
            let usage: TokenUsage?
        }
        do {
            let decoded = try JSONDecoder().decode(Completion.self, from: data)
            let text = decoded.choices.first?.message.content ?? ""
            if requireComplete, let reason = decoded.choices.first?.finishReason, reason != "stop" {
                throw ClientError.decoding("摘要未完整结束（\(reason)），未标记为完成；请调整预算后继续。")
            }
            return (text, decoded.usage)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    // MARK: - 流式

    /// 流式补全。按增量产 `ChatStreamEvent`。
    public func stream(
        model: String,
        messages: [ChatMessage],
        thinking: ThinkingMode = .disabled,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        model: model, messages: messages, thinking: thinking,
                        temperature: temperature, maxTokens: maxTokens, stream: true
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.transport("非 HTTP 响应")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // 错误体在流里，需要读完才能给出可读信息
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ClientError.http(status: http.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let event = SSEDecoder.decode(line: line) else { continue }
                        if case .finished = event { continuation.yield(event); break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 传输

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}
