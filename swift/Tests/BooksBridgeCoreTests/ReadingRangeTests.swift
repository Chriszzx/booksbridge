import XCTest
@testable import BooksBridgeCore
@testable import BooksBridgeLLM

final class ReadingRangeTests: XCTestCase {
    private let start = "这是第一章开头的内容，有一段很重要的背景。"
    private let page = "这是当前屏幕上可见的完整正文，足够作为唯一锚点。"
    private let secret = "后面尚未阅读的秘密，绝对不允许进入受限上下文。"
    private func chapters() -> [BookPreprocessor.Chapter] {
        [.init(spineIndex: 1, href: "one", text: start),
         .init(spineIndex: 2, href: "two", text: "本章前面已经读过的情节。\n" + page + "\n" + secret),
         .init(spineIndex: 3, href: "three", text: "最后一章结局。")]
    }
    func testPaginatedWebAreaOutsideWindowStillUsesWindowViewport() {
        let window = CGRect(x: 207, y: 118, width: 1024, height: 768)
        let paginated = CGRect(x: -19537, y: 202, width: 906, height: 564)
        XCTAssertEqual(AccessibilityReader.readingViewport(reader: paginated, window: window), window)
        let ordinary = CGRect(x: 252, y: 190, width: 424, height: 564)
        XCTAssertEqual(AccessibilityReader.readingViewport(reader: ordinary, window: window), ordinary)
    }

    func testProgressIncludesCurrentChapterPrefixButNeverSuffix() throws {
        let reading = try ScopedReading.resolve(chapters: chapters(), current: 0, scope: .upToProgress, visible: [page])
        XCTAssertEqual(reading.currentChapter, 1, "实时页面优先于旧CFI")
        let text = reading.chapters.map(\.text).joined()
        XCTAssertTrue(text.contains(start)); XCTAssertTrue(text.contains("本章前面")); XCTAssertTrue(text.contains(page))
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("结局"))
        let tools = ReadingTools(reading: reading)
        XCTAssertFalse(tools.search("秘密").contains(secret))
        XCTAssertFalse(tools.read(chapter: 1, offset: 0, length: 99999).contains(secret))
        XCTAssertEqual(tools.read(chapter: 2, offset: 0, length: 100), "读取请求超出允许范围")
    }
    func testScopesAreNestedAndRequireNoSummary() throws {
        let progress = try ScopedReading.resolve(chapters: chapters(), current: 1, scope: .upToProgress, visible: [page])
        let chapter = try ScopedReading.resolve(chapters: chapters(), current: 1, scope: .currentChapter, visible: [page])
        let whole = try ScopedReading.resolve(chapters: chapters(), current: nil, scope: .wholeBook, visible: [])
        XCTAssertLessThan(progress.boundary, chapter.boundary); XCTAssertLessThan(chapter.boundary, whole.boundary)
        XCTAssertTrue(chapter.chapters.last!.text.contains(secret)); XCTAssertEqual(whole.chapters.count, 3)
    }
    func testMissingOrAmbiguousPageFailsClosed() {
        XCTAssertThrowsError(try ScopedReading.resolve(chapters: chapters(), current: 1, scope: .upToProgress, visible: []))
        let repeated = [BookPreprocessor.Chapter(spineIndex: 1, href: "x", text: page + page)]
        XCTAssertThrowsError(try ScopedReading.resolve(chapters: repeated, current: 0, scope: .upToProgress, visible: [page]))
    }
    func testPageAcrossChapterBoundary() throws {
        let result = try ScopedReading.resolve(chapters: chapters(), current: 0, scope: .upToProgress, visible: [start, page])
        XCTAssertEqual(result.currentChapter, 1); XCTAssertFalse(result.chapters.last!.text.contains(secret))
    }
    func testWhitespaceAndUnicodeNormalization() {
        XCTAssertNotNil(ScopedReading.pageEnd(in: "序言\n" + page + secret, visible: [page.replacingOccurrences(of: "正文", with: "正 文")]))
    }
    func testHistoryBudgetAndRollbackBoundaries() {
        let messages: [ChatMessage] = [.user("old"), .assistant(String(repeating: "a", count: 100)), .user("new"), .assistant("answer")]
        let trimmed = PromptBuilder.trimHistory(messages, characters: 20)
        XCTAssertEqual(trimmed, Array(messages.suffix(2)))
        XCTAssertLessThan(ReadingBoundary(chapter: 1, end: 100), ReadingBoundary(chapter: 1, end: 200))
    }
    func testToolPlannerRespectsSmallRequestBudget() {
        let messages = PromptBuilder.retrievalMessages(instruction: String(repeating: "规则", count: 500),
            question: String(repeating: "问题", count: 800), material: String(repeating: "原文", count: 5000), budget: 4000)
        XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.count }, 4000)
    }
    func testActiveBookMatchingRejectsStalePreferenceAndAmbiguousTitles() {
        func book(_ id: String, _ title: String) -> Book { .init(assetID: id, title: title, author: "", progress: 0, contentType: .epub, path: nil, lastOpened: nil) }
        let books = [book("A", "旧书"), book("B", "新书")]
        XCTAssertEqual(ReadingCoordinator.matchActiveBook(title: "新书", books: books)?.assetID, "B")
        XCTAssertNil(ReadingCoordinator.matchActiveBook(title: "书库", books: books))
        XCTAssertNil(ReadingCoordinator.matchActiveBook(title: "新书", books: books + [book("C", "新书")]))
    }
}
