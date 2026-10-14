import XCTest

@testable import BooksBridgeCore

final class BooksPathsTests: XCTestCase {
    func testDefaultPathsAreUnderContainer() {
        let paths = BooksPaths(home: URL(fileURLWithPath: "/Users/tester"))
        XCTAssertEqual(
            paths.preferences.path,
            "/Users/tester/Library/Containers/com.apple.iBooksX/Data/Library/Preferences/com.apple.iBooksX.plist"
        )
        XCTAssertEqual(
            paths.documents.path,
            "/Users/tester/Library/Containers/com.apple.iBooksX/Data/Documents"
        )
    }

    func testMissingContainerYieldsNoDatabases() {
        let paths = BooksPaths(home: URL(fileURLWithPath: "/nonexistent-home-xyz"))
        XCTAssertNil(paths.libraryDatabase())
        XCTAssertNil(paths.annotationDatabase())
    }
}

final class ModelsTests: XCTestCase {
    func testUnknownAuthorIsHidden() {
        let book = Book(
            assetID: "A", title: "T", author: "UnknownAuthor",
            progress: 0.5, contentType: .epub, path: nil, lastOpened: nil
        )
        XCTAssertNil(book.displayAuthor)
        XCTAssertEqual(book.displayTitle, "《T》")
    }

    func testRealAuthorIsShown() {
        let book = Book(
            assetID: "A", title: "T", author: " 某人 ",
            progress: 0, contentType: .pdf, path: nil, lastOpened: nil
        )
        XCTAssertEqual(book.displayAuthor, "某人", "首尾空白应被去掉")
    }

    func testAuthorWithPrivateUsePrefixIsTreatedAsUnknown() {
        // 实测样本：图书 App 里有些书的作者字段是 "\u{E83A}UnknownAuthor"
        let book = Book(
            assetID: "A", title: "004 荒岛惊魂", author: "\u{E83A}UnknownAuthor",
            progress: 0, contentType: .pdf, path: nil, lastOpened: nil
        )
        XCTAssertNil(book.displayAuthor, "私有区前缀不应让占位作者蒙混过关")
    }

    func testAuthorStripsInvisibleCharacters() {
        let book = Book(
            assetID: "A", title: "T", author: "\u{200B}刘慈欣\u{FEFF}",
            progress: 0, contentType: .epub, path: nil, lastOpened: nil
        )
        XCTAssertEqual(book.displayAuthor, "刘慈欣")
    }

    func testBlankAuthorIsHidden() {
        let book = Book(
            assetID: "A", title: "T", author: "   ",
            progress: 0, contentType: .epub, path: nil, lastOpened: nil
        )
        XCTAssertNil(book.displayAuthor)
    }
}
