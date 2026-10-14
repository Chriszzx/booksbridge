import Foundation

/// Server-Sent Events 解码。
///
/// DeepSeek 与 OpenAI 的流式格式一致：每行形如
/// ```
/// data: {"choices":[{"delta":{"content":"你"}}]}
/// data: [DONE]
/// ```
/// 另外可能有 `: keep-alive` 注释行与空行，需要跳过。
///
/// 拆成独立类型是为了可单测——流式解析最容易在边界上出错
/// （分片、空 delta、`[DONE]` 与最后一条 usage 同时到达）。
enum SSEDecoder {
    /// 增量响应体。
    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoningContent: String?
                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]?
        let usage: TokenUsage?
    }

    /// 解码一行 SSE。返回 nil 表示这行不含有效事件（注释、空行、心跳）。
    static func decode(line: String) -> ChatStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 注释行与空行
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }
        // 只处理 data 字段
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }

        if payload == "[DONE]" {
            return .finished(usage: nil, finishReason: nil)
        }

        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else {
            // 单行解析失败不应中断整个流：服务端偶尔会插入非标准行
            return nil
        }

        let choice = chunk.choices?.first
        let finishReason = choice?.finishReason

        // 最后一条 chunk 可能同时带 finish_reason 与 usage，但没有新内容
        if finishReason != nil {
            return .finished(usage: chunk.usage, finishReason: finishReason)
        }

        if let reasoning = choice?.delta?.reasoningContent, !reasoning.isEmpty {
            return .reasoning(reasoning)
        }
        if let content = choice?.delta?.content, !content.isEmpty {
            return .content(content)
        }
        return nil
    }
}
