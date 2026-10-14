import XCTest
import BooksBridgeCore
import BooksBridgeLLM
@testable import BooksBridgeApp

@MainActor
final class ReadingAssistantTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        <package><manifest><item id="c1" href="one.xhtml"/><item id="c2" href="two.xhtml"/></manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """.write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        for name in ["one", "two"] {
            try "<html><body><h1>\(name)标题</h1><p>\(name)这是一段足够定位的独特原文内容。</p><p>之后尚未读到的内容。</p></body></html>"
                .write(to: root.appendingPathComponent(name + ".xhtml"), atomically: true, encoding: .utf8)
        }
        return root
    }
    private func book(_ root: URL, id: String = "A", progress: Double = 0.1) -> Book {
        Book(assetID: id, title: "测试书", author: "", progress: progress, contentType: .epub, path: root.path, lastOpened: nil)
    }
    private func live(_ book: Book) -> ReadingContext {
        .init(book: book, position: nil, visibleText: ["one这是一段足够定位的独特原文内容。"], selection: nil)
    }
    func testAppCanCancelAnswerBeforeFirstBook() { AppDelegate().cancelPendingAnswer() }
    func testRetryUsesQuestionNotPreviousAnswerAsSearchQuery() {
        XCTAssertTrue(ReadingAssistant.retrievalQuestion("重试", history: [.user("开头到现在讲了什么"), .assistant("错误回答")]).contains("开头到现在"))
        XCTAssertFalse(ReadingAssistant.retrievalQuestion("重试", history: [.assistant("错误回答")]).contains("错误回答"))
    }
    func testLocalImportBuildsMapAndReusesOnlyThisConversationPosition() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: root.appendingPathComponent("maps"))
        let first = try await assistant.refresh(book: book(root), live: live(book(root)), previous: nil)
        XCTAssertEqual(first.chapterTitle, "one标题")
        XCTAssertFalse(first.reused)
        let fallback = try await assistant.refresh(book: book(root, progress: 0.99), live: nil, previous: first)
        XCTAssertTrue(fallback.reused); XCTAssertEqual(fallback.progress, 0.1)
        XCTAssertEqual(fallback.page, first.page)
        let other = try await assistant.refresh(book: book(root), live: live(book(root, id: "B")), previous: first)
        XCTAssertEqual(other.page, first.page)
        let invalidLive = ReadingContext(book: book(root), position: nil, visibleText: ["这段足够长的活跃页面内容完全无法匹配本书"], selection: nil)
        do {
            _ = try await assistant.refresh(book: book(root), live: invalidLive, previous: first)
            XCTFail("有活跃文字但定位失败时，不能静默沿用旧位置")
        } catch {}
        let freshConversation = try await assistant.refresh(book: book(root), live: nil, previous: nil)
        XCTAssertNil(freshConversation.page)
        XCTAssertThrowsError(try assistant.reading(snapshot: freshConversation, scope: .upToProgress))
        XCTAssertEqual(try assistant.reading(snapshot: freshConversation, scope: .wholeBook).chapters.count, 2)
        let mapFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("maps"), includingPropertiesForKeys: nil)
        XCTAssertEqual(mapFiles.count, 1)
        XCTAssertFalse(try String(contentsOf: mapFiles[0], encoding: .utf8).contains("足够定位的独特原文"), "地图不能保存正文副本")
        try "<h1>改过的书</h1><p>内容已经变了</p>".write(to: root.appendingPathComponent("one.xhtml"), atomically: true, encoding: .utf8)
        let changed = try await assistant.refresh(book: book(root), live: nil, previous: first)
        XCTAssertNil(changed.page, "文件变化后旧边界不能复用")
    }
    func testUnreadableSourceFailsInsteadOfSilentlyBuildingIncompleteMap() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("two.xhtml"))
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: root.appendingPathComponent("maps"))
        do { _ = try await assistant.refresh(book: book(root), live: nil, previous: nil); XCTFail("缺失正文应报错") } catch {}
    }
    private actor Gate {
        var started = false
        var resume: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { resume = $0 } }
        func release() { resume?.resume(); resume = nil }
    }
    func testScopedSummaryJobSurvivesNavigationAndStoresOriginalBoundary() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: root.appendingPathComponent("maps"))
        let snapshot = try await assistant.refresh(book: book(root), live: live(book(root)), previous: nil)
        let allowed = try assistant.reading(snapshot: snapshot, scope: .upToProgress)
        let jobs = SummaryJobs(); let gate = Gate()
        var completed: ReadingSummary?
        var updates: [String] = []
        jobs.onUpdate = { assetID, conversation, status, summary in
            XCTAssertEqual(assetID, "A"); XCTAssertEqual(conversation, "C")
            updates.append(status); if let summary { completed = summary }
        }
        jobs.processOverride = { _, chapters, progress in
            XCTAssertFalse(chapters.map(\.text).joined().contains("尚未读到"))
            progress(.started(chunkCount: 2)); await gate.wait()
            try Task.checkCancellation()
            return BookKnowledge(readme: "范围内摘要", contentHash: "test", model: "test", characterCount: 20, chapterCount: 1, chunkCount: 2, promptTokens: 0, completionTokens: 0)
        }
        jobs.start(book: book(root), conversationID: "C", snapshot: snapshot, reading: allowed, scope: .upToProgress, settings: AppSettings(), apiKey: "")
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        assistant.cancelAnswer()
        _ = try await assistant.refresh(book: book(root, id: "B"), live: nil, previous: nil)
        XCTAssertTrue(jobs.isRunning(assetID: "A", conversationID: "C"))
        jobs.start(book: book(root), conversationID: "C", snapshot: snapshot, reading: allowed, scope: .upToProgress, settings: AppSettings(), apiKey: "")
        await gate.release()
        for _ in 0..<200 { if completed != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completed?.boundary, allowed.boundary)
        XCTAssertEqual(completed?.sourceHash, snapshot.sourceHash)
        XCTAssertEqual(updates.filter { $0 == "正在生成范围摘要" }.count, 1)
        XCTAssertEqual(assistant.currentBook?.assetID, "B")
    }

    func testCancelledSummaryCannotPublishLateResult() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: root.appendingPathComponent("maps"))
        let snapshot = try await assistant.refresh(book: book(root), live: live(book(root)), previous: nil)
        let allowed = try assistant.reading(snapshot: snapshot, scope: .upToProgress)
        let jobs = SummaryJobs(); let gate = Gate()
        var statuses: [String] = []
        var completed = false
        jobs.onUpdate = { _, _, status, summary in statuses.append(status); completed = completed || summary != nil }
        jobs.processOverride = { _, _, progress in
            await gate.wait()
            progress(.chunkDone(index: 1, total: 1))
            return BookKnowledge(readme: "晚到的结果", contentHash: "test", model: "test", characterCount: 20, chapterCount: 1, chunkCount: 1, promptTokens: 0, completionTokens: 0)
        }
        jobs.start(book: book(root), conversationID: "C", snapshot: snapshot, reading: allowed, scope: .upToProgress, settings: AppSettings(), apiKey: "")
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        jobs.cancel(assetID: "A", conversationID: "C")
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(jobs.isRunning(assetID: "A", conversationID: "C"))
        XCTAssertFalse(completed)
        XCTAssertEqual(statuses.last, "摘要已取消")
    }
}
