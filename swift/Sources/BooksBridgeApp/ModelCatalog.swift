import Foundation
import BooksBridgeCore
import BooksBridgeLLM

public struct ModelStamp: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let name: String
    public let configuration: String
}

struct ServiceModel: Codable, Sendable, Equatable, Identifiable {
    var id = UUID().uuidString
    var revision = UUID().uuidString
    var name: String
    var remoteID: String
    var contextTokens = 32768
    var outputTokens = 2048
    var thinking: AppSettings.ThinkingLevel = .off
    var sendsThinking = false
    var sendsTemperature = true
    var temperature = 0.3
}
struct ModelService: Codable, Sendable, Equatable, Identifiable {
    var id = UUID().uuidString
    var revision = UUID().uuidString
    var name: String
    var baseURL: String
    var enabled = true
    var requiresKey = true
    var models: [ServiceModel] = []
}
struct ModelCatalog: Codable, Equatable {
    var version = 1
    var services: [ModelService] = []
    var defaultChat: String?
    var defaultSummary: String?
}
struct ModelConnection: Sendable {
    let service: ModelService
    let model: ServiceModel
    let key: String
    var stamp: ModelStamp { ModelStamp(providerID: service.id, modelID: model.id,
        name: "\(service.name) / \(model.name)", configuration: service.revision + ":" + model.revision) }
    func canResumeSummary(of book: StoredBook) -> Bool {
        let hasSummary = book.study?.whole != nil || !(book.study?.chapters.isEmpty ?? true)
        return !hasSummary || book.summaryModelStamp?.configuration == stamp.configuration
    }
    func settings(_ general: AppSettings) -> AppSettings {
        var result = general
        result.baseURL = service.baseURL; result.model = model.remoteID
        result.summaryContextTokens = model.contextTokens; result.outputTokens = model.outputTokens
        result.requiresAPIKey = service.requiresKey; result.sendsThinking = model.sendsThinking
        result.sendsTemperature = model.sendsTemperature; result.thinkingLevel = model.thinking
        result.temperature = model.temperature
        return result
    }
    var client: ChatClient { ChatClient(baseURL: service.baseURL, apiKey: key, requiresAPIKey: service.requiresKey, sendsThinking: model.sendsThinking) }
}

/// Metadata and provider-scoped credentials are persisted separately; UI payloads never contain keys.
final class ModelCatalogStore {
    private(set) var state: ModelCatalog
    private var keys: [String: String]
    private let directory: URL
    private var readable = true
    init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
        state = ModelCatalog(); keys = [:]
        do {
            let metadata = directory.appendingPathComponent("models.json")
            let secrets = directory.appendingPathComponent("model-secrets.json")
            if FileManager.default.fileExists(atPath: metadata.path) { state = try JSONDecoder().decode(ModelCatalog.self, from: Data(contentsOf: metadata)) }
            if FileManager.default.fileExists(atPath: secrets.path) { keys = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: secrets)) }
        } catch { readable = false }
    }
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let text): text } }
    }
    func resolve(_ id: String?) throws -> ModelConnection {
        guard readable else { throw Failure.invalid("模型配置文件无法读取，请先修复配置文件。") }
        guard let id, let service = state.services.first(where: { $0.models.contains { $0.id == id } }),
              service.enabled, let model = service.models.first(where: { $0.id == id }) else { throw Failure.invalid("请选择一个已启用的模型。") }
        try Self.validateURL(service.baseURL)
        let key = keys[service.id] ?? ""
        guard !service.requiresKey || !key.isEmpty else { throw Failure.invalid("请为 \(service.name) 配置 API Key。") }
        return ModelConnection(service: service, model: model, key: key)
    }
    static func validateURL(_ text: String) throws {
        guard let u = URLComponents(string: text), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              u.host?.isEmpty == false, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else {
            throw Failure.invalid("请输入有效的 HTTP(S) API 基础地址，不含密钥、查询参数或片段。")
        }
    }
    private func write(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(".models-\(UUID()).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.invalid("无法保存模型配置。")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    private func change(_ operation: (inout ModelCatalog, inout [String:String]) throws -> Void) throws {
        guard readable else { throw Failure.invalid("模型配置无法读取，已停止覆盖。") }
        var next = state, secrets = keys
        try operation(&next, &secrets)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(next), credentials = try encoder.encode(secrets)
        let oldSecrets = try encoder.encode(keys)
        try write(credentials, name: "model-secrets.json")
        do { try write(metadata, name: "models.json") }
        catch { try? write(oldSecrets, name: "model-secrets.json"); throw error }
        state = next; keys = secrets
    }
    @discardableResult
    func saveService(id: String?, name: String, baseURL: String, enabled: Bool, requiresKey: Bool, key: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.invalid("请填写服务商名称。") }
        try Self.validateURL(url)
        let identifier = id ?? UUID().uuidString
        try change { state, keys in
            if id != nil && !state.services.contains(where: { $0.id == identifier }) { throw Failure.invalid("服务商已删除。") }
            var service = state.services.first { $0.id == identifier } ?? ModelService(id: identifier, name: name, baseURL: url)
            let credential = key?.trimmingCharacters(in: .whitespacesAndNewlines)
            if service.baseURL != url || service.requiresKey != requiresKey || (credential != nil && credential != keys[identifier]) { service.revision = UUID().uuidString }
            service.name = name; service.baseURL = url; service.enabled = enabled; service.requiresKey = requiresKey
            if let credential { keys[identifier] = credential.isEmpty ? nil : credential }
            if let i = state.services.firstIndex(where: { $0.id == identifier }) { state.services[i] = service } else { state.services.append(service) }
        }
        return identifier
    }
    func deleteService(_ id: String) throws {
        try change { state, keys in state.services.removeAll { $0.id == id }; keys[id] = nil }
        // References intentionally remain unresolved instead of silently selecting another endpoint.
    }
    @discardableResult
    func saveModel(serviceID: String, model: ServiceModel) throws -> String {
        guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.remoteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (8192...2_000_000).contains(model.contextTokens), (256...131072).contains(model.outputTokens),
              model.outputTokens <= model.contextTokens / 2, (0...2).contains(model.temperature) else { throw Failure.invalid("请检查模型名称、ID 和上下文/输出限制（上下文至少 8192，输出不超过其一半）。") }
        try change { state, _ in
            guard let i = state.services.firstIndex(where: { $0.id == serviceID }) else { throw Failure.invalid("服务商不存在。") }
            if state.services.enumerated().contains(where: { $0.offset != i && $0.element.models.contains { $0.id == model.id } }) { throw Failure.invalid("模型不属于此服务商。") }
            var model = model
            if let j = state.services[i].models.firstIndex(where: { $0.id == model.id }) {
                let old = state.services[i].models[j]
                model.revision = old.revision
                var comparable = old; comparable.name = model.name
                if comparable != model { model.revision = UUID().uuidString }
                state.services[i].models[j] = model
            } else { state.services[i].models.append(model) }
        }
        return model.id
    }
    /// Import a selection in one transaction. Remote IDs are unique within a provider;
    /// retries preserve existing model identities, tuning, and default selections.
    @discardableResult
    func addModels(serviceID: String, remoteIDs: [String], revision: String) throws -> Int {
        let ids = remoteIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { throw Failure.invalid("请选择有效的模型 ID。") }
        var count = 0
        try change { state, _ in
            guard let i = state.services.firstIndex(where: { $0.id == serviceID }) else { throw Failure.invalid("服务商已删除。") }
            guard state.services[i].revision == revision else { throw Failure.invalid("连接配置已改变，请刷新列表后再添加。") }
            var existing = Set(state.services[i].models.map(\.remoteID))
            let anthropic = URLComponents(string: state.services[i].baseURL)?.host?.lowercased() == "api.anthropic.com"
            for id in ids where existing.insert(id).inserted {
                var model = ServiceModel(name: id, remoteID: id)
                model.sendsTemperature = !anthropic
                state.services[i].models.append(model); count += 1
            }
        }
        return count
    }
    func deleteModel(serviceID: String, id: String) throws {
        try change { state, _ in
            guard let i = state.services.firstIndex(where: { $0.id == serviceID }) else { return }
            state.services[i].models.removeAll { $0.id == id }
        }
    }
    func setDefault(_ purpose: String, id: String?) throws {
        if id != nil { _ = try resolve(id) }
        try change { state, _ in
            if purpose == "chat" { state.defaultChat = id }
            else if purpose == "summary" { state.defaultSummary = id }
            else { throw Failure.invalid("未知模型用途。") }
        }
    }
    func service(_ id: String) -> ModelService? { state.services.first { $0.id == id } }
    func key(for id: String) -> String { keys[id] ?? "" }
    var payload: [String:Any] {
        ["services": state.services.map { service in
            ["id":service.id,"name":service.name,"baseURL":service.baseURL,"enabled":service.enabled,
             "requiresKey":service.requiresKey,"hasKey":!(keys[service.id] ?? "").isEmpty,"revision":service.revision,
             "models":service.models.map { m in
                ["id":m.id,"name":m.name,"remoteID":m.remoteID,"contextTokens":m.contextTokens,"outputTokens":m.outputTokens,
                 "thinking":m.thinking.rawValue,"sendsThinking":m.sendsThinking,"sendsTemperature":m.sendsTemperature,
                 "temperature":m.temperature,"revision":m.revision] as [String:Any]
             }] as [String:Any]
        }, "defaultChat":state.defaultChat ?? "", "defaultSummary":state.defaultSummary ?? "",
         "loadError":readable ? "" : "模型配置文件无法读取，已停止修改。"]
    }
}
