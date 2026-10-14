import XCTest
import BooksBridgeCore
import BooksBridgeLLM
@testable import BooksBridgeApp

@MainActor
final class ReadingAssistantTests: XCTestCase {
    private actor SummaryGate {
        var started = false
        var resume: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            await withCheckedContinuation { resume = $0 }
        }
        func release() { resume?.resume(); resume = nil }
    }

    func testSummarySurvivesObserverCancellationAndOtherBookNavigation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache")
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "test", knowledgeDirectory: directory)
        let gate = SummaryGate()
        assistant.processOverride = { book, epub, progress in
            progress(.started(chunkCount: 4))
            await gate.wait()
            try Task.checkCancellation()
            return BookKnowledge(readme: "完成的摘要", contentHash: BookPreprocessor.contentHash(of: BookPreprocessor.extractChapters(epub: epub)),
                model: "test", characterCount: 800, chapterCount: 2, chunkCount: 4, promptTokens: 0, completionTokens: 0)
        }
        let stream = assistant.open(book: book(root), currentCFI: nil, forceReprocess: true)
        let observer = Task { for await _ in stream {} }
        for _ in 0..<200 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await gate.started
        XCTAssertTrue(started)
        observer.cancel()
        assistant.cancelAnswer()
        for await _ in assistant.open(book: book(root, id: "B"), currentCFI: nil) {}
        if case .processing = assistant.preparationState(assetID: "A") {} else { XCTFail("切换页面不能取消摘要") }
        let restarted = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: directory)
        if case .failed(let reason) = restarted.preparationState(assetID: "A") {
            XCTAssertTrue(reason.contains("中断"))
        } else { XCTFail("重启必须报告未完成任务") }
        // Repeated requests must attach to the existing job instead of paying twice.
        for await _ in assistant.open(book: book(root), currentCFI: nil, forceReprocess: true) {}
        await gate.release()
        for _ in 0..<200 {
            if case .ready = assistant.preparationState(assetID: "A") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if case .ready = assistant.preparationState(assetID: "A") {} else { XCTFail("脱离页面后仍应完成") }
        XCTAssertEqual(assistant.currentBook?.assetID, "B")
        XCTAssertNil(assistant.currentKnowledge, "A 的摘要不能写入 B")
        for await _ in assistant.open(book: book(root), currentCFI: nil) {}
        XCTAssertEqual(assistant.currentKnowledge?.readme, "完成的摘要")
    }

    func testRetryRetrievesOriginalQuestionInsteadOfOnlyRetryWords() {
        XCTAssertTrue(ReadingAssistant.retrievalQuestion("不太对，重试", history: [.user("开头到现在讲了什么"), .assistant("错误回答")]).contains("开头到现在"))
        XCTAssertFalse(ReadingAssistant.retrievalQuestion("重试", history: [.assistant("错误回答")]).contains("错误回答"))
    }
    func testAppCanCancelAnswerBeforeFirstBookOrLaunchSettings() {
        let app = AppDelegate()
        app.cancelPendingAnswer()
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let opf = """
        <package><manifest><item id="c1" href="one.xhtml"/><item id="c2" href="two.xhtml"/></manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """
        try opf.write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        for name in ["one", "two"] {
            try ("<html><body><p>" + String(repeating: name + " 正文内容。", count: 80) + "</p></body></html>")
                .write(to: root.appendingPathComponent(name + ".xhtml"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func book(_ root: URL, id: String = "A", progress: Double = 0.1) -> Book {
        Book(assetID: id, title: "测试书", author: "", progress: progress, contentType: .epub,
             path: root.path, lastOpened: nil)
    }

    func testEachRequestRefreshesChapterAndProgressWithoutOtherBookState() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "")
        try assistant.refreshReading(book: book(root), currentCFI: "epubcfi(/6/2[c1]!/4/2/1:0)", scope: .upToProgress)
        XCTAssertEqual(assistant.currentChapterIndex, 0)
        try assistant.refreshReading(book: book(root, progress: 0.7), currentCFI: "epubcfi(/6/4[c2]!/4/2/1:0)", scope: .upToProgress)
        XCTAssertEqual(assistant.currentChapterIndex, 1)
        XCTAssertEqual(assistant.currentBook?.progress, 0.7)
        XCTAssertThrowsError(try assistant.refreshReading(book: book(root, id: "B"), currentCFI: nil, scope: .currentChapter))
        XCTAssertEqual(assistant.currentBook?.assetID, "B")
        XCTAssertNil(assistant.currentChapterIndex, "不能沿用书 A 的位置")
    }

    func testOpeningBookReusesStableCacheWithoutNetworkRequest() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache")
        let chapters = BookPreprocessor.extractChapters(epub: try EpubDocument(root: root))
        let knowledge = BookKnowledge(readme: "缓存说明", contentHash: BookPreprocessor.contentHash(of: chapters), generatedAt: Date(timeIntervalSince1970: 0),
            model: "test", characterCount: 800, chapterCount: 2, chunkCount: 1, promptTokens: 1, completionTokens: 1)
        await BookKnowledgeStore(directory: directory).save(knowledge, assetID: "A")
        var settings = AppSettings()
        settings.baseURL = "http://127.0.0.1:1/v1"
        let assistant = ReadingAssistant(settings: settings, apiKey: "test", knowledgeDirectory: directory)
        for await _ in assistant.open(book: book(root), currentCFI: nil) {}
        XCTAssertEqual(assistant.currentKnowledge, knowledge)
        if case .ready = assistant.preparation {} else { XCTFail("缓存应直接命中") }
        // 再创建一个助手，模拟重新启动后仍能复用。
        let reopened = ReadingAssistant(settings: settings, apiKey: "test", knowledgeDirectory: directory)
        for await _ in reopened.open(book: book(root), currentCFI: nil) {}
        XCTAssertEqual(reopened.currentKnowledge, knowledge)
    }

    func testOldFingerprintDoesNotAutomaticallyTriggerPaidPreprocessing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache")
        await BookKnowledgeStore(directory: directory).save(BookKnowledge(readme: "旧摘要", contentHash: "legacy-hash",
            model: "test", characterCount: 800, chapterCount: 2, chunkCount: 1, promptTokens: 1, completionTokens: 1), assetID: "A")
        var settings = AppSettings()
        settings.baseURL = "http://127.0.0.1:1/v1"
        let assistant = ReadingAssistant(settings: settings, apiKey: "test", knowledgeDirectory: directory)
        for await _ in assistant.open(book: book(root), currentCFI: nil) {}
        XCTAssertNil(assistant.currentKnowledge)
        XCTAssertEqual(assistant.preparation, .idle)
    }
}
