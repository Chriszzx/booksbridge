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
        layout.setCollapsed(true)
        layout.setBookCollapsed(assetID: "A", collapsed: true)
        layout.setBookCollapsed(assetID: "B", collapsed: true)
        layout.setBookCollapsed(assetID: "A", collapsed: false)

        let reloaded = SidebarLayoutStore(defaults: defaults)
        XCTAssertTrue(reloaded.isCollapsed)
        XCTAssertEqual(reloaded.collapsedBooks, ["B"])
        reloaded.setCollapsed(false)
        XCTAssertEqual(reloaded.collapsedBooks, ["B"])
    }
}
