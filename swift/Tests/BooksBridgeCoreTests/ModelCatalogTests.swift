import XCTest
import Foundation
import BooksBridgeCore
@testable import BooksBridgeApp
@testable import BooksBridgeLLM

final class ModelCatalogTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-model-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testProviderKeysAreIsolatedAndNeverReturnedInPayload() throws {
        let url = try directory(), store = ModelCatalogStore(directory: url)
        let a = try store.saveService(id: nil, name: "Same", baseURL: "https://a.example.test/v1", enabled: true, requiresKey: true, key: "key-A")
        let b = try store.saveService(id: nil, name: "Same", baseURL: "https://b.example.test/v1", enabled: true, requiresKey: true, key: "key-B")
        let ma = ServiceModel(name: "Same model", remoteID: "remote"), mb = ServiceModel(name: "Same model", remoteID: "remote")
        try store.saveModel(serviceID: a, model: ma); try store.saveModel(serviceID: b, model: mb)
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(ma.id, mb.id)
        let loaded = ModelCatalogStore(directory: url)
        XCTAssertEqual(try loaded.resolve(ma.id).key, "key-A"); XCTAssertEqual(try loaded.resolve(mb.id).key, "key-B")
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: loaded.payload), as: UTF8.self)
        XCTAssertFalse(payload.contains("key-A")); XCTAssertFalse(payload.contains("key-B"))
        let metadata = try String(contentsOf: url.appendingPathComponent("models.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("key-A"))
        for name in ["models.json", "model-secrets.json"] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }
    func testDefaultsAreIndependentAndDeletedReferencesNeverFallback() throws {
        let store = ModelCatalogStore(directory: try directory())
        let p = try store.saveService(id: nil, name: "Local", baseURL: "http://localhost:11434/v1", enabled: true, requiresKey: false)
        let a = ServiceModel(name: "Chat", remoteID: "chat"), b = ServiceModel(name: "Summary", remoteID: "summary")
        try store.saveModel(serviceID: p, model: a); try store.saveModel(serviceID: p, model: b)
        try store.setDefault("chat", id: a.id); try store.setDefault("summary", id: b.id)
        XCTAssertEqual(try store.resolve(store.state.defaultChat).model.remoteID, "chat")
        XCTAssertEqual(try store.resolve(store.state.defaultSummary).model.remoteID, "summary")
        try store.deleteModel(serviceID: p, id: a.id)
        XCTAssertEqual(store.state.defaultChat, a.id)
        XCTAssertThrowsError(try store.resolve(store.state.defaultChat))
        XCTAssertEqual(try store.resolve(store.state.defaultSummary).model.id, b.id)
        try store.deleteService(p)
        XCTAssertThrowsError(try store.resolve(b.id)); XCTAssertEqual(store.key(for: p), "")
    }
    func testRenameKeepsIdentityButConfigurationChangesInvalidateSummaryResume() throws {
        let store = ModelCatalogStore(directory: try directory())
        let p = try store.saveService(id: nil, name: "Service", baseURL: "https://example.test/v1", enabled: true, requiresKey: true, key: "before")
        var model = ServiceModel(name: "Original", remoteID: "model")
        try store.saveModel(serviceID: p, model: model)
        let original = try store.resolve(model.id)
        try store.saveService(id: p, name: "Renamed", baseURL: "https://example.test/v1", enabled: true, requiresKey: true)
        model.name = "Renamed model"; try store.saveModel(serviceID: p, model: model)
        XCTAssertEqual(try store.resolve(model.id).stamp.configuration, original.stamp.configuration)
        try store.saveService(id: p, name: "Renamed", baseURL: "https://other.example.test/v1", enabled: true, requiresKey: true, key: "after")
        XCTAssertNotEqual(try store.resolve(model.id).stamp.configuration, original.stamp.configuration)
        // A connection captured before an async request is an immutable value snapshot.
        XCTAssertEqual(original.key, "before"); XCTAssertEqual(original.service.baseURL, "https://example.test/v1")
        model.contextTokens *= 2; try store.saveModel(serviceID: p, model: model)
        XCTAssertNotEqual(try store.resolve(model.id).model.revision, original.model.revision)
    }
    func testDisabledAndMissingKeyModelsCannotBeSelected() throws {
        let store = ModelCatalogStore(directory: try directory())
        let p = try store.saveService(id: nil, name: "Service", baseURL: "https://example.test/v1", enabled: true, requiresKey: true)
        let model = ServiceModel(name: "Model", remoteID: "remote"); try store.saveModel(serviceID: p, model: model)
        XCTAssertThrowsError(try store.setDefault("chat", id: model.id))
        try store.saveService(id: p, name: "Service", baseURL: "https://example.test/v1", enabled: true, requiresKey: true, key: "test")
        XCTAssertNoThrow(try store.resolve(model.id))
        try store.saveService(id: p, name: "Service", baseURL: "https://example.test/v1", enabled: false, requiresKey: true)
        XCTAssertThrowsError(try store.resolve(model.id))
        try store.saveService(id: p, name: "Service", baseURL: "https://example.test/v1", enabled: true, requiresKey: true, key: "")
        XCTAssertThrowsError(try store.resolve(model.id)); XCTAssertEqual(store.key(for:p), "")
    }
    func testBadURLAndBudgetsRejectedAndCorruptCatalogNeverOverwritten() throws {
        for url in ["file:///tmp/x", "https://key:secret@example.test/v1", "https://example.test/v1?key=secret", "https://example.test/v1#fragment"] {
            XCTAssertThrowsError(try ModelCatalogStore.validateURL(url))
        }
        let url = try directory(), store = ModelCatalogStore(directory: url)
        let p = try store.saveService(id:nil, name:"Local", baseURL:"http://localhost:1234/v1", enabled:true, requiresKey:false)
        var model = ServiceModel(name:"Model", remoteID:"remote"); model.outputTokens = model.contextTokens
        XCTAssertThrowsError(try store.saveModel(serviceID:p, model:model))
        let corrupt = Data("corrupted".utf8); try corrupt.write(to:url.appendingPathComponent("models.json"))
        let broken = ModelCatalogStore(directory:url)
        XCTAssertThrowsError(try broken.deleteService(p))
        XCTAssertEqual(try Data(contentsOf:url.appendingPathComponent("models.json")),corrupt)
    }
    func testNoKeyGatewayAndOptionalRequestParameters() throws {
        let client = ChatClient(baseURL:"http://localhost:1234/proxy",apiKey:"",requiresAPIKey:false,sendsThinking:false)
        let request = try client.makeRequest(model:"local",messages:[.user("Hello")],thinking:.disabled,temperature:nil,maxTokens:256,stream:false)
        XCTAssertEqual(request.url?.absoluteString,"http://localhost:1234/proxy/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
        let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        XCTAssertNil(body["thinking"]); XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["model"] as? String,"local"); XCTAssertEqual(body["max_tokens"] as? Int,256)
        XCTAssertThrowsError(try ChatClient(baseURL:"https://example.test/v1",apiKey:"").makeRequest(model:"remote",messages:[.user("Hello")],thinking:.disabled,temperature:nil,maxTokens:nil,stream:false))
    }
    func testBulkImportIsIdempotentProviderScopedAndPreservesTuning() throws {
        let url = try directory(), store = ModelCatalogStore(directory: url)
        let p = try store.saveService(id:nil, name:"Provider", baseURL:"https://example.test/v1", enabled:true, requiresKey:false)
        let q = try store.saveService(id:nil, name:"Anthropic", baseURL:"https://api.anthropic.com/v1", enabled:true, requiresKey:false)
        var existing = ServiceModel(name:"Custom title", remoteID:"existing")
        existing.contextTokens = 65536; existing.outputTokens = 4096
        try store.saveModel(serviceID:p, model:existing); try store.setDefault("chat", id:existing.id)
        let revision = try XCTUnwrap(store.service(p)?.revision)
        XCTAssertEqual(try store.addModels(serviceID:p, remoteIDs:["existing", "new", " new ", "other"], revision:revision), 2)
        XCTAssertEqual(try store.addModels(serviceID:p, remoteIDs:["existing", "new", "other"], revision:revision), 0)
        XCTAssertEqual(store.service(p)?.models.first, existing)
        XCTAssertEqual(store.state.defaultChat, existing.id); XCTAssertNil(store.state.defaultSummary)
        XCTAssertEqual(try store.addModels(serviceID:q, remoteIDs:["new"], revision:store.service(q)!.revision), 1)
        XCTAssertFalse(store.service(q)!.models[0].sendsTemperature)
        XCTAssertNotEqual(store.service(q)!.models[0].id, store.service(p)!.models[1].id)
        XCTAssertEqual(ModelCatalogStore(directory:url).state, store.state)
    }
    func testBulkImportRejectsStaleOrInvalidBatchAndDoesNotPartiallyWrite() throws {
        let url = try directory(), store = ModelCatalogStore(directory:url)
        let p = try store.saveService(id:nil, name:"Local", baseURL:"http://localhost:1234/v1", enabled:true, requiresKey:false)
        let revision = try XCTUnwrap(store.service(p)?.revision), before = store.state
        XCTAssertThrowsError(try store.addModels(serviceID:p, remoteIDs:["valid", " "], revision:revision))
        XCTAssertThrowsError(try store.addModels(serviceID:p, remoteIDs:["valid"], revision:"old"))
        XCTAssertThrowsError(try store.addModels(serviceID:"deleted", remoteIDs:["valid"], revision:revision))
        XCTAssertEqual(store.state,before); XCTAssertEqual(ModelCatalogStore(directory:url).state,before)
        // A file in place of the storage directory deterministically forces a write failure.
        try FileManager.default.removeItem(at:url)
        try Data("blocked".utf8).write(to:url)
        XCTAssertThrowsError(try store.addModels(serviceID:p, remoteIDs:["one","two"], revision:revision))
        XCTAssertEqual(store.state,before)
    }
    @MainActor
    func testModelSelectionsAndActualReplyAttributionSurviveArchiveRestartAndDelete() throws {
        let root = try directory(), file = root.appendingPathComponent("store.json")
        let store = ConversationStore(fileURL:file)
        _ = store.addBook(assetID:"A",title:"Book",author:"")
        let c = try XCTUnwrap(store.createConversation(assetID:"A"))
        let stamp = ModelStamp(providerID:"provider",modelID:"chat",name:"Provider / Original name",configuration:"v1")
        XCTAssertTrue(store.setChatModel(assetID:"A",conversationID:c.id,modelID:"chat"))
        XCTAssertTrue(store.setSummaryModel(assetID:"A",modelID:"summary",stamp:stamp))
        let reply = Conversation.Message(role:.assistant,text:"Answer",reasoning:"Thoughts",reasoningExpanded:true,model:stamp)
        store.appendMessage(assetID:"A",conversationID:c.id,message:reply)
        XCTAssertTrue(store.setArchived(assetID:"A",conversationID:c.id,archived:true))
        let loaded = ConversationStore(fileURL:file)
        XCTAssertEqual(loaded.book(assetID:"A")?.summaryModelID,"summary")
        let restored = try XCTUnwrap(loaded.conversation(assetID:"A",conversationID:c.id))
        XCTAssertEqual(restored.modelID,"chat"); XCTAssertEqual(restored.messages.last?.model,stamp)
        XCTAssertEqual(restored.messages.last?.reasoning,"Thoughts")
        XCTAssertTrue(loaded.setArchived(assetID:"A",conversationID:c.id,archived:false))
        XCTAssertTrue(loaded.changeMessage(assetID:"A",conversationID:c.id,messageID:reply.id))
        XCTAssertTrue(loaded.conversation(assetID:"A",conversationID:c.id)!.messages.isEmpty)
    }
}
