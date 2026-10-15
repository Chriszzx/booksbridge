import AppKit
import WebKit
import XCTest
@testable import BooksBridgeApp

@MainActor
final class PageWindowControllerTests: XCTestCase {
    func testIntegratedWindowKeepsNativeControlsAndContentClearOfDragRegion() throws {
        _ = NSApplication.shared
        let page = PageWindowController(mode: .windowed)
        let window = try XCTUnwrap(page.window)
        let webView = WKWebView()
        page.installContentView(webView)
        defer { window.close() }

        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]))
        let container = try XCTUnwrap(window.contentView)
        let dragRegion = try XCTUnwrap(container.subviews.compactMap { $0 as? WindowDragRegion }.first)

        for size in [NSSize(width: 720, height: 460), NSSize(width: 1200, height: 820)] {
            page.forceContentSize(size)
            container.layoutSubtreeIfNeeded()
            XCTAssertEqual(webView.frame, container.bounds)
            XCTAssertEqual(dragRegion.frame.maxY, container.bounds.maxY, accuracy: 0.5)
            XCTAssertEqual(dragRegion.frame.height, PageWindowController.dragRegionHeight)
            XCTAssertEqual(dragRegion.frame.width, container.bounds.width)
            XCTAssertFalse(dragRegion.frame.contains(NSPoint(x: 120, y: container.bounds.maxY - 50)))
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let control = try XCTUnwrap(window.standardWindowButton(kind))
                XCTAssertFalse(control.isHidden)
                let rect = container.convert(control.bounds, from: control)
                XCTAssertLessThan(rect.maxX, 210)
                XCTAssertGreaterThanOrEqual(rect.minY, dragRegion.frame.minY)
            }
        }
    }
}
