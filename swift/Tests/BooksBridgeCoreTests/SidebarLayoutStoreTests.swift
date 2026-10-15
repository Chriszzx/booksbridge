import Foundation
import XCTest
@testable import BooksBridgeApp

final class SidebarLayoutStoreTests: XCTestCase {
    func testDefaultsAndIndependentBookFoldsSurviveReload() throws {
        let suite = "BooksBridge.SidebarLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = SidebarLayoutStore(defaults: defaults)
        XCTAssertFalse(layout.isCollapsed)
        XCTAssertTrue(layout.collapsedBooks.isEmpty)
        XCTAssertEqual(layout.width, 248)
        layout.setWidth(335)
        layout.setCollapsed(true)
        layout.setBookCollapsed(assetID: "A", collapsed: true)
        layout.setBookCollapsed(assetID: "B", collapsed: true)
        layout.setBookCollapsed(assetID: "A", collapsed: false)

        let reloaded = SidebarLayoutStore(defaults: defaults)
        XCTAssertTrue(reloaded.isCollapsed)
        XCTAssertEqual(reloaded.collapsedBooks, ["B"])
        XCTAssertEqual(reloaded.width, 335)
        reloaded.setCollapsed(false)
        XCTAssertEqual(reloaded.collapsedBooks, ["B"])
    }

    func testWidthLimitsAndInvalidInput() throws {
        let suite = "BooksBridge.SidebarWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = SidebarLayoutStore(defaults: defaults)
        layout.setWidth(10000)
        XCTAssertEqual(layout.width, 480)
        layout.setWidth(.nan)
        layout.setWidth(.infinity)
        XCTAssertEqual(layout.width, 480)
        layout.setWidth(-50)
        XCTAssertEqual(SidebarLayoutStore(defaults: defaults).width, 210)
    }
}
