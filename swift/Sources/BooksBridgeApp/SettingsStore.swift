import BooksBridgeCore
import BooksBridgeLLM
import Foundation

/// 应用设置。骨架期只包含 LLM 接入所需的字段，但**不做任何调用**。
///
/// 存储拆成两份：
/// - `settings.json`（0600）：非敏感配置，如服务商、模型名、读取范围
/// - `secret.json`（0600）：API Key 单独存放，避免混在配置里被误分享
///
/// 说明取舍：这里**没有**用 Keychain。Keychain 每次读写都可能弹授权框
/// （尤其对未签名/自签名的本地应用），对一个自用工具来说摩擦过大。
/// 代价是 Key 以明文落盘——已通过 0600 权限限制为仅当前用户可读。
/// 若将来要分发，应改为 Keychain 或让用户每次输入。
public struct AppSettings: Codable, Sendable, Equatable {
    /// 服务商标识。骨架期只做配置，不影响任何行为。
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case deepseek
        case openai
        case anthropic
        case ollama
        case custom

        public var label: String {
            switch self {
            case .deepseek: "DeepSeek"
            case .openai: "OpenAI"
            case .anthropic: "Anthropic"
            case .ollama: "Ollama（本地）"
            case .custom: "自定义"
            }
        }

        /// 默认接口地址。
        public var defaultBaseURL: String {
            switch self {
            case .deepseek: "https://api.deepseek.com/v1"
            case .openai: "https://api.openai.com/v1"
            case .anthropic: "https://api.anthropic.com/v1"
            case .ollama: "http://localhost:11434/v1"
            case .custom: ""
            }
        }

        /// 该服务商是否需要 API Key（本地 Ollama 不需要）。
        public var requiresAPIKey: Bool {
            self != .ollama
        }

        /// 常见模型名，仅用于下拉建议。
        public var suggestedModels: [String] {
            switch self {
            case .deepseek: ["deepseek-flash", "deepseek-v4-pro"]
            case .openai: ["gpt-4o", "gpt-4o-mini"]
            case .anthropic: ["claude-sonnet-4-5", "claude-opus-4-1"]
            case .ollama: ["qwen2.5:14b", "llama3.1:8b"]
            case .custom: []
            }
        }
    }

    /// 思考模式的档位。DeepSeek 当前用 `thinking` 对象控制，
    /// 而不是靠选 `deepseek-reasoner` 这种模型名。
    public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
        case off
        case low
        case high
        case max

        public var label: String {
            switch self {
            case .off: "关闭"
            case .low: "低"
            case .high: "高"
            case .max: "最高"
            }
        }

        public var explanation: String {
            switch self {
            case .off: "最快最省，适合简单问答"
            case .low: "轻度推理"
            case .high: "推荐，复杂问题表现更好"
            case .max: "最充分，也最慢最贵"
            }
        }
    }

    public var provider: Provider
    public var baseURL: String
    public var model: String
    public var temperature: Double
    /// 默认的书籍知识范围（对应三档剧透边界）。
    public var defaultScope: KnowledgeScope
    public var maxContextCharacters: Int
    public var thinkingLevel: ThinkingLevel
    public var autoExpandReasoning: Bool

    public init(
        provider: Provider = .deepseek,
        baseURL: String = Provider.deepseek.defaultBaseURL,
        model: String = "deepseek-flash",
        temperature: Double = 0.3,
        defaultScope: KnowledgeScope = .upToProgress,
        maxContextCharacters: Int = 12_000,
        thinkingLevel: ThinkingLevel = .off,
        autoExpandReasoning: Bool = false
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.defaultScope = defaultScope
        self.maxContextCharacters = maxContextCharacters
        self.thinkingLevel = thinkingLevel
        self.autoExpandReasoning = autoExpandReasoning
    }

    /// 解码旧版本配置文件时缺字段要能兜底，否则升级后会读不出设置。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(Provider.self, forKey: .provider)) ?? .deepseek
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? Provider.deepseek.defaultBaseURL
        model = (try? c.decode(String.self, forKey: .model)) ?? "deepseek-flash"
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0.3
        defaultScope = (try? c.decode(KnowledgeScope.self, forKey: .defaultScope)) ?? .upToProgress
        maxContextCharacters = (try? c.decode(Int.self, forKey: .maxContextCharacters)) ?? 12_000
        thinkingLevel = (try? c.decode(ThinkingLevel.self, forKey: .thinkingLevel)) ?? .off
        autoExpandReasoning = (try? c.decode(Bool.self, forKey: .autoExpandReasoning)) ?? false
    }
}

/// `AppSettings` + API Key 的读写。
public final class SettingsStore {
    public private(set) var settings: AppSettings
    public private(set) var apiKey: String

    private let settingsURL: URL
    private let secretURL: URL
    private let fileManager: FileManager

    public init(
        directory: URL = AppPaths.supportDirectory,
        fileManager: FileManager = .default
    ) {
        self.settingsURL = directory.appendingPathComponent("settings.json")
        self.secretURL = directory.appendingPathComponent("secret.json")
        self.fileManager = fileManager
        self.settings = Self.loadSettings(from: settingsURL)
        self.apiKey = Self.loadAPIKey(from: secretURL)
    }

    // MARK: - 读取

    private static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    private struct Secret: Codable {
        var apiKey: String
    }

    private static func loadAPIKey(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let secret = try? JSONDecoder().decode(Secret.self, from: data) else {
            return ""
        }
        return secret.apiKey
    }

    // MARK: - 写入

    public func update(_ transform: (inout AppSettings) -> Void) {
        transform(&settings)
        persistSettings()
    }

    public func setAPIKey(_ key: String) {
        apiKey = key
        persistSecret()
    }

    private func persistSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        write(data, to: settingsURL)
    }

    private func persistSecret() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Secret(apiKey: apiKey)) else { return }
        write(data, to: secretURL)
    }

    /// 原子写 + 0600 权限（只有当前用户可读写）。
    private func write(_ data: Data, to url: URL) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: temp, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
            // replaceItemAt 可能带回原文件权限，再设一次确保 0600
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[BooksBridge] 写入设置失败: \(error.localizedDescription)")
        }
    }

    /// 供 UI 展示：API Key 是否已配置（不回传明文原值以外的信息）。
    public var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否可以认为"配置完成"。骨架期用来在 UI 上显示状态，不触发任何请求。
    public var isConfigured: Bool {
        let needsKey = settings.provider.requiresAPIKey
        let hasValidURL = !settings.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let hasModel = !settings.model.trimmingCharacters(in: .whitespaces).isEmpty
        return hasValidURL && hasModel && (!needsKey || hasAPIKey)
    }
}

// MARK: - 与 LLM 层的衔接

extension AppSettings.ThinkingLevel {
    /// 转成客户端需要的 `ThinkingMode`。
    ///
    /// 两层各留一个枚举是有意的：设置层的取值要落盘、要能向后兼容地演进，
    /// LLM 层的取值要贴合 API 形状。显式转换比共用一个类型更不容易互相牵制。
    public var thinkingMode: ThinkingMode {
        switch self {
        case .off: .disabled
        case .low: .effort(.low)
        case .high: .effort(.high)
        case .max: .effort(.max)
        }
    }
}
