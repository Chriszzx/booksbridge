import XCTest

@testable import BooksBridgeLLM

/// SSE 流式解析。
///
/// 这是最容易在边界上出错的地方：分片、空 delta、`[DONE]` 与带 usage 的
/// 最后一条 chunk 往往同时到达，处理顺序错了就会丢用量或截断答案。
final class SSEDecoderTests: XCTestCase {
    func testDecodesContentDelta() throws {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        guard case .content(let text)? = SSEDecoder.decode(line: line) else {
            return XCTFail("应解析出 content 增量")
        }
        XCTAssertEqual(text, "你好")
    }

    func testDecodesReasoningDelta() throws {
        let line = #"data: {"choices":[{"delta":{"reasoning_content":"让我想想"}}]}"#
        guard case .reasoning(let text)? = SSEDecoder.decode(line: line) else {
            return XCTFail("应解析出 reasoning 增量")
        }
        XCTAssertEqual(text, "让我想想")
    }

    func testPrefersReasoningOverContentWhenBothPresent() throws {
        let line = #"data: {"choices":[{"delta":{"reasoning_content":"想","content":"答"}}]}"#
        guard case .reasoning(let text)? = SSEDecoder.decode(line: line) else {
            return XCTFail("两者同时出现时应先出 reasoning")
        }
        XCTAssertEqual(text, "想")
    }

    func testDoneMarkerFinishes() throws {
        guard case .finished = SSEDecoder.decode(line: "data: [DONE]")! else {
            return XCTFail("[DONE] 应结束流")
        }
    }

    func testFinishReasonWithUsage() throws {
        let line = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_tokens_details":{"cached_tokens":64},"completion_tokens_details":{"reasoning_tokens":5}}}"#
        guard case .finished(let usage, let reason)? = SSEDecoder.decode(line: line) else {
            return XCTFail("应解析出结束事件")
        }
        XCTAssertEqual(reason, "stop")
        let u = try XCTUnwrap(usage)
        XCTAssertEqual(u.promptTokens, 100)
        XCTAssertEqual(u.completionTokens, 20)
        XCTAssertEqual(u.totalTokens, 120)
        XCTAssertEqual(u.cachedTokens, 64, "嵌套的 cached_tokens 要解出来——它直接影响计费")
        XCTAssertEqual(u.reasoningTokens, 5)
    }

    func testIgnoresCommentsAndBlankLines() {
        XCTAssertNil(SSEDecoder.decode(line: ""))
        XCTAssertNil(SSEDecoder.decode(line: ": keep-alive"))
        XCTAssertNil(SSEDecoder.decode(line: "event: ping"))
    }

    func testIgnoresEmptyDelta() {
        // 有些服务端会发只有 role 的起始 chunk
        XCTAssertNil(SSEDecoder.decode(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
    }

    func testMalformedJSONDoesNotThrow() {
        // 单行解析失败应被忽略，不能中断整个流
        XCTAssertNil(SSEDecoder.decode(line: #"data: {这不是 JSON"#))
    }

    func testUsageMissingFieldsDegradeToZero() throws {
        let line = #"data: {"choices":[{"delta":{},"finish_reason":"length"}],"usage":{}}"#
        guard case .finished(let usage, _)? = SSEDecoder.decode(line: line) else {
            return XCTFail("应解析出结束事件")
        }
        let u = try XCTUnwrap(usage)
        XCTAssertEqual(u.promptTokens, 0, "缺字段应退化为 0 而不是解析失败")
        XCTAssertEqual(u.cachedTokens, 0)
    }
}

/// 请求构造。
///
/// Base URL 的规范化最容易踩坑：用户可能填带 /v1 的、不带的、带尾斜杠的，
/// 拼错就是 404。
final class ChatClientRequestTests: XCTestCase {
    private func client(_ base: String) -> ChatClient {
        ChatClient(baseURL: base, apiKey: "sk-test")
    }

    func testPreservesExplicitBasePathWithoutGuessingVersion() throws {
        let url = try client("https://example.test/gateway").endpointURL()
        XCTAssertEqual(url.absoluteString, "https://example.test/gateway/chat/completions")
    }

    func testKeepsExistingVersionSegment() throws {
        let url = try client("https://api.deepseek.com/v1").endpointURL()
        XCTAssertEqual(url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    }

    func testHandlesTrailingSlash() throws {
        let url = try client("https://api.deepseek.com/v1/").endpointURL()
        XCTAssertEqual(url.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    }

    func testRespectsFullyQualifiedEndpoint() throws {
        let url = try client("https://example.com/openai/v1/chat/completions").endpointURL()
        XCTAssertEqual(url.absoluteString, "https://example.com/openai/v1/chat/completions")
    }

    func testCustomPortAndPath() throws {
        let url = try client("http://localhost:11434/v1").endpointURL()
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testEmptyBaseURLThrows() {
        XCTAssertThrowsError(try client("").endpointURL())
    }

    func testMissingAPIKeyThrows() {
        let c = ChatClient(baseURL: "https://api.deepseek.com", apiKey: "  ")
        XCTAssertThrowsError(try c.makeRequest(
            model: "deepseek-flash", messages: [], thinking: .disabled,
            temperature: nil, maxTokens: nil, stream: false
        ))
    }

    func testRequestBodyShape() throws {
        let request = try client("https://api.deepseek.com").makeRequest(
            model: "deepseek-flash",
            messages: [.system("S"), .user("U")],
            thinking: .effort(.high),
            temperature: 0.3,
            maxTokens: 1000,
            stream: true
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 1000)

        let thinking = try XCTUnwrap(json["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "enabled")
        XCTAssertEqual(thinking["reasoning_effort"], "high")

        let streamOptions = try XCTUnwrap(json["stream_options"] as? [String: Any])
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true, "要拿到用量必须显式开启")
    }

    func testDisabledThinkingPayload() throws {
        let request = try client("https://api.deepseek.com").makeRequest(
            model: "deepseek-flash", messages: [], thinking: .disabled,
            temperature: nil, maxTokens: nil, stream: false
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let thinking = try XCTUnwrap(json["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
        XCTAssertNil(thinking["reasoning_effort"])
        XCTAssertNil(json["stream_options"], "非流式请求不该带 stream_options")
    }

    func testThinkingEffortsSerialize() {
        XCTAssertEqual(ThinkingMode.effort(.low).payload["reasoning_effort"], "low")
        XCTAssertEqual(ThinkingMode.effort(.high).payload["reasoning_effort"], "high")
        XCTAssertEqual(ThinkingMode.effort(.max).payload["reasoning_effort"], "max")
    }
}
