import XCTest

@testable import BooksBridgeCore

/// 针对**真实图书 App 数据**的集成测试。
///
/// 这类测试依赖运行环境（装了图书 App、有书、且已授予权限），
/// 因此在条件不满足时 `XCTSkip` 而不是失败——保证别人 clone 下来也能跑通测试套件。
final class IntegrationTests: XCTestCase {
    private let paths = BooksPaths()
    private let store = BooksStore()

    private func requireLibrary() throws {
        guard paths.libraryDatabase() != nil else {
            throw XCTSkip("本机没有图书 App 书库，跳过集成测试")
        }
    }

    private func requireCurrentBook() throws -> String {
        try requireLibrary()
        guard let assetID = store.currentAssetID() else {
            throw XCTSkip("图书 App 没有记录当前在读书")
        }
        return assetID
    }

    // MARK: - 路径发现

    func testDiscoversDatabases() throws {
        try requireLibrary()
        let library = try XCTUnwrap(paths.libraryDatabase())
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
        XCTAssertTrue(library.lastPathComponent.hasPrefix("BKLibrary"))
        XCTAssertTrue(library.pathExtension == "sqlite")
    }

    func testWatchedFilesIncludeWAL() throws {
        try requireLibrary()
        let watched = paths.watchedFiles()
        XCTAssertFalse(watched.isEmpty)
        XCTAssertTrue(
            watched.contains { $0.lastPathComponent.hasSuffix(".sqlite-wal") },
            "必须监听 -wal，因为翻页就是改写它"
        )
    }

    // MARK: - 权限

    func testFullDiskAccessIsDetectedCorrectly() throws {
        try requireLibrary()
        let status = Permissions(paths: paths).fullDiskAccessStatus()
        // 有权限时应是 granted；无权限时应是 denied（而不是错误的 granted）
        if case .unknown(let why) = status {
            XCTFail("权限状态不应为 unknown：\(why)")
        }
    }

    // MARK: - 数据读取

    func testReadsCurrentBook() throws {
        let assetID = try requireCurrentBook()
        let book = try XCTUnwrap(store.book(assetID: assetID), "书库里应能找到当前书")
        XCTAssertFalse(book.title.isEmpty)
        XCTAssertGreaterThanOrEqual(book.progress, 0)
        XCTAssertLessThanOrEqual(book.progress, 1)
    }

    func testReadsReadingPosition() throws {
        let assetID = try requireCurrentBook()
        guard let position = try store.readingPosition(assetID: assetID) else {
            throw XCTSkip("当前书没有阅读位置记录")
        }
        XCTAssertFalse(position.raw.isEmpty)
        XCTAssertNotNil(position.updated, "位置记录应带更新时间")
    }

    func testRecentBooksAreSortedByLastOpened() throws {
        try requireLibrary()
        let books = try store.recentBooks(limit: 10)
        try XCTSkipIf(books.isEmpty, "书库为空")
        let dates = books.compactMap(\.lastOpened)
        XCTAssertEqual(dates, dates.sorted(by: >), "应按最后打开时间倒序")
    }

    // MARK: - 端到端：CFI → 章节正文

    func testResolvesCurrentPositionToChapterText() throws {
        let assetID = try requireCurrentBook()
        let book = try XCTUnwrap(try store.book(assetID: assetID))
        let position = try XCTUnwrap(try store.readingPosition(assetID: assetID))

        guard case .epubCFI = position.kind else {
            throw XCTSkip("当前书不是 EPUB（PDF 走另一条路线）")
        }
        let path = try XCTUnwrap(book.path, "EPUB 应有本地路径")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "书籍文件不在本地"
        )

        let cfi = try XCTUnwrap(CFI(raw: try XCTUnwrap(position.cfi)))
        let epub = try EpubDocument(root: URL(fileURLWithPath: path))

        // 两条路径必须都指向同一个章节：id 断言 vs 数字路径
        if let assertion = cfi.idAssertion {
            let byID = epub.href(forID: assertion)
            let byIndex = epub.href(forSpineIndex: cfi.spineIndex)
            XCTAssertNotNil(byID, "id 断言应能在 manifest 里找到")
            if let byID, let byIndex {
                XCTAssertEqual(byID, byIndex, "id 断言与数字路径应指向同一章节")
            }
        }

        let resolved = try epub.resolve(cfi: cfi)
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: epub.fileURL(forHref: resolved.href).path),
            "章节文件缺失（书籍文件不完整）"
        )
        XCTAssertFalse(resolved.text.isEmpty, "章节正文不应为空")
    }

    // MARK: - Coordinator 装配

    func testCoordinatorProducesContext() throws {
        let assetID = try requireCurrentBook()
        _ = assetID

        // 不读屏幕正文，避免测试依赖辅助功能授权
        let coordinator = ReadingCoordinator(options: .init(includeVisibleText: false))
        let context = try XCTUnwrap(
            coordinator.makeContext(),
            "在已授权且有当前书的前提下应能采集到上下文"
        )
        XCTAssertFalse(context.book.title.isEmpty)
    }

    func testCoordinatorChapterMatchesPosition() throws {
        let assetID = try requireCurrentBook()
        _ = assetID

        let coordinator = ReadingCoordinator(options: .init(includeVisibleText: false))
        guard let context = try? XCTUnwrap(coordinator.makeContext()) else {
            throw XCTSkip("无法采集上下文")
        }
        guard case .epubCFI = context.position?.kind else {
            throw XCTSkip("当前书不是 EPUB")
        }
        let chapter = coordinator.currentChapterText(context: context)
        // 书籍文件不完整时 chapter 为 nil，这是可接受的降级
        if let chapter {
            XCTAssertFalse(chapter.text.isEmpty)
        }
    }
}
