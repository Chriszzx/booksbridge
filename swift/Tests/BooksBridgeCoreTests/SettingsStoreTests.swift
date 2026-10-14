import XCTest

@testable import BooksBridgeApp

/// `SettingsStore` 的持久化与判定逻辑。
final class SettingsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("booksbridge-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(directory: directory)
    }

    // MARK: - 默认值与往返

    func testDefaultsWhenNoFiles() {
        let store = makeStore()
        XCTAssertEqual(store.settings.provider, .deepseek)
        XCTAssertEqual(store.settings.model, "deepseek-flash", "DeepSeek 当前的主模型标识")
        XCTAssertFalse(store.hasAPIKey)
    }

    func testThinkingLevelDefaultsToOff() {
        XCTAssertEqual(makeStore().settings.thinkingLevel, .off, "默认关闭思考模式：更快更省")
    }

    func testThinkingLevelRoundTrip() {
        let store = makeStore()
        store.update { $0.thinkingLevel = .high }
        XCTAssertEqual(makeStore().settings.thinkingLevel, .high)
    }

    func testDecodingLegacySettingsWithoutThinkingLevel() throws {
        // 旧版本配置文件没有 thinkingLevel 字段，升级后必须能读出来而不是报错
        let legacy = """
        {"provider":"deepseek","baseURL":"https://api.deepseek.com/v1",
         "model":"deepseek-chat","temperature":0.5,
         "defaultScope":"currentChapter","maxContextCharacters":8000}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("settings.json"))
        let store = makeStore()
        XCTAssertEqual(store.settings.model, "deepseek-chat")
        XCTAssertEqual(store.settings.thinkingLevel, .off, "缺字段应兜底为默认值")
        XCTAssertEqual(store.settings.defaultScope, .currentChapter)
    }

    func testSettingsRoundTrip() {
        let store = makeStore()
        store.update { draft in
            draft.provider = .openai
            draft.model = "gpt-4o"
            draft.baseURL = "https://example.com/v1"
            draft.temperature = 1.2
            draft.defaultScope = .upToProgress
            draft.maxContextCharacters = 5000
        }

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.settings.provider, .openai)
        XCTAssertEqual(reloaded.settings.model, "gpt-4o")
        XCTAssertEqual(reloaded.settings.baseURL, "https://example.com/v1")
        XCTAssertEqual(reloaded.settings.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.settings.defaultScope, .upToProgress)
        XCTAssertEqual(reloaded.settings.maxContextCharacters, 5000)
    }

    func testAPIKeyRoundTrip() {
        let store = makeStore()
        store.setAPIKey("sk-test-123")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.apiKey, "sk-test-123")
        XCTAssertTrue(reloaded.hasAPIKey)
    }

    func testClearingAPIKey() {
        let store = makeStore()
        store.setAPIKey("sk-test")
        store.setAPIKey("")
        XCTAssertFalse(makeStore().hasAPIKey)
    }

    // MARK: - 文件权限

    func testSecretsAreWrittenWith0600() throws {
        let store = makeStore()
        store.setAPIKey("sk-secret")
        store.update { $0.model = "x" }

        for name in ["secret.json", "settings.json"] {
            let path = directory.appendingPathComponent(name).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(
                permissions & 0o777, 0o600,
                "\(name) 应以 0600 保存（API Key 不应对同机其他用户可读）"
            )
        }
    }

    func testAPIKeyIsNotInSettingsFile() throws {
        let store = makeStore()
        store.setAPIKey("sk-must-not-leak")
        store.update { $0.model = "m" }

        let settingsText = try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(settingsText.contains("sk-must-not-leak"), "API Key 不应混在 settings.json 里")
    }

    // MARK: - 配置判定

    func testConfiguredRequiresKeyForCloudProviders() {
        let store = makeStore()
        store.update { $0.provider = .openai; $0.model = "gpt-4o" }
        XCTAssertFalse(store.isConfigured, "云服务商缺 Key 时不算配置完成")

        store.setAPIKey("sk-x")
        XCTAssertTrue(store.isConfigured)
    }

    func testOllamaDoesNotRequireKey() {
        let store = makeStore()
        store.update { draft in
            draft.provider = .ollama
            draft.model = "qwen2.5:14b"
            draft.baseURL = "http://localhost:11434/v1"
        }
        XCTAssertTrue(store.isConfigured, "本地 Ollama 不需要 API Key")
    }

    func testEmptyModelIsNotConfigured() {
        let store = makeStore()
        store.setAPIKey("sk-x")
        store.update { $0.model = "" }
        XCTAssertFalse(store.isConfigured)
    }

    func testEmptyBaseURLIsNotConfigured() {
        let store = makeStore()
        store.setAPIKey("sk-x")
        store.update { $0.baseURL = "" }
        XCTAssertFalse(store.isConfigured)
    }

    // MARK: - 服务商元数据

    func testEveryProviderExceptOllamaRequiresKey() {
        for provider in AppSettings.Provider.allCases {
            if provider == .ollama {
                XCTAssertFalse(provider.requiresAPIKey)
            } else {
                XCTAssertTrue(provider.requiresAPIKey, "\(provider.rawValue) 应需要 API Key")
            }
        }
    }

    func testCloudProvidersHaveDefaultBaseURL() {
        for provider in AppSettings.Provider.allCases where provider != .custom {
            XCTAssertFalse(provider.defaultBaseURL.isEmpty, "\(provider.rawValue) 应有默认地址")
        }
    }

    func testCorruptSettingsFallBackToDefaults() throws {
        try Data("{ 坏掉的 JSON".utf8)
            .write(to: directory.appendingPathComponent("settings.json"))

        let store = makeStore()
        XCTAssertEqual(store.settings.provider, .deepseek, "损坏时应回退到默认值而不是崩溃")
    }
}
