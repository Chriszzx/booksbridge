import XCTest
import BooksBridgeCore
@testable import BooksBridgeApp

final class BookDataRemovalTests: XCTestCase {
    func testDeletionRemovesOwnedDocumentsIncludingAliasesAndArchivesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let original = root.appendingPathComponent("AppleBooks/original.epub")
        try FileManager.default.createDirectory(at:original.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("Apple Books 原书".utf8).write(to:original)
        let support = root.appendingPathComponent("BooksBridge")
        let store = ConversationStore(fileURL:support.appendingPathComponent("store.json"))
        store.addBook(assetID:"A",title:"同名",author:"")
        store.addBook(assetID:"OTHER",title:"同名",author:"")
        let c = try XCTUnwrap(store.createConversation(assetID:"A"))
        store.appendMessage(assetID:"A",conversationID:c.id,message:.init(role:.assistant,text:"回答",reasoning:"推理",reasoningExpanded:true))
        store.setArchived(assetID:"A",conversationID:c.id,archived:true)
        let identity = try BookSourceIdentity.read(at:original)
        store.bindSource(assetID:"A",identity:identity)
        store.linkSource(assetID:"A",incomingID:"ALIAS",identity:identity)
        var owned: [URL] = []
        for id in ["A","ALIAS","OTHER"] {
            for relative in ["maps/" + BookDataRemoval.mapFilename(assetID:id),"knowledge/\(id).json","knowledge/\(id).md"] {
                let file = support.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data("缓存".utf8).write(to:file)
                if id != "OTHER" { owned.append(file) }
            }
        }
        try BookDataRemoval(directory:support).removeBook(assetID:"A",store:store)
        XCTAssertNil(store.book(assetID:"A")); XCTAssertNil(store.book(assetID:"ALIAS"))
        XCTAssertNotNil(ConversationStore(fileURL:support.appendingPathComponent("store.json")).book(assetID:"OTHER"))
        XCTAssertTrue(owned.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath:support.appendingPathComponent("maps/" + BookDataRemoval.mapFilename(assetID:"OTHER")).path))
        XCTAssertEqual(try Data(contentsOf:original),Data("Apple Books 原书".utf8))
    }

    func testWriteFailureRollsBackRecordAndCacheMoves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let stateDirectory = root.appendingPathComponent("state"), backup = root.appendingPathComponent("backup")
        let store = ConversationStore(fileURL:stateDirectory.appendingPathComponent("store.json"))
        store.addBook(assetID:"A",title:"书",author:"")
        let map = root.appendingPathComponent("maps/" + BookDataRemoval.mapFilename(assetID:"A"))
        try FileManager.default.createDirectory(at:map.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("地图".utf8).write(to:map)
        try FileManager.default.moveItem(at:stateDirectory,to:backup)
        try Data("blocked".utf8).write(to:stateDirectory)
        XCTAssertThrowsError(try BookDataRemoval(directory:root).removeBook(assetID:"A",store:store))
        XCTAssertNotNil(store.book(assetID:"A"))
        XCTAssertNotNil(store.lastWriteError)
        XCTAssertEqual(try Data(contentsOf:map),Data("地图".utf8))
        XCTAssertFalse(store.renameBook(assetID:"A",title:"失败的名称"))
        XCTAssertEqual(store.book(assetID:"A")?.displayTitle,"书")
    }
}
