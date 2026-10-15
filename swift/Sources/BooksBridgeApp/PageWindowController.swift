import AppKit
import Foundation

/// 页面窗口。
///
/// 两种模式：
/// - **窗口化（windowed，默认）**：内容延伸到透明标题栏，保留原生红黄绿按钮，
///   可拖动、可缩放、可最小化。用 `visibleFrame` 居中摆放，不与菜单栏/Dock 重叠。
/// - **全屏（fullscreen）**：原生 macOS 全屏空间。
///
/// 早期版本有过 `.borderless` 的无边框铺满模式，已移除：
/// 无边框窗口没有标题栏，用户既不能拖也不能缩，且小尺寸下内容会互相挤压。
///
/// 也不用 `NSPanel`/`.nonactivatingPanel`：输入框必须能正常成为 key window，
/// 而"返回图书"已实测不影响图书 App 的状态，无需靠不激活来规避。
@MainActor
public final class PageWindowController: NSWindowController {
    public enum Mode: String {
        /// 标准窗口（默认）。
        case windowed
        /// 原生全屏。
        case fullscreen

        /// 兼容旧参数名：`native` 曾是全屏的取值。
        public static func parse(_ raw: String) -> Mode? {
            if let mode = Mode(rawValue: raw) { return mode }
            return raw == "native" ? .fullscreen : nil
        }
    }

    private let mode: Mode
    /// 记住用户调整过的窗口大小，下次打开沿用。
    private var lastWindowedFrame: NSRect?
    /// 与 WebUI 的 --window-drag-height 一致；这条区域只承载原生窗口操作。
    static let dragRegionHeight: CGFloat = 28

    public init(mode: Mode) {
        self.mode = mode

        let window = NSWindow(
            contentRect: PageWindowController.defaultContentRect(),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "BooksBridge"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        // 防止被压到布局塌陷的尺寸
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)

        // Web UI arbitrates Escape for dialogs, editing and the double-Escape stop shortcut.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    /// 网页背景覆盖整个窗口，顶部空白区域由 AppKit 处理拖动。
    /// 不把整个 WKWebView 设为可拖动，以免干扰文字选择与输入。
    public func installContentView(_ content: NSView) {
        guard let window else { return }
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let dragRegion = WindowDragRegion()
        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dragRegion)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dragRegion.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragRegion.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragRegion.topAnchor.constraint(equalTo: container.topAnchor),
            dragRegion.heightAnchor.constraint(equalToConstant: Self.dragRegionHeight),
        ])
        window.contentView = container
    }

    // MARK: - 尺寸

    /// 默认内容尺寸。
    ///
    /// 取屏幕可见区的 72%，并夹在 [860×580, 1200×820] 之间——
    /// 既能在小屏上留出边距，也不会在大屏上过分铺开。
    private static func defaultContentRect() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(visible.width * 0.72, 860), 1200)
        let height = min(max(visible.height * 0.78, 580), 820)
        let origin = NSPoint(
            x: visible.minX + (visible.width - width) / 2,
            y: visible.minY + (visible.height - height) / 2
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    /// 确保窗口完全落在屏幕可见区域内（换显示器或改分辨率后可能越界）。
    private func clampToVisibleScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame

        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)

        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - 显示 / 隐藏

    /// 供自动化验证：强制设定内容尺寸（用于测试最小尺寸下的布局）。
    public func forceContentSize(_ size: NSSize) {
        guard let window else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true)
    }

    public func show() {
        guard let window else { return }

        switch mode {
        case .windowed:
            // 沿用上次的尺寸（若用户调过），否则用默认居中位置
            window.setFrame(lastWindowedFrame ?? Self.defaultContentRect(), display: false)
            clampToVisibleScreen()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()

        case .fullscreen:
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    public func hide() {
        guard let window else { return }
        if mode == .windowed, !window.styleMask.contains(.fullScreen) {
            lastWindowedFrame = window.frame
        }
        switch mode {
        case .windowed:
            window.orderOut(nil)
        case .fullscreen:
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            window.orderOut(nil)
        }
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    @discardableResult
    public func toggle() -> Bool {
        if isVisible {
            hide()
            return false
        } else {
            show()
            return true
        }
    }

    // MARK: - 状态描述（供诊断与自动化验证）

    public var stateDescription: String {
        guard let window else { return "(无窗口)" }
        let frame = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let inside = visible.contains(frame)
        return """
        模式=\(mode.rawValue) 可见=\(window.isVisible) 全屏=\(window.styleMask.contains(.fullScreen))
        窗口 frame  = \(Int(frame.width))×\(Int(frame.height)) @ (\(Int(frame.origin.x)),\(Int(frame.origin.y)))
        屏幕可见区  = \(Int(visible.width))×\(Int(visible.height)) @ (\(Int(visible.origin.x)),\(Int(visible.origin.y)))
        标题栏      = 一体式（保留原生窗口按钮）
        可缩放      = \(window.styleMask.contains(.resizable) ? "是" : "否")
        完全在屏内  = \(inside ? "是" : "否")
        最小尺寸    = \(Int(window.contentMinSize.width))×\(Int(window.contentMinSize.height))
        """
    }

}

/// 透明且仅覆盖顶部留白，原生窗口按钮仍由标题栏承载。
@MainActor
final class WindowDragRegion: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            if action == "Minimize" { window.performMiniaturize(nil) }
            else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
    }
}
