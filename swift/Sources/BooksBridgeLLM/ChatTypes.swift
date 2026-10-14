import Foundation

/// 聊天消息。与 OpenAI 兼容格式一致，DeepSeek 沿用同一套。
public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, content: text) }
}

/// 思考模式。
///
/// DeepSeek 当前的 Chat Completions 用 `thinking` 对象控制，而不是靠选模型名。
/// `reasoning_effort` 同时承担"开关"与"档位"两件事：`none` 关闭思考。
public enum ThinkingMode: Sendable, Equatable {
    case disabled
    case effort(Effort)

    public enum Effort: String, Sendable, CaseIterable {
        case low
        case high
        case max
    }

    /// 序列化成 API 需要的 `thinking` 字段。
    var payload: [String: String] {
        switch self {
        case .disabled:
            ["type": "disabled"]
        case .effort(let effort):
            ["type": "enabled", "reasoning_effort": effort.rawValue]
        }
    }
}

/// 一次补全的用量统计。
///
/// 只用于解析响应，因此声明为 `Decodable`。
/// `prompt_tokens_details.cached_tokens` 是嵌套字段，需要自定义解码。
/// DeepSeek 对命中上下文缓存的前缀计费更低，反复带同一本书时这个值会很高。
public struct TokenUsage: Decodable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let cachedTokens: Int
    public let reasoningTokens: Int

    public init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        cachedTokens: Int = 0,
        reasoningTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }

    private enum PromptDetailsKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }

    private enum CompletionDetailsKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 各字段都可能缺失：不同兼容端点的用量结构不完全一致，缺了就记 0
        promptTokens = (try? container.decode(Int.self, forKey: .promptTokens)) ?? 0
        completionTokens = (try? container.decode(Int.self, forKey: .completionTokens)) ?? 0
        totalTokens = (try? container.decode(Int.self, forKey: .totalTokens)) ?? 0
        if let details = try? container.nestedContainer(
            keyedBy: PromptDetailsKeys.self, forKey: .promptTokensDetails
        ) {
            cachedTokens = (try? details.decode(Int.self, forKey: .cachedTokens)) ?? 0
        } else {
            cachedTokens = 0
        }
        if let details = try? container.nestedContainer(
            keyedBy: CompletionDetailsKeys.self, forKey: .completionTokensDetails
        ) {
            reasoningTokens = (try? details.decode(Int.self, forKey: .reasoningTokens)) ?? 0
        } else {
            reasoningTokens = 0
        }
    }
}

/// 流式增量。
public enum ChatStreamEvent: Sendable {
    /// 正文增量。
    case content(String)
    /// 思考过程增量（仅思考模式会有）。
    case reasoning(String)
    /// 结束，附带用量（若服务端返回）。
    case finished(usage: TokenUsage?, finishReason: String?)
}
