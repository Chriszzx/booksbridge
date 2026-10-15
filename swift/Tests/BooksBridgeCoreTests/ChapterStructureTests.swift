import XCTest
import BooksBridgeCore
@testable import BooksBridgeLLM
@testable import BooksBridgeApp

@MainActor
final class ChapterStructureTests: XCTestCase {
    private func fixture(_ html: [String] = ["<p>第一卷</p><p>第一章</p><p>甲的故事。</p><p>第二章</p><p>乙的故事与未来秘密。</p>"]) throws -> (URL, Book, ReadingAssistant, ConversationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), app = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = html.indices.map { "<item id='a\($0)' href='a\($0).xhtml'/>" }.joined()
        let spine = html.indices.map { "<itemref idref='a\($0)'/>" }.joined()
        try "<package><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>".write(to: source.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        for (index,text) in html.enumerated() { try text.write(to: source.appendingPathComponent("a\(index).xhtml"), atomically: true, encoding: .utf8) }
        let book = Book(assetID: "A", title: "结构测试", author: "", progress: 0, contentType: .epub, path: source.path, lastOpened: nil)
        let loader = ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: app.appendingPathComponent("maps"))
        let store = ConversationStore(fileURL: app.appendingPathComponent("store.json"))
        store.addBook(assetID: "A", title: book.title, author: "")
        return (root, book, loader, store)
    }
    private func load(_ book: Book, _ loader: ReadingAssistant, _ store: ConversationStore) async throws {
        _ = try await loader.refresh(book: book, live: nil, previous: nil)
        XCTAssertTrue(store.updateStatistics(assetID: "A", statistics: try XCTUnwrap(loader.currentStatistics)))
    }
    nonisolated private static func mock(_ messages: [ChatMessage], _ output: Int) throws -> String {
        struct Input: Decodable { let candidates: [ChapterStructure.Candidate]; let previous: ChapterStructure.Decision? }
        let input = try JSONDecoder().decode(Input.self, from: Data(messages.last!.content.utf8))
        let decisions = input.candidates.map { candidate in
            if input.previous?.anchorID == candidate.id { return input.previous! }
            let kind = candidate.title.contains("卷") ? "volume" : candidate.title.hasPrefix("文档") ? "unknown" : "chapter"
            return ChapterStructure.Decision(anchorID: candidate.id, kind: kind, startsSection: true, confidence: kind == "unknown" ? 0.4 : 0.9)
        }
        return String(decoding: try JSONEncoder().encode(decisions), as: UTF8.self)
    }
    private func proposal(_ loader: ReadingAssistant, _ base: BookStatistics) async throws -> ChapterStructure {
        let candidates = ChapterStructure.candidates(map: try XCTUnwrap(loader.currentMap), chapters: loader.currentChapters)
        return try await ChapterClassifier(contextTokens: 8192, characterBudget: 5000, completion: Self.mock)
            .classify(candidates: candidates, chapters: loader.currentChapters, base: base, model: "offline")
    }
    private func finish(_ jobs: StructureJobs) async throws {
        for _ in 0..<400 { if !jobs.isRunning("A") { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("offline job timed out")
    }
    func testMissingTOCMarkersBecomeAnchoredVolumeAndChaptersAndPermissionUsesOverlay() async throws {
        let (root, book, loader, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        let local = try XCTUnwrap(loader.currentStatistics)
        XCTAssertEqual(local.sections.count, 1)
        let proposal = try await proposal(loader, local)
        XCTAssertEqual(proposal.statistics.chapterCount, 2)
        XCTAssertEqual(proposal.nodes.map(\.kind), ["volume", "chapter", "chapter"])
        XCTAssertEqual(proposal.nodes[1].parentID, proposal.nodes[0].anchorID)
        XCTAssertEqual(proposal.statistics.sections.first?.start, local.sections.first?.start)
        XCTAssertEqual(proposal.statistics.sections.last?.end, local.sections.last?.end)
        let first = proposal.statistics.sections[1]
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: local.sourceHash, page: .init(chapter: 0, end: first.end.end - 2), chapterTitle: first.title, progress: 0.4)
        let before = try loader.reading(snapshot: snapshot, scope: .currentChapter)
        XCTAssertTrue(before.chapters.map(\.text).joined().contains("未来秘密"))
        loader.useStatistics(proposal.statistics)
        let after = try loader.reading(snapshot: snapshot, scope: .currentChapter)
        XCTAssertEqual(after.boundary, first.end)
        XCTAssertFalse(after.chapters.map(\.text).joined().contains("未来秘密"))
        let up = try loader.reading(snapshot: snapshot, scope: .upToProgress)
        XCTAssertEqual(up.boundary, snapshot.page)
    }
    func testSharedProposalApplyRestartRestoreAndClearPreservesStructure() async throws {
        let (root, book, loader, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: book.path!), before = try BookSourceIdentity.read(at: source)
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        try await load(book, loader, store)
        let a = try XCTUnwrap(store.createConversation(assetID: "A")), b = try XCTUnwrap(store.createConversation(assetID: "A"))
        let jobs = StructureJobs(); jobs.completionOverride = Self.mock
        jobs.start(book: book, settings: AppSettings(), apiKey: "", store: store, mapDirectory: root.appendingPathComponent("app/maps"))
        store.setActive(assetID: "A", conversationID: b.id); store.setArchived(assetID: "A", conversationID: a.id, archived: true)
        try await finish(jobs)
        var study = try XCTUnwrap(store.book(assetID: "A")?.study)
        let proposed = try XCTUnwrap(study.proposedStructure), original = study.statistics
        let pendingReload = ConversationStore(fileURL: root.appendingPathComponent("app/store.json"))
        XCTAssertEqual(pendingReload.book(assetID: "A")?.study?.proposedStructure?.id, proposed.id)
        XCTAssertFalse(store.structurePermissionRequired(assetID: "A", conversationID: b.id, scope: .currentChapter))
        XCTAssertEqual(original.sections.count, 1) // analysis itself never applies
        XCTAssertTrue(study.applyStructure(proposed)); XCTAssertTrue(store.saveStudy(assetID: "A", study: study))
        XCTAssertTrue(store.structurePermissionRequired(assetID: "A", conversationID: b.id, scope: .currentChapter))
        XCTAssertFalse(store.structurePermissionRequired(assetID: "A", conversationID: b.id, scope: .upToProgress))
        XCTAssertFalse(store.confirmStructure(assetID: "A", conversationID: b.id, version: "stale"))
        XCTAssertTrue(store.confirmStructure(assetID: "A", conversationID: b.id, version: study.statistics.structureVersion))
        XCTAssertFalse(store.structurePermissionRequired(assetID: "A", conversationID: b.id, scope: .currentChapter))
        XCTAssertTrue(store.structurePermissionRequired(assetID: "A", conversationID: a.id, scope: .currentChapter))
        XCTAssertTrue(store.updateStatistics(assetID: "A", statistics: original))
        XCTAssertEqual(store.book(assetID: "A")?.study?.statistics, proposed.statistics)
        XCTAssertTrue(store.clearStudy(assetID: "A"))
        let restored = ConversationStore(fileURL: root.appendingPathComponent("app/store.json"))
        var saved = try XCTUnwrap(restored.book(assetID: "A")?.study)
        XCTAssertEqual(saved.statistics, proposed.statistics); XCTAssertNotNil(saved.appliedStructure)
        saved.restoreLocalStructure(); XCTAssertEqual(saved.statistics, original)
        XCTAssertTrue(restored.saveStudy(assetID: "A", study: saved))
        XCTAssertTrue(restored.structurePermissionRequired(assetID: "A", conversationID: b.id, scope: .currentChapter))
        XCTAssertEqual(try BookSourceIdentity.read(at: source), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 2)
    }
    func testMalformedUnknownDuplicateOutOfOrderResponsesAreRejected() async throws {
        let (root, book, loader, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        let candidates = ChapterStructure.candidates(map: loader.currentMap!, chapters: loader.currentChapters)
        for output in ["not json", "[]", "[{\"anchorID\":\"invented\",\"kind\":\"chapter\",\"startsSection\":true,\"confidence\":1}]"] {
            let classifier = ChapterClassifier(contextTokens: 8192, characterBudget: 5000) { _,_ in output }
            do { _ = try await classifier.classify(candidates: candidates, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake"); XCTFail("invalid output accepted") } catch {}
        }
        let good = candidates.map { ChapterStructure.Decision(anchorID: $0.id, kind: "chapter", startsSection: true, confidence: 0.9) }
        for bad in [Array(good.reversed()), Array(repeating: good[0], count: good.count), good.map { .init(anchorID: $0.anchorID, kind: "invented", startsSection: true, confidence: 0.9) }, good.map { .init(anchorID: $0.anchorID, kind: "chapter", startsSection: true, confidence: 2) }] {
            XCTAssertThrowsError(try ChapterStructure.build(candidates: candidates, decisions: bad, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake"))
        }
    }
    func testBatchesRespectBudgetAndRequireOverlapAgreement() async throws {
        let html = (1...22).map { "<h1>第\($0)章</h1><p>" + String(repeating: "正文", count: 100) + "</p>" }.joined()
        let (root, book, loader, store) = try fixture([html]); defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        let candidates = ChapterStructure.candidates(map: loader.currentMap!, chapters: loader.currentChapters)
        let classifier = ChapterClassifier(contextTokens: 4096, characterBudget: 4000) { messages, output in
            XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.utf8.count } + output + 256, 4096)
            XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.count }, 4000)
            return try Self.mock(messages, output)
        }
        let result = try await classifier.classify(candidates: candidates, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake")
        XCTAssertEqual(result.statistics.chapterCount, 22)
        let invalid = ChapterClassifier(contextTokens: 4096, characterBudget: 4000) { messages, output in
            let good = try Self.mock(messages, output)
            if messages.last!.content.contains("\"previous\"") { return good.replacingOccurrences(of: "0.9", with: "0.8") }
            return good
        }
        do { _ = try await invalid.classify(candidates: candidates, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake"); XCTFail("overlap changed") } catch {}
        let insufficient = ChapterClassifier(contextTokens: 100, characterBudget: 100) { _,_ in XCTFail("must not send"); return "[]" }
        do { _ = try await insufficient.classify(candidates: candidates, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake"); XCTFail("budget ignored") } catch {}
    }
    func testUnknownAndLowConfidenceDoNotMergeAndSourceChangeInvalidatesProposal() async throws {
        let (root, book, loader, store) = try fixture(["<p>没有目录的正文。</p>", "<p>另一段没有标题的正文。</p>"])
        defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        let candidates = ChapterStructure.candidates(map: loader.currentMap!, chapters: loader.currentChapters)
        let decisions = candidates.map { ChapterStructure.Decision(anchorID: $0.id, kind: "unknown", startsSection: false, confidence: 0.3) }
        let proposal = try ChapterStructure.build(candidates: candidates, decisions: decisions, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake")
        XCTAssertEqual(proposal.uncertainCount, 2); XCTAssertEqual(proposal.statistics.sections.count, 2)
        var study = BookStudy(statistics: loader.currentStatistics!); study.proposedStructure = proposal
        let changed = BookStatistics(sourceHash: "changed", characterCount: 1, estimatedTokens: 1, documentCount: 1, headingCount: 0, sections: [])
        study.refreshLocal(changed); XCTAssertNil(study.proposedStructure); XCTAssertFalse(study.applyStructure(proposal))
    }
    func testNewStructureInvalidatesWholeAndOnlyChangedIntervals() async throws {
        let (root, book, loader, store) = try fixture(["<h1>第一章</h1><p>甲</p>", "<p>第二章</p><p>乙</p><p>第三章</p><p>丙</p>"])
        defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        var study = BookStudy(statistics: loader.currentStatistics!)
        study.chapters = study.statistics.sections.map { ChapterDigest(section: $0, text: "cached", model: "fake") }
        study.whole = ReadingSummary(text: "old whole", sourceHash: study.statistics.sourceHash, boundary: study.statistics.sections.last!.end, scope: .wholeBook)
        let result = try await proposal(loader, study.statistics)
        XCTAssertTrue(study.applyStructure(result)); XCTAssertNil(study.whole)
        XCTAssertEqual(study.completedCount, 1); XCTAssertEqual(study.chapters.first?.sectionID, result.statistics.sections.first?.id)
    }
    private actor Gate {
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func pause() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testCancellationDeletionAndChangedStructureRejectLateResults() async throws {
        for mode in ["cancel", "delete", "change"] {
            let (root, book, loader, store) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try await load(book, loader, store)
            let jobs = StructureJobs(), gate = Gate()
            jobs.completionOverride = { messages,output in await gate.pause(); return try Self.mock(messages, output) }
            jobs.start(book: book, settings: AppSettings(), apiKey: "", store: store, mapDirectory: root.appendingPathComponent("app/maps"))
            for _ in 0..<300 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
            let waiting = await gate.waiting; XCTAssertTrue(waiting)
            if mode == "cancel" { jobs.cancel("A", store: store) }
            if mode == "delete" {
                store.removeBook(assetID: "A"); store.addBook(assetID: "A", title: "reimported", author: "")
            }
            if mode == "change" {
                var study = store.book(assetID: "A")!.study!
                let proposed = try await proposal(loader, study.statistics)
                XCTAssertTrue(study.applyStructure(proposed)); XCTAssertTrue(store.saveStudy(assetID: "A", study: study))
            }
            await gate.release(); try await finish(jobs)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(store.book(assetID: "A")?.study?.proposedStructure)
        }
    }
    func testSummaryCannotCommitAfterStructureVersionChangesWithoutSourceChange() async throws {
        let (root, book, loader, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        let original = loader.currentStatistics!, gate = Gate(), jobs = SummaryJobs()
        jobs.processOverride = { _,_ in await gate.pause(); return "stale summary" }
        let snapshot = ReadingSnapshot(assetID: "A", sourceHash: original.sourceHash, page: nil, chapterTitle: "", progress: 0)
        jobs.start(book: book, snapshot: snapshot, chapters: loader.currentChapters, scope: .wholeBook, settings: AppSettings(), apiKey: "", store: store)
        for _ in 0..<300 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        var study = store.book(assetID: "A")!.study!
        let proposed = try await proposal(loader, study.statistics)
        XCTAssertTrue(study.applyStructure(proposed)); XCTAssertTrue(store.saveStudy(assetID: "A", study: study))
        await gate.release()
        for _ in 0..<300 { if !jobs.isRunning(assetID: "A") { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.book(assetID: "A")?.study?.statistics.sourceHash, original.sourceHash)
        XCTAssertEqual(store.book(assetID: "A")?.study?.completedCount, 0); XCTAssertNil(store.book(assetID: "A")?.study?.whole)
    }

    func testChapterMayContinueAcrossDocumentsAndRepeatedTitlesKeepDistinctAnchors() async throws {
        let (root, book, loader, store) = try fixture(["<h1>第一章</h1><p>开始。</p>", "<p>同章续文。</p><h1>第一章</h1><p>另一卷的同名章节。</p>"])
        defer { try? FileManager.default.removeItem(at: root) }
        try await load(book, loader, store)
        let candidates = ChapterStructure.candidates(map: loader.currentMap!, chapters: loader.currentChapters)
        XCTAssertEqual(candidates.count, 3); XCTAssertEqual(Set(candidates.map(\.id)).count, 3)
        let decisions = candidates.map { candidate in ChapterStructure.Decision(anchorID: candidate.id,
            kind: "chapter", startsSection: !candidate.title.hasPrefix("文档"), confidence: 0.95) }
        let result = try ChapterStructure.build(candidates: candidates, decisions: decisions, chapters: loader.currentChapters, base: loader.currentStatistics!, model: "fake")
        XCTAssertEqual(result.statistics.chapterCount, 2)
        let first = result.statistics.sections[0]
        XCTAssertEqual(first.end, candidates[2].start)
        let text = BookStatistics.text(chapters: loader.currentChapters, from: first.start, through: first.end)
        XCTAssertTrue(text.contains("同章续文")); XCTAssertFalse(text.contains("另一卷"))
        XCTAssertNotEqual(result.statistics.sections[0].id, result.statistics.sections[1].id)
        var study = BookStudy(statistics: loader.currentStatistics!); study.structureStatus = "正在分析章节 1/3"
        XCTAssertTrue(store.saveStudy(assetID: "A", study: study))
        let restarted = ConversationStore(fileURL: root.appendingPathComponent("app/store.json"))
        XCTAssertEqual(restarted.book(assetID: "A")?.study?.structureStatus, "章节分析已中断，请手动重新分析")
    }

}
