import XCTest
@testable import BooksBridgeCore
@testable import BooksBridgeLLM
@testable import BooksBridgeApp

final class BookMapTests: XCTestCase {
    func testNCXHierarchyAndRepeatedHeadingTextUseSourcePositions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<package><manifest><item id='a' href='a.xhtml'/><item id='n' href='toc.ncx' media-type='application/x-dtbncx+xml'/></manifest><spine><itemref idref='a'/></spine></package>".write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<ncx><navMap><navPoint><navLabel><text>第一卷</text></navLabel><content src = 'a.xhtml'/><navPoint><navLabel><text>第二节</text></navLabel><content src='a.xhtml#second'/></navPoint></navPoint></navMap></ncx>".write(to: root.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        let before = "第一节正文中提到第二节的名字。这里仍然属于第一节。"
        try "<p>\(before)</p><h2 id = 'second'>第二节</h2><p>未来内容。</p>".write(to: root.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        let epub = try EpubDocument(root: root)
        let navigation = try epub.navigationEntries()
        XCTAssertEqual(navigation.map(\.level), [1, 2])
        let map = try BookMap.build(epub: epub, chapters: BookPreprocessor.extractChapters(epub: epub))
        XCTAssertEqual(map.entries.count, 2, "目录锚点和标题在同一位置，应合并")
        XCTAssertEqual(map.entries[1].start.end, ScopedReading.normalized(before).unicodeScalars.count)
    }

    func testPageListAloneDoesNotBecomeChapterMap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<package><manifest><item id='a' href='a.xhtml'/><item id='n' href='nav.xhtml' properties='nav'/></manifest><spine><itemref idref='a'/></spine></package>".write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<nav epub:type='page-list'><a href='a.xhtml'>第3页</a></nav>".write(to: root.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try "<h1>第一章</h1><p>这是一段正文内容。</p>".write(to: root.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        let epub = try EpubDocument(root: root)
        XCTAssertTrue(try epub.navigationEntries().isEmpty)
        XCTAssertEqual(try BookMap.build(epub: epub, chapters: BookPreprocessor.extractChapters(epub: epub)).entries.first?.title, "第一章")
    }

    func testHeadingsInsideOneDocumentGiveRealBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<package><manifest><item id='one' href='one.xhtml'/><item id='nav' href='nav.xhtml' properties='nav'/></manifest><spine><itemref idref='one'/></spine></package>".write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<nav><a href='one.xhtml'>第一卷</a></nav>".write(to: root.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try "<h1>第一章 开始</h1><p>这是当前页面上足够长的独特定位文字。</p><p>本章剩余内容。</p><h1>第二章 未来</h1><p>未来的秘密。</p>".write(to: root.appendingPathComponent("one.xhtml"), atomically: true, encoding: .utf8)
        let epub = try EpubDocument(root: root)
        let chapters = BookPreprocessor.extractChapters(epub: epub)
        let map = try BookMap.build(epub: epub, chapters: chapters)
        XCTAssertEqual(try epub.navigationTitles()["one.xhtml"], "第一卷")
        let page = try ScopedReading.resolve(chapters: chapters, current: nil, scope: .upToProgress, visible: ["这是当前页面上足够长的独特定位文字。"])
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: map.sourceHash, page: page.boundary, chapterTitle: "第一章 开始", progress: 0.3)
        let throughChapter = try snapshot.reading(chapters: chapters, map: map, scope: .currentChapter)
        XCTAssertTrue(throughChapter.chapters[0].text.contains("本章剩余内容"))
        XCTAssertFalse(throughChapter.chapters[0].text.contains("第二章"))
        XCTAssertFalse(throughChapter.chapters[0].text.contains("未来的秘密"))
        let whole = try snapshot.reading(chapters: chapters, map: map, scope: .wholeBook)
        let summary = ReadingSummary(text: "未来的秘密", sourceHash: map.sourceHash, boundary: whole.boundary, scope: .wholeBook)
        XCTAssertFalse(summary.isAllowed(snapshot: snapshot, reading: throughChapter))
        XCTAssertFalse(summary.isAllowed(snapshot: snapshot, reading: page))
    }
    func testTOCAnchorsSplitOneFileAndPreserveCrossFileChapters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<package><manifest><item id='a' href='a.xhtml'/><item id='b' href='b.xhtml'/><item id='n' href='nav.xhtml' properties='nav'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>".write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<nav epub:type='toc'><ol><li><a href='a.xhtml#start'>真正的第一章</a></li><li><a href='b.xhtml#second'>真正的第二章</a></li></ol></nav><nav epub:type='page-list'><a href='a.xhtml#start'>第3页</a></nav>".write(to: root.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try "<p id='start'>这是第一章开头足够长的页面定位内容。</p>".write(to: root.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        try "<p>第一章跨文件的后半部分。</p><p id='second'>第二章尚未阅读的秘密内容。</p>".write(to: root.appendingPathComponent("b.xhtml"), atomically: true, encoding: .utf8)
        let epub = try EpubDocument(root: root)
        let chapters = BookPreprocessor.extractChapters(epub: epub)
        let map = try BookMap.build(epub: epub, chapters: chapters)
        let boundary = try ScopedReading.resolve(chapters: chapters, current: nil, scope: .upToProgress, visible: ["这是第一章开头足够长的页面定位内容。"]).boundary
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: map.sourceHash, page: boundary, chapterTitle: "真正的第一章", progress: 0.2)
        XCTAssertEqual(map.entry(at: boundary)?.title, "真正的第一章")
        let chapter = try snapshot.reading(chapters: chapters, map: map, scope: .currentChapter)
        XCTAssertTrue(chapter.chapters.map(\.text).joined().contains("跨文件的后半部分"))
        XCTAssertFalse(chapter.chapters.map(\.text).joined().contains("未阅读的秘密"))
        XCTAssertFalse(map.entries.contains { $0.title == "第3页" })
    }

    func testCommandParsingAndQuoteConfirmationCannotExpandRange() throws {
        XCTAssertTrue(ReadingCommand(" /now ").refreshOnlyOrFirst)
        XCTAssertEqual(ReadingCommand("/now\t解释这句话").question, "解释这句话")
        XCTAssertFalse(ReadingCommand("/nowhere").refreshOnlyOrFirst)
        let text = "这是已经阅读过的足够长的唯一定位文字。"
        let source = [BookPreprocessor.Chapter(spineIndex: 1, href: "a", text: text + "后续秘密")]
        let reading = try ScopedReading.resolve(chapters: source, current: nil, scope: .upToProgress, visible: [text])
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: "hash", page: reading.boundary, chapterTitle: "章", progress: 0.2)
        let quote = ConfirmedReference(token: "token", assetID: "A", conversationID: "C", sourceHash: "hash", text: text)
        XCTAssertNil(quote.validated(token: "token", confirmed: false, snapshot: snapshot, conversationID: "C", reading: reading))
        XCTAssertNil(quote.validated(token: "token", confirmed: true, snapshot: snapshot, conversationID: "OTHER", reading: reading))
        XCTAssertEqual(quote.validated(token: "token", confirmed: true, snapshot: snapshot, conversationID: "C", reading: reading), text)
        let future = ConfirmedReference(token: "token", assetID: "A", conversationID: "C", sourceHash: "hash", text: "后续秘密")
        XCTAssertNil(future.validated(token: "token", confirmed: true, snapshot: snapshot, conversationID: "C", reading: reading))
    }

    func testSelectionRangeMustBeValidBeforeCallingItExact() {
        let whole = "整段内容不等于选中的几个字"
        let paragraph = AccessibilityReader.Snapshot(windowTitles: [], visibleText: [], selection: whole, selectionNodeText: whole)
        XCTAssertFalse(paragraph.selectionIsExact)
        XCTAssertEqual(paragraph.preciseSelection, whole)
        let selected = AccessibilityReader.Snapshot(windowTitles: [], visibleText: [], selection: whole, selectionNodeText: whole, selectionRange: NSRange(location: 0, length: 2))
        XCTAssertTrue(selected.selectionIsExact); XCTAssertEqual(selected.preciseSelection, "整段")
    }
    func testConversationSnapshotSummaryAndInterruptedJobPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("store.json")
        let store = ConversationStore(fileURL: file)
        store.addBook(assetID: "A", title: "书", author: "")
        let c = try XCTUnwrap(store.createConversation(assetID: "A"))
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: "hash", page: .init(chapter: 0, end: 20), chapterTitle: "序章", progress: 0.2)
        store.updateReading(assetID: "A", conversationID: c.id, snapshot: snapshot)
        store.updateConversation(assetID: "A", conversationID: c.id) { $0.summaryStatus = "正在生成摘要 1/2" }
        let restored = ConversationStore(fileURL: file)
        XCTAssertEqual(restored.conversation(assetID: "A", conversationID: c.id)?.readingSnapshot?.page, snapshot.page)
        XCTAssertTrue(restored.conversation(assetID: "A", conversationID: c.id)?.summaryStatus?.contains("中断") == true)
    }
}
