import XCTest
@testable import BooksBridgeCore

final class BookIdentityTests: XCTestCase {
    func testFileCopiesRenamesAndDifferentContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A.epub"), b = root.appendingPathComponent("不同书名.epub")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data("原书内容".utf8).write(to: a.appendingPathComponent("chapter.xhtml"))
        let first = try BookSourceIdentity.read(at: a)
        try FileManager.default.copyItem(at: a, to: b)
        XCTAssertEqual(first.fingerprint, try BookSourceIdentity.read(at: b).fingerprint)
        let moved = root.appendingPathComponent("改名.epub")
        try FileManager.default.moveItem(at: a, to: moved)
        XCTAssertEqual(first.fingerprint, try BookSourceIdentity.read(at: moved).fingerprint)
        XCTAssertTrue(BookSourceIdentity.contains(documentURL: moved.appendingPathComponent("chapter.xhtml"), sourcePath: moved.path))
        XCTAssertFalse(BookSourceIdentity.contains(documentURL: URL(fileURLWithPath: moved.path + "-other/chapter.xhtml"), sourcePath: moved.path))
        try Data("同名但内容不同".utf8).write(to: b.appendingPathComponent("chapter.xhtml"))
        XCTAssertNotEqual(first.fingerprint, try BookSourceIdentity.read(at: b).fingerprint)
    }

    func testSourceURLWinsOverTitleAndManualConfirmationExpiresWithPage() {
        func book(_ id: String, _ path: String) -> Book { .init(assetID:id,title:"同名书",author:"",progress:0,contentType:.epub,path:path,lastOpened:nil) }
        let books = [book("A","/tmp/a.epub"),book("B","/tmp/b.epub")]
        let resolver = ActiveBookResolver()
        let byFile = AccessibilityReader.Snapshot(windowTitles:["完全不同的显示名"],visibleText:["当前页"],selection:nil,documentURLs:[URL(fileURLWithPath:"/tmp/b.epub/chapter.xhtml")])
        XCTAssertEqual(resolver.resolve(snapshot:byFile,books:books)?.assetID,"B")
        let unknown = AccessibilityReader.Snapshot(windowTitles:["同名书"],visibleText:["当前页"],selection:nil,documentURLs:[URL(fileURLWithPath:"/tmp/unknown.epub")])
        XCTAssertNil(resolver.resolve(snapshot:unknown,books:[books[0]]))
        let ambiguous = AccessibilityReader.Snapshot(windowTitles:["同名书"],visibleText:["当前页"],selection:nil,windowIdentity:"window1")
        XCTAssertNil(resolver.resolve(snapshot:ambiguous,books:books))
        resolver.confirm(snapshot:ambiguous,assetID:"B")
        XCTAssertEqual(resolver.resolve(snapshot:ambiguous,books:books)?.assetID,"B")
        let changedPage = AccessibilityReader.Snapshot(windowTitles:["同名书"],visibleText:["另一页"],selection:nil,windowIdentity:"window1")
        XCTAssertNil(resolver.resolve(snapshot:changedPage,books:books))
        resolver.forget(assetIDs:["B"])
        XCTAssertNil(resolver.resolve(snapshot:ambiguous,books:books))
    }
}
