import XCTest

@testable import BooksBridgeApp
import BooksBridgeLLM

/// `ConversationStore` 的持久化行为。
///
/// 全部用临时目录，绝不碰用户真实的 store.json。
final class ConversationStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("booksbridge-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("store.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ConversationStore {
        ConversationStore(fileURL: fileURL)
    }

    func testScopeCannotBeChangedAndPersists() {
        let store = makeStore()
        store.addBook(assetID: "A", title: "书", author: "")
        let conversation = store.createConversation(assetID: "A")!
        XCTAssertEqual(store.lockScope(assetID: "A", conversationID: conversation.id, requested: .upToProgress), .upToProgress)
        XCTAssertEqual(store.lockScope(assetID: "A", conversationID: conversation.id, requested: .wholeBook), .upToProgress)
        XCTAssertEqual(makeStore().conversation(assetID: "A", conversationID: conversation.id)?.scope, .upToProgress)
    }

    func testNewConversationCanUseDifferentScope() {
        let store = makeStore()
        store.addBook(assetID: "A", title: "书", author: "")
        let first = store.createConversation(assetID: "A")!
        let second = store.createConversation(assetID: "A")!
        _ = store.lockScope(assetID: "A", conversationID: first.id, requested: .upToProgress)
        XCTAssertEqual(store.lockScope(assetID: "A", conversationID: second.id, requested: .wholeBook), .wholeBook)
    }

    func testLegacyHistoryIsExcludedWhenScopeFirstLocks() throws {
        let old = Conversation(title: "旧对话", messages: [.init(role: .assistant, text: "曾经透露的结局")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(old)) as! [String: Any]
        json.removeValue(forKey: "scope")
        json.removeValue(forKey: "scopeHistoryStartIndex")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.scope)
        let store = makeStore()
        store.addBook(assetID: "A", title: "书", author: "")
        let conversation = store.createConversation(assetID: "A")!
        store.appendMessage(assetID: "A", conversationID: conversation.id, message: legacy.messages[0])
        _ = store.lockScope(assetID: "A", conversationID: conversation.id, requested: .upToProgress)
        XCTAssertEqual(makeStore().conversation(assetID: "A", conversationID: conversation.id)?.scopeHistoryStartIndex, 1)
    }

    // MARK: - 基础读写

    func testStartsEmptyWhenFileMissing() {
        let store = makeStore()
        XCTAssertTrue(store.state.books.isEmpty)
        XCTAssertNil(store.state.lastActive)
    }

    func testAddBookPersistsAcrossInstances() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "三体", author: "刘慈欣")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.state.books.count, 1)
        XCTAssertEqual(reloaded.book(assetID: "A1")?.title, "三体")
        XCTAssertEqual(reloaded.book(assetID: "A1")?.author, "刘慈欣")
    }

    func testAddBookIsIdempotentAndRefreshesMetadata() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "旧标题", author: "旧作者")
        store.addBook(assetID: "A1", title: "新标题", author: "新作者")

        XCTAssertEqual(store.state.books.count, 1, "重复加入不应产生第二条记录")
        XCTAssertEqual(store.book(assetID: "A1")?.title, "新标题")
    }

    func testAddBookKeepsExistingConversations() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        store.createConversation(assetID: "A1")
        store.addBook(assetID: "A1", title: "书改名", author: "")

        XCTAssertEqual(store.book(assetID: "A1")?.conversations.count, 1)
    }

    // MARK: - 对话

    func testCreateConversationAutoNumbers() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")

        let first = store.createConversation(assetID: "A1")
        let second = store.createConversation(assetID: "A1")

        XCTAssertEqual(first?.title, "对话 1")
        XCTAssertEqual(second?.title, "对话 2")
        XCTAssertEqual(store.book(assetID: "A1")?.conversations.count, 2)
    }

    func testConversationNumberingSurvivesDeletion() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        let first = store.createConversation(assetID: "A1")!
        _ = store.createConversation(assetID: "A1")

        // 删掉"对话 1"，下一条应该是"对话 3"而不是重复的"对话 2"
        XCTAssertTrue(store.deleteConversation(assetID: "A1", conversationID: first.id))
        let third = store.createConversation(assetID: "A1")

        XCTAssertEqual(third?.title, "对话 3", "编号应取已有最大值 +1，避免重名")
    }

    func testCreateConversationOnUnknownBookReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.createConversation(assetID: "不存在"))
    }

    func testConversationsAreIndependentPerBook() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书一", author: "")
        store.addBook(assetID: "A2", title: "书二", author: "")

        _ = store.createConversation(assetID: "A1")

        XCTAssertEqual(store.book(assetID: "A1")?.conversations.count, 1)
        XCTAssertEqual(store.book(assetID: "A2")?.conversations.count, 0, "对话不应跨书串台")
    }

    func testDeleteConversationReportsWhetherItExisted() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        let conversation = store.createConversation(assetID: "A1")!

        XCTAssertTrue(store.deleteConversation(assetID: "A1", conversationID: conversation.id))
        XCTAssertFalse(store.deleteConversation(assetID: "A1", conversationID: conversation.id),
                       "重复删除应返回 false")
    }

    // MARK: - 活跃位置

    func testActivePositionPersists() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        let conversation = store.createConversation(assetID: "A1")!
        store.setActive(assetID: "A1", conversationID: conversation.id)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.state.lastActive?.assetID, "A1")
        XCTAssertEqual(reloaded.state.lastActive?.conversationID, conversation.id)
    }

    func testRemovingBookFixesDanglingActivePosition() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书一", author: "")
        store.addBook(assetID: "A2", title: "书二", author: "")
        store.setActive(assetID: "A1", conversationID: nil)

        store.removeBook(assetID: "A1")

        XCTAssertEqual(store.state.lastActive?.assetID, "A2", "应自动指向剩下的书，而不是留下悬空引用")
    }

    func testDeleteActiveConversationMovesActiveToSibling() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        let first = store.createConversation(assetID: "A1")!
        let second = store.createConversation(assetID: "A1")!
        store.setActive(assetID: "A1", conversationID: first.id)

        store.deleteConversation(assetID: "A1", conversationID: first.id)

        XCTAssertEqual(store.state.lastActive?.conversationID, second.id)
    }

    // MARK: - 健壮性

    func testCorruptFileIsBackedUpInsteadOfCrashing() throws {
        try Data("{ 这不是 JSON".utf8).write(to: fileURL)

        let store = makeStore()

        XCTAssertTrue(store.state.books.isEmpty, "损坏时应回退到空状态")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt") }
        XCTAssertEqual(backups.count, 1, "坏文件应被备份而不是删除")
    }

    func testWriteIsAtomicAndLeavesNoTempFiles() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        for _ in 0..<5 { _ = store.createConversation(assetID: "A1") }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".tmp") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "临时文件应被 replaceItemAt 消费掉，不应残留")
    }

    func testMessagesRoundTrip() {
        let store = makeStore()
        store.addBook(assetID: "A1", title: "书", author: "")
        let conversation = store.createConversation(assetID: "A1")!

        store.appendMessage(
            assetID: "A1",
            conversationID: conversation.id,
            message: .init(role: .user, text: "这句话什么意思？")
        )

        let reloaded = makeStore()
        let messages = reloaded.conversation(assetID: "A1", conversationID: conversation.id)?.messages
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?.text, "这句话什么意思？")
        XCTAssertEqual(messages?.first?.role, .user)
    }
}
