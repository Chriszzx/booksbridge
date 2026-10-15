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

    func testBookMovesPersistWithoutChangingConversationState() throws {
        let store = makeStore()
        for id in ["A", "B", "C"] { store.addBook(assetID: id, title: id, author: "") }
        let c = try XCTUnwrap(store.createConversation(assetID: "B"))
        store.setActive(assetID: "B", conversationID: c.id)
        store.lockScope(assetID: "B", conversationID: c.id, requested: .upToProgress)
        XCTAssertTrue(store.moveBook(assetID: "C", beforeAssetID: "A"))
        XCTAssertEqual(makeStore().state.books.map(\.assetID), ["C", "A", "B"])
        XCTAssertTrue(store.moveBook(assetID: "C", beforeAssetID: nil))
        XCTAssertEqual(makeStore().state.books.map(\.assetID), ["A", "B", "C"])
        XCTAssertFalse(store.moveBook(assetID: "B", beforeAssetID: "missing"))
        XCTAssertFalse(store.moveBook(assetID: "B", beforeAssetID: "B"))
        XCTAssertEqual(makeStore().state.lastActive?.conversationID, c.id)
        XCTAssertEqual(makeStore().conversation(assetID: "B", conversationID: c.id)?.scope, .upToProgress)
    }

    func testArchiveAndRestorePreserveScopeMessagesSnapshotAndRunningSummary() throws {
        let store = makeStore(); store.addBook(assetID: "A", title: "书", author: "")
        let c = try XCTUnwrap(store.createConversation(assetID: "A"))
        let next = try XCTUnwrap(store.createConversation(assetID: "A"))
        store.setActive(assetID: "A", conversationID: c.id)
        store.lockScope(assetID: "A", conversationID: c.id, requested: .currentChapter)
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: "hash", page: .init(chapter: 0, end: 10), chapterTitle: "第一章", progress: 0.2)
        let summary = ReadingSummary(text: "范围摘要", sourceHash: "hash", boundary: .init(chapter: 0, end: 10), scope: .currentChapter)
        store.updateReading(assetID: "A", conversationID: c.id, snapshot: snapshot)
        store.updateConversation(assetID: "A", conversationID: c.id) { $0.summary = summary; $0.summaryStatus = "正在生成摘要 1/3" }
        store.appendMessage(assetID: "A", conversationID: c.id, message: .init(role: .user, text: "问题"))
        XCTAssertTrue(store.setArchived(assetID: "A", conversationID: c.id, archived: true))
        XCTAssertEqual(store.state.lastActive?.conversationID, next.id)
        XCTAssertEqual(store.conversation(assetID: "A", conversationID: c.id)?.summaryStatus, "正在生成摘要 1/3")
        XCTAssertNotNil(makeStore().conversation(assetID: "A", conversationID: c.id)?.archivedAt)
        XCTAssertTrue(store.setArchived(assetID: "A", conversationID: c.id, archived: false))
        let restored = try XCTUnwrap(makeStore().conversation(assetID: "A", conversationID: c.id))
        XCTAssertNil(restored.archivedAt)
        XCTAssertEqual(restored.scope, .currentChapter)
        XCTAssertEqual(restored.messages.first?.text, "问题")
        XCTAssertEqual(restored.readingSnapshot?.page, snapshot.page)
        XCTAssertEqual(restored.summary?.text, summary.text)
        store.setActive(assetID: "A", conversationID: next.id)
        store.setArchived(assetID: "A", conversationID: c.id, archived: true)
        store.setArchived(assetID: "A", conversationID: next.id, archived: true)
        XCTAssertNil(store.state.lastActive?.conversationID)
        XCTAssertEqual(store.book(assetID: "A")?.conversations.count, 2)
        XCTAssertFalse(store.setArchived(assetID: "A", conversationID: "missing", archived: true))
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

extension ConversationStoreTests {
    func testEditDeleteAndRetryPreserveIdentityAndInvalidateDependentContext() throws {
        let store = makeStore(); store.addBook(assetID: "A", title: "书", author: "")
        let c = try XCTUnwrap(store.createConversation(assetID: "A"))
        let boundary = ReadingBoundary(chapter: 0, end: 10)
        for (id,role) in [("q1",Conversation.Message.Role.user),("a1",.assistant),("q2",.user),("a2",.assistant)] {
            store.appendMessage(assetID: "A", conversationID: c.id, message: .init(id: id, role: role, text: id, boundary: boundary, sourceHash: "hash"))
        }
        store.lockScope(assetID: "A", conversationID: c.id, requested: .upToProgress)
        XCTAssertTrue(store.changeMessage(assetID: "A", conversationID: c.id, messageID: "q1", text: "修改"))
        var saved = try XCTUnwrap(makeStore().conversation(assetID: "A", conversationID: c.id))
        XCTAssertEqual(saved.messages.count, 4); XCTAssertEqual(saved.messages[0].text, "修改")
        XCTAssertTrue(saved.messages.allSatisfy { $0.boundary == nil && $0.sourceHash == nil })
        XCTAssertEqual(saved.retryQuestion(for: "a1")?.text, "修改")
        store.saveAnswer(assetID: "A", conversationID: c.id, questionID: "q1", replacing: "a1", answer: .init(role: .assistant, text: "新回答", boundary: boundary, sourceHash: "hash"))
        saved = try XCTUnwrap(makeStore().conversation(assetID: "A", conversationID: c.id))
        XCTAssertEqual(saved.messages.map(\.id), ["q1","a1","q2","a2"])
        XCTAssertEqual(saved.messages[1].text,"新回答"); XCTAssertEqual(saved.messages[0].boundary,boundary)
        XCTAssertNil(saved.messages[2].boundary)
        XCTAssertTrue(store.changeMessage(assetID: "A", conversationID: c.id, messageID: "q2"))
        saved = try XCTUnwrap(makeStore().conversation(assetID: "A", conversationID: c.id))
        XCTAssertNil(saved.retryQuestion(for: "a2"), "Deleted question must not retry a different preceding question")
        XCTAssertEqual(saved.scopeHistoryStartIndex, 3); XCTAssertEqual(saved.scope, .upToProgress)
        XCTAssertFalse(store.changeMessage(assetID: "A", conversationID: c.id, messageID: "a1", text: "不允许修改助手"))
        XCTAssertFalse(store.changeMessage(assetID: "A", conversationID: c.id, messageID: "q1", text: " "))
        store.setArchived(assetID: "A", conversationID: c.id, archived: true)
        XCTAssertFalse(store.changeMessage(assetID: "A", conversationID: c.id, messageID: "q1"))
    }
}
