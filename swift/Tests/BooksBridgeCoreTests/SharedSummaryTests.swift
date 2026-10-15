import XCTest
import BooksBridgeCore
@testable import BooksBridgeLLM
@testable import BooksBridgeApp

@MainActor
final class SharedSummaryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, Book, ReadingAssistant, ConversationStore, ReadingSnapshot) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("read-only-source"), app = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "<package><manifest><item id='a' href='a.xhtml'/><item id='b' href='b.xhtml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>".write(to: source.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<h1>第一章</h1><p>甲的故事发生在第一章。</p>".write(to: source.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        try "<h1>第二章</h1><p>乙的故事在当前页面已经发生。</p><p>后面的未读秘密。</p>".write(to: source.appendingPathComponent("b.xhtml"), atomically: true, encoding: .utf8)
        let book = Book(assetID: "source-A", title: "测试书", author: "", progress: 0.6, contentType: .epub, path: source.path, lastOpened: nil)
        let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: app.appendingPathComponent("maps"))
        let store = ConversationStore(fileURL: app.appendingPathComponent("store.json"))
        store.addBook(assetID: book.assetID, title: book.title, author: "")
        let snapshot = ReadingSnapshot(assetID: book.assetID, sourceHash: "", page: nil, chapterTitle: "", progress: 0)
        return (root, source, book, assistant, store, snapshot)
    }
    private func load(_ book: Book, _ assistant: ReadingAssistant, _ store: ConversationStore) async throws -> ReadingSnapshot {
        let live = ReadingContext(book: book, position: nil, visibleText: ["乙的故事在当前页面已经发生。"], selection: nil)
        let snapshot = try await assistant.refresh(book: book, live: live, previous: nil)
        XCTAssertTrue(store.updateStatistics(assetID: book.assetID, statistics: try XCTUnwrap(assistant.currentStatistics)))
        return snapshot
    }
    private actor Recorder {
        var inputs: [(String,String)] = []
        var holdAt: Int?
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func setHold(_ index: Int?) { holdAt = index }
        func process(_ source: String, _ title: String) async -> String {
            inputs.append((source,title))
            if inputs.count == holdAt { waiting = true; await withCheckedContinuation { continuation = $0 } }
            return "摘要：" + title
        }
        func release() { continuation?.resume(); continuation = nil; waiting = false }
    }
    private func finish(_ jobs: SummaryJobs, _ id: String) async throws {
        for _ in 0..<300 { if !jobs.isRunning(assetID: id) { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("模拟任务应已完成")
    }
    func testSummaryResumeRequiresSameProviderAndModelConfiguration() async throws {
        let (root, _, book, reader, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await load(book, reader, store)
        let catalog = ModelCatalogStore(directory: root.appendingPathComponent("models"))
        let provider = try catalog.saveService(id: nil, name: "Local", baseURL: "http://localhost:1234/v1", enabled: true, requiresKey: false)
        var model = ServiceModel(name: "Summary", remoteID: "summary")
        try catalog.saveModel(serviceID: provider, model: model)
        let connection = try catalog.resolve(model.id)
        XCTAssertTrue(connection.canResumeSummary(of: try XCTUnwrap(store.book(assetID: book.assetID))))
        var study = try XCTUnwrap(store.book(assetID: book.assetID)?.study)
        study.chapters.append(ChapterDigest(section: study.statistics.sections[0], text: "Saved chapter", model: model.remoteID))
        XCTAssertTrue(store.saveStudy(assetID: book.assetID, study: study))
        XCTAssertFalse(connection.canResumeSummary(of: try XCTUnwrap(store.book(assetID: book.assetID))), "Unattributed legacy chapters require regeneration")
        XCTAssertTrue(store.setSummaryModel(assetID: book.assetID, modelID: model.id, stamp: connection.stamp))
        XCTAssertTrue(connection.canResumeSummary(of: try XCTUnwrap(store.book(assetID: book.assetID))))
        model.remoteID = "different-model"; try catalog.saveModel(serviceID: provider, model: model)
        let changed = try catalog.resolve(model.id)
        XCTAssertFalse(changed.canResumeSummary(of: try XCTUnwrap(store.book(assetID: book.assetID))))
        XCTAssertEqual(store.book(assetID: book.assetID)?.study?.chapters.first?.text, "Saved chapter", "Selecting another model must preserve existing summaries")
        XCTAssertTrue(store.clearStudy(assetID: book.assetID))
        XCTAssertTrue(changed.canResumeSummary(of: try XCTUnwrap(store.book(assetID: book.assetID))))
    }

    func testWholeBookPreparationNeedsNoPageAndNeverLocksConversationScope() async throws {
        let (root, _, book, _, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let free = try XCTUnwrap(store.createConversation(assetID: book.assetID))
        let limited = try XCTUnwrap(store.createConversation(assetID: book.assetID))
        _ = store.lockScope(assetID: book.assetID, conversationID: limited.id, requested: .upToProgress)
        let jobs = SummaryJobs(), recorder = Recorder(); await recorder.setHold(1)
        jobs.processOverride = { text,title in await recorder.process(text,title) }
        jobs.startWholeBook(assetID: book.assetID, settings: AppSettings(), apiKey: "", store: store) { book }
        for _ in 0..<200 { if await recorder.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        store.setActive(assetID: book.assetID, conversationID: free.id)
        XCTAssertTrue(jobs.isRunning(assetID: book.assetID))
        await recorder.release(); try await finish(jobs, book.assetID)
        XCTAssertNotNil(store.book(assetID: book.assetID)?.study?.whole)
        XCTAssertNil(store.conversation(assetID: book.assetID, conversationID: free.id)?.scope)
        XCTAssertNil(store.conversation(assetID: book.assetID, conversationID: free.id)?.readingSnapshot)
        XCTAssertEqual(store.conversation(assetID: book.assetID, conversationID: limited.id)?.scope, .upToProgress)
        XCTAssertTrue(store.conversation(assetID: book.assetID, conversationID: limited.id)!.messages.isEmpty)
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 3)
        XCTAssertTrue(inputs[1].0.contains("未读秘密"), "Explicit whole-book job is independent of the active chat's restricted scope")
    }

    func testCancellingPreparationPreventsLateModelCallsAndWrites() async throws {
        let (root, _, book, _, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let jobs = SummaryJobs(), recorder = Recorder(); await recorder.setHold(1)
        jobs.processOverride = { text,title in await recorder.process(text,title) }
        jobs.startWholeBook(assetID: book.assetID, settings: AppSettings(), apiKey: "", store: store) {
            _ = await recorder.process("load", "gate")
            return book
        }
        for _ in 0..<200 { if await recorder.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        jobs.cancel(assetID: book.assetID, store: store)
        await recorder.release(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(jobs.isRunning(assetID: book.assetID))
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertNil(store.book(assetID: book.assetID)?.study)
    }

    func testBookSharedJobPersistsAcrossNavigationArchiveDeletionAndRestartWithoutTouchingSource() async throws {
        let (root, source, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try BookSourceIdentity.read(at: source)
        for name in ["content.opf", "a.xhtml", "b.xhtml"] { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.appendingPathComponent(name).path) }
        let snapshot = try await load(book, assistant, store)
        let a = try XCTUnwrap(store.createConversation(assetID: book.assetID)), b = try XCTUnwrap(store.createConversation(assetID: book.assetID))
        let jobs = SummaryJobs(), recorder = Recorder(); await recorder.setHold(1)
        jobs.processOverride = { source,title in await recorder.process(source,title) }
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        for _ in 0..<200 { if await recorder.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        store.setActive(assetID: book.assetID, conversationID: b.id)
        store.setArchived(assetID: book.assetID, conversationID: a.id, archived: true)
        store.deleteConversation(assetID: book.assetID, conversationID: a.id)
        XCTAssertTrue(jobs.isRunning(assetID: book.assetID))
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        await recorder.release(); try await finish(jobs, book.assetID)
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 3)
        XCTAssertFalse(inputs[0].0.contains("未读秘密")); XCTAssertFalse(inputs[1].0.contains("甲的故事"))
        XCTAssertTrue(inputs[2].0.contains("摘要：本章：第一章")); XCTAssertFalse(inputs[2].0.contains("甲的故事发生"))
        let study = try XCTUnwrap(store.book(assetID: book.assetID)?.study)
        XCTAssertEqual(study.completedCount, 2); XCTAssertNotNil(study.whole)
        let reloaded = ConversationStore(fileURL: root.appendingPathComponent("app/store.json"))
        let restored = try XCTUnwrap(reloaded.book(assetID: book.assetID)?.study)
        XCTAssertEqual(restored.statistics, study.statistics); XCTAssertEqual(restored.status, study.status)
        XCTAssertEqual(restored.chapters.map(\.text), study.chapters.map(\.text))
        XCTAssertEqual(restored.whole?.text, study.whole?.text)
        XCTAssertEqual(restored.chapters[0].generatedAt.timeIntervalSince1970, study.chapters[0].generatedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(reloaded.book(assetID: book.assetID)?.libraryID, store.book(assetID: book.assetID)?.libraryID)
        XCTAssertEqual(try BookSourceIdentity.read(at: source).fingerprint, before.fingerprint)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted(), ["a.xhtml", "b.xhtml", "content.opf"])
    }
    func testPermissionsUseEarlierChapterSummariesAndOnlyCurrentReadSource() async throws {
        let (root, _, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await load(book, assistant, store)
        var study = try XCTUnwrap(store.book(assetID: book.assetID)?.study)
        XCTAssertEqual(study.statistics.sections.count, 2)
        XCTAssertEqual(study.statistics.documentCount, 2)
        XCTAssertEqual(study.statistics.characterCount, assistant.currentChapters.reduce(0) { $0 + $1.text.count })
        study.chapters = study.statistics.sections.map { ChapterDigest(section: $0, text: $0.title == "第一章" ? "以前的摘要" : "未读秘密摘要", model: "fake") }
        study.whole = ReadingSummary(text: "全书秘密", sourceHash: snapshot.sourceHash, boundary: study.statistics.sections.last!.end, scope: .wholeBook)
        let up = study.readingMaterial(snapshot: snapshot, scope: .upToProgress, source: assistant.currentChapters)
        XCTAssertTrue(up.contains("以前的摘要")); XCTAssertTrue(up.contains("乙的故事在当前页面已经发生"))
        XCTAssertFalse(up.contains("未读秘密")); XCTAssertFalse(up.contains("全书秘密")); XCTAssertFalse(up.contains("甲的故事发生"))
        let chapter = study.readingMaterial(snapshot: snapshot, scope: .currentChapter, source: assistant.currentChapters)
        XCTAssertTrue(chapter.contains("以前的摘要")); XCTAssertTrue(chapter.contains("未读秘密摘要")); XCTAssertFalse(chapter.contains("全书秘密"))
        XCTAssertTrue(study.readingMaterial(snapshot: snapshot, scope: .wholeBook, source: assistant.currentChapters).contains("全书秘密"))
        XCTAssertFalse(study.summary(snapshot: snapshot, scope: .upToProgress)!.text.contains("未读秘密"))
        let jobs = SummaryJobs(), recorder = Recorder()
        jobs.processOverride = { source,title in await recorder.process(source,title) }
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .upToProgress, settings: AppSettings(), apiKey: "", store: store)
        try await finish(jobs, book.assetID)
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 1); XCTAssertFalse(inputs[0].0.contains("乙的故事"))
        XCTAssertNil(store.book(assetID: book.assetID)?.study?.whole)
    }
    func testCancelledJobKeepsCompletedChaptersAndResumesWithoutDuplicateRequests() async throws {
        let (root, _, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await load(book, assistant, store)
        let jobs = SummaryJobs(), recorder = Recorder(); await recorder.setHold(2)
        jobs.processOverride = { source,title in await recorder.process(source,title) }
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        for _ in 0..<200 { if await recorder.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.book(assetID: book.assetID)?.study?.completedCount, 1)
        jobs.cancel(assetID: book.assetID, store: store)
        await recorder.release(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.book(assetID: book.assetID)?.study?.completedCount, 1)
        XCTAssertNil(store.book(assetID: book.assetID)?.study?.whole)
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        try await finish(jobs, book.assetID)
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.filter { $0.1 == "本章：第一章" }.count, 1)
        XCTAssertEqual(store.book(assetID: book.assetID)?.study?.completedCount, 2)
        XCTAssertNotNil(store.book(assetID: book.assetID)?.study?.whole)
    }
    func testDeletedBookCannotBeResurrectedByLateSummaryEvenAfterReimport() async throws {
        let (root, source, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await load(book, assistant, store)
        let oldID = store.book(assetID: book.assetID)?.libraryID
        let jobs = SummaryJobs(), recorder = Recorder(); await recorder.setHold(1)
        jobs.processOverride = { source,title in await recorder.process(source,title) }
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        for _ in 0..<200 { if await recorder.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        jobs.cancel(assetID: book.assetID, store: store); assistant.forgetBook(assetID: book.assetID)
        try BookDataRemoval(directory: root.appendingPathComponent("app")).removeBook(assetID: book.assetID, store: store)
        store.addBook(assetID: book.assetID, title: book.title, author: "")
        XCTAssertNotEqual(oldID, store.book(assetID: book.assetID)?.libraryID)
        await recorder.release(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.book(assetID: book.assetID)?.study)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.xhtml").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("app/maps").path).isEmpty)
    }
    func testChangedSourceRetainsOnlyUnchangedChapterAndInvalidatesWholeSummary() async throws {
        let (root, source, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await load(book, assistant, store)
        var study = try XCTUnwrap(store.book(assetID: book.assetID)?.study)
        study.chapters = study.statistics.sections.map { ChapterDigest(section: $0, text: "旧摘要", model: "fake") }
        study.whole = ReadingSummary(text: "旧全书", sourceHash: snapshot.sourceHash, boundary: study.statistics.sections.last!.end, scope: .wholeBook)
        store.saveStudy(assetID: book.assetID, study: study)
        try "<h1>第二章</h1><p>改过的故事。</p>".write(to: source.appendingPathComponent("b.xhtml"), atomically: true, encoding: .utf8)
        _ = try await assistant.refresh(book: book, live: nil, previous: snapshot)
        store.updateStatistics(assetID: book.assetID, statistics: assistant.currentStatistics!)
        let updated = store.book(assetID: book.assetID)!.study!
        XCTAssertEqual(updated.completedCount, 1); XCTAssertNil(updated.whole)
        XCTAssertNil(updated.summary(snapshot: snapshot, scope: .wholeBook))
    }
    func testRestartMarksInterruptedAndMigratesLegacyWholeOnlyForMatchingSource() async throws {
        let (root, _, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await assistant.refresh(book: book, live: nil, previous: nil)
        let conversation = try XCTUnwrap(store.createConversation(assetID: book.assetID))
        store.updateConversation(assetID: book.assetID, conversationID: conversation.id) {
            $0.summary = ReadingSummary(text: "旧版全书摘要", sourceHash: snapshot.sourceHash, boundary: .init(chapter: 1, end: Int.max), scope: .wholeBook)
        }
        store.updateStatistics(assetID: book.assetID, statistics: assistant.currentStatistics!)
        XCTAssertEqual(store.book(assetID: book.assetID)?.study?.whole?.text, "旧版全书摘要")
        var study = store.book(assetID: book.assetID)!.study!
        study.chapters = [ChapterDigest(section: study.statistics.sections[0], text: "已保存第一章", model: "fake")]
        study.status = "正在生成第 2 章"
        store.saveStudy(assetID: book.assetID, study: study)
        let reloaded = ConversationStore(fileURL: root.appendingPathComponent("app/store.json"))
        XCTAssertEqual(reloaded.book(assetID: book.assetID)?.study?.completedCount, 1)
        XCTAssertTrue(reloaded.book(assetID: book.assetID)?.study?.status.contains("已中断") == true)
        reloaded.clearStudy(assetID: book.assetID)
        reloaded.updateStatistics(assetID: book.assetID, statistics: assistant.currentStatistics!)
        XCTAssertNil(reloaded.book(assetID: book.assetID)?.study?.whole, "清除后不能重新迁移旧摘要")
        XCTAssertEqual(reloaded.book(assetID: book.assetID)?.study?.completedCount, 0)
    }

    func testSummaryWriteFailureStopsBeforeAnotherModelRequest() async throws {
        let (root, _, book, assistant, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await load(book, assistant, store)
        let jobs = SummaryJobs(), recorder = Recorder(); await recorder.setHold(1)
        jobs.processOverride = { text,title in await recorder.process(text,title) }
        jobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        for _ in 0..<200 { if await recorder.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        let app = root.appendingPathComponent("app")
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("saved-app"))
        try Data("blocker".utf8).write(to: app)
        await recorder.release(); try await finish(jobs, book.assetID)
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(store.book(assetID: book.assetID)?.study?.completedCount, 0)
        XCTAssertNotNil(store.lastWriteError)
        XCTAssertTrue(jobs.failureStatus(assetID: book.assetID)?.contains("保存失败") == true)
    }

}

final class ChapterSummarizerTests: XCTestCase {
    private actor Calls { var count = 0; func add() { count += 1 } }
    func testTruncatedCompletionCannotBecomeFinishedSummary() throws {
        let truncated = Data(#"{"choices":[{"message":{"content":"半截摘要"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertThrowsError(try ChatClient.decodeCompletion(truncated, requireComplete: true))
        let complete = Data(#"{"choices":[{"message":{"content":"完整摘要"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try ChatClient.decodeCompletion(complete, requireComplete: true).text, "完整摘要")
    }
    func testOversizedParagraphAndReductionRequestsRespectBothBudgets() async throws {
        let calls = Calls()
        let source = String(repeating: "中文段落👩🏽‍💻", count: 1600)
        let summarizer = ChapterSummarizer(characterBudget: 4000, contextTokens: 4096) { messages, output in
            XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.count }, 4000)
            XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.utf8.count } + output + 256, 4096)
            await calls.add(); return "压缩后的事实摘要"
        }
        let result = try await summarizer.summarize(source, title: "长章")
        XCTAssertFalse(result.isEmpty)
        let count = await calls.count; XCTAssertGreaterThan(count, 2)
        let parts = ChapterSummarizer.split(source, limit: 600)
        XCTAssertEqual(parts.joined(), source)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 600 })
    }
}
