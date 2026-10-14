import XCTest
import BooksBridgeCore
import BooksBridgeLLM
@testable import BooksBridgeApp

@MainActor
final class ReadingAssistantTests: XCTestCase {
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
