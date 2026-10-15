import XCTest
import BooksBridgeCore
@testable import BooksBridgeLLM
@testable import BooksBridgeApp

@MainActor
final class BookPositionTrackerTests: XCTestCase {
    private let anchorA = "这是甲书当前页独一无二的原文定位内容。"
    private let anchorB = "这是乙书当前页完全不同的原文定位内容。"
    private func fixture() throws -> (URL, Book, Book, ConversationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (id, text) in [("A", anchorA), ("B", anchorB)] {
            let source = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "<package><manifest><item id='a' href='a.xhtml'/></manifest><spine><itemref idref='a'/></spine></package>".write(to: source.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
            try "<h1>同名章节</h1><p>\(text)</p><p>后续未读秘密不能进入当前页。</p>".write(to: source.appendingPathComponent("a.xhtml"), atomically: true, encoding: .utf8)
        }
        func book(_ id: String) -> Book { Book(assetID: id, title: "同名书", author: "", progress: 0.05, contentType: .epub, path: root.appendingPathComponent(id).path, lastOpened: nil) }
        return (root, book("A"), book("B"), ConversationStore(fileURL: root.appendingPathComponent("app/store.json")))
    }
    private func context(_ book: Book, _ visible: [String], page: String? = "第12页|第13页", raw: String = "epubcfi(/6/2!/4/2,:1)", at: Date = Date(), updated: Date = Date(timeIntervalSince1970: 1000.125)) -> ReadingContext {
        ReadingContext(book: book, position: ReadingPosition(kind: .epubCFI(raw), raw: raw, updated: updated, selectedText: nil),
                       visibleText: visible, selection: nil, capturedAt: at, pageIdentity: page)
    }
    private func reader(_ root: URL) -> ReadingAssistant { ReadingAssistant(settings: AppSettings(), apiKey: "", knowledgeDirectory: root.appendingPathComponent("app/maps")) }
    func testSwitchBooksThenImportAndCreateMultipleChatsUsesCorrectVerifiedBook() async throws {
        let (root, a, b, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tracker = BookPositionTracker()
        tracker.onVerified = { _ = store.saveVerifiedPosition(assetID: $0.assetID, snapshot: $0) }
        tracker.observe(context(a, [anchorA]))
        let posAValue = await tracker.position(for: ["A"], canonicalID: "A")
        let posA = try XCTUnwrap(posAValue)
        XCTAssertTrue(store.state.books.isEmpty, "Detection must not import a book")
        tracker.observe(context(b, [anchorB]))
        let hidden = context(b, [])
        tracker.observe(hidden) // User switches to BooksBridge while parsing is still running.
        store.addBook(assetID: "B", title: b.title, author: "")
        let cachedBValue = await tracker.position(for: ["B"], canonicalID: "B")
        let cachedB = try XCTUnwrap(cachedBValue)
        XCTAssertNotEqual(cachedB.sourceHash, posA.sourceHash)
        let assistant = reader(root)
        for _ in 0..<3 {
            let chat = try XCTUnwrap(store.createConversation(assetID: "B"))
            let snapshot = try await assistant.refresh(book: b, live: hidden, previous: nil, shared: cachedB)
            XCTAssertNotNil(snapshot.page); XCTAssertTrue(snapshot.reused); XCTAssertEqual(snapshot.assetID, "B")
            XCTAssertEqual(snapshot.positionEvidence, cachedB.positionEvidence)
            store.updateReading(assetID: "B", conversationID: chat.id, snapshot: snapshot)
            XCTAssertTrue(store.conversation(assetID: "B", conversationID: chat.id)!.title.hasPrefix("5%"))
            let permitted = try assistant.reading(snapshot: snapshot, scope: .upToProgress).chapters.map(\.text).joined()
            XCTAssertTrue(permitted.contains(anchorB)); XCTAssertFalse(permitted.contains(anchorA)); XCTAssertFalse(permitted.contains("未读秘密"))
        }
        let wrong = try await assistant.refresh(book: b, live: hidden, previous: nil, shared: posA)
        XCTAssertNil(wrong.page, "Matching display titles are not identity")
    }
    func testPositionPersistsAcrossRestartButOriginalSourceIsUntouched() async throws {
        let (root, a, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: a.path!), before = try BookSourceIdentity.read(at: source)
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        store.addBook(assetID: "A", title: a.title, author: "")
        let tracker = BookPositionTracker(); tracker.onVerified = { _ = store.saveVerifiedPosition(assetID: $0.assetID, snapshot: $0) }
        tracker.observe(context(a, [anchorA]))
        let verifiedValue = await tracker.position(for: ["A"], canonicalID: "A")
        let verified = try XCTUnwrap(verifiedValue)
        let reloaded = ConversationStore(fileURL: root.appendingPathComponent("app/store.json"))
        let persisted = try XCTUnwrap(reloaded.book(assetID: "A")?.verifiedPosition)
        XCTAssertEqual(persisted.positionEvidence, verified.positionEvidence, "Fractional database timestamp survives JSON")
        let result = try await reader(root).refresh(book: a, live: context(a, []), previous: nil, shared: persisted)
        XCTAssertEqual(result.page, verified.page); XCTAssertTrue(result.reused)
        let json = try String(contentsOf: root.appendingPathComponent("app/store.json"), encoding: .utf8)
        XCTAssertFalse(json.contains(anchorA)); XCTAssertFalse(json.contains("未读秘密"))
        XCTAssertEqual(try BookSourceIdentity.read(at: source), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/maps").path))
    }
    func testPageOrDatabaseMovementRejectsCachedPositionEvenWhenProgressIsUnchanged() async throws {
        let (root, a, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = reader(root)
        let position = try await assistant.refresh(book: a, live: context(a, [anchorA]), previous: nil)
        for changed in [context(a, [], page: "第14页|第15页"), context(a, [], raw: "epubcfi(/6/2!/4/4,:1)"), context(a, [], updated: Date(timeIntervalSince1970: 1001)), context(a, [], page: nil)] {
            let result = try await assistant.refresh(book: a, live: changed, previous: position, shared: position)
            XCTAssertNil(result.page); XCTAssertFalse(result.reused)
            XCTAssertTrue(result.label.contains("书库进度 5.0%")); XCTAssertTrue(result.label.contains("页末尚未定位"))
            XCTAssertThrowsError(try assistant.reading(snapshot: result, scope: .upToProgress))
        }
    }
    func testNoPageMarkerOnlyAllowsRecentDatabaseVerifiedObservation() async throws {
        let (root, a, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = reader(root), stamp = Date()
        let old = try await assistant.refresh(book: a, live: context(a, [anchorA], page: nil, at: stamp), previous: nil)
        let recent = try await assistant.refresh(book: a, live: context(a, [], page: nil, at: stamp.addingTimeInterval(2)), previous: nil, shared: old)
        XCTAssertNotNil(recent.page)
        let stale = try await assistant.refresh(book: a, live: context(a, [], page: nil, at: stamp.addingTimeInterval(16)), previous: nil, shared: old)
        XCTAssertNil(stale.page)
        let noEvidence = ReadingContext(book: a, position: nil, visibleText: [], selection: nil)
        let missing = try await assistant.refresh(book: a, live: noEvidence, previous: old, shared: old)
        XCTAssertNil(missing.page)
    }
    func testSourceChangesAndMismatchedLiveTextNeverReuseCache() async throws {
        let (root, a, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = reader(root)
        let position = try await assistant.refresh(book: a, live: context(a, [anchorA]), previous: nil)
        do {
            _ = try await assistant.refresh(book: a, live: context(a, [anchorB]), previous: position, shared: position)
            XCTFail("Visible text mismatch must fail closed")
        } catch {}
        try "<h1>已变化</h1><p>完全不同的原文</p>".write(to: root.appendingPathComponent("A/a.xhtml"), atomically: true, encoding: .utf8)
        let changed = try await assistant.refresh(book: a, live: context(a, []), previous: position, shared: position)
        XCTAssertNil(changed.page)
    }
    func testInactiveConversationKeepsOwnPositionAndNewChatCanUseSameBookPosition() async throws {
        let (root, a, b, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let assistant = reader(root)
        let original = try await assistant.refresh(book: a, live: context(a, [anchorA]), previous: nil)
        let newer = try await assistant.refresh(book: a, live: context(a, ["后续未读秘密不能进入当前页。"], page: "第14页"), previous: nil)
        let existing = try await assistant.refresh(book: a, live: context(b, [anchorB]), previous: original, shared: newer)
        XCTAssertEqual(existing.page, original.page); XCTAssertTrue(existing.reused)
        let newChat = try await assistant.refresh(book: a, live: context(b, []), previous: nil, shared: original)
        XCTAssertEqual(newChat.page, original.page)
        let unknown = ReadingSnapshot(assetID: "A", sourceHash: original.sourceHash, page: nil, chapterTitle: "尚未定位", progress: 0, reused: true)
        let unresolved = try await assistant.refresh(book: a, live: nil, previous: unknown)
        XCTAssertFalse(unresolved.reused); XCTAssertNil(unresolved.page)
    }
    private actor Gate {
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func pause() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testLateObservationCannotRepopulateDeletedBookOrOverwriteChangedPage() async throws {
        for mode in ["delete", "move"] {
            let (root, a, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let assistant = reader(root), live = context(a, [anchorA]), gate = Gate(), tracker = BookPositionTracker()
            let snapshot = try await assistant.refresh(book: a, live: live, previous: nil)
            var callbacks = 0; tracker.onVerified = { _ in callbacks += 1 }
            tracker.loadOverride = { _ in await gate.pause(); return snapshot }
            tracker.observe(live)
            for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
            if mode == "delete" { tracker.forget(["A"]) }
            else { tracker.observe(context(a, [], page: "第14页")) }
            await gate.release()
            let result = await tracker.position(for: ["A"], canonicalID: "A")
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(result); XCTAssertEqual(callbacks, 0)
        }
    }
    func testBoundedPreimportCacheAndExplicitAliasMapping() async throws {
        let (root, a, b, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tracker = BookPositionTracker(capacity: 1)
        tracker.observe(context(a, [anchorA]))
        _ = await tracker.position(for: ["A"], canonicalID: "A")
        tracker.observe(context(b, [anchorB]))
        let alias = await tracker.position(for: ["B"], canonicalID: "canonical")
        XCTAssertEqual(alias?.assetID, "canonical")
        let removed = await tracker.position(for: ["A"], canonicalID: "A")
        XCTAssertNil(removed)
        tracker.reset()
        let reset = await tracker.position(for: ["B"], canonicalID: "B")
        XCTAssertNil(reset)
    }
    func testInvalidForegroundObservationBlocksStoredReuseUntilReverified() async throws {
        let (root, a, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tracker = BookPositionTracker()
        tracker.observe(context(a, [anchorA])); _ = await tracker.position(for: ["A"], canonicalID: "A")
        tracker.observe(context(a, [anchorB])); _ = await tracker.position(for: ["A"], canonicalID: "A")
        tracker.observe(context(a, []))
        XCTAssertTrue(tracker.hasUnverifiedObservation(for: ["A"]))
        tracker.observe(context(a, [anchorA])); _ = await tracker.position(for: ["A"], canonicalID: "A")
        XCTAssertFalse(tracker.hasUnverifiedObservation(for: ["A"]))
    }
    func testPageLabelsAreMetadataNotEstimatedTextOffsets() {
        XCTAssertEqual(AccessibilityReader.pageIdentity(from: ["第12页", "第13页", "第12页", "书名", "正文第14页发生的故事"]), "第12页|第13页")
        XCTAssertEqual(AccessibilityReader.pageIdentity(from: ["Page 12", "Page 13"]), "Page 12|Page 13")
        XCTAssertNil(AccessibilityReader.pageIdentity(from: ["12", "5%", "第1章"]))
    }
}
