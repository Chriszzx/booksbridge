import AppKit
import BooksBridgeCore
import Foundation

/// 菜单栏上的书本桥图标。
///
/// 交互：
/// - **左键**：下拉状态菜单（状态提示 + 操作），第一项是「打开界面」
/// - **右键**：同一个菜单
///
/// 之所以先弹菜单而不是直接开窗口：菜单能承载"当前在读什么 / 配置是否就绪"
/// 这类一眼可见的状态，而开窗口是个重动作。
///
/// 菜单交给 `statusItem.menu` 由 AppKit 托管，**不要用 `popUp(positioning:at:in:)`**。
/// 早期用手动弹出，出现了两个症状：
///   - 菜单顶部出现折叠（在菜单栏边缘触发系统的截断行为）
///   - 点开后位置发生位移（手动 origin 与内容实际高度不一致，AppKit 二次摆放）
/// 改成托管后由系统统一计算位置与尺寸，两个问题一并消失。
@MainActor
public final class StatusItemController: NSObject {
    /// 菜单需要展示的运行时状态。
    public struct MenuState {
        public var bookTitle: String?
        public var bookProgress: Double?
        public var conversationTitle: String?
        public var isDetecting: Bool
        public var fullDiskAccess: Bool
        public var accessibility: Bool
        public var llmConfigured: Bool

        public init(
            bookTitle: String? = nil,
            bookProgress: Double? = nil,
            conversationTitle: String? = nil,
            isDetecting: Bool = false,
            fullDiskAccess: Bool = false,
            accessibility: Bool = false,
            llmConfigured: Bool = false
        ) {
            self.bookTitle = bookTitle
            self.bookProgress = bookProgress
            self.conversationTitle = conversationTitle
            self.isDetecting = isDetecting
            self.fullDiskAccess = fullDiskAccess
            self.accessibility = accessibility
            self.llmConfigured = llmConfigured
        }
    }

    /// 由外部提供当前状态，避免这里持有业务对象。
    public var stateProvider: () -> MenuState = { MenuState() }

    private var menuIsOpen = false
    public var onRefresh: (() -> Void)?
    private let statusItem: NSStatusItem
    private let onOpenPage: () -> Void
    private let onOpenSettings: () -> Void
    private let onReturnToReader: () -> Void
    private let onOpenDataDirectory: () -> Void

    public init(
        onOpenPage: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onReturnToReader: @escaping () -> Void,
        onOpenDataDirectory: @escaping () -> Void
    ) {
        self.onOpenPage = onOpenPage
        self.onOpenSettings = onOpenSettings
        self.onReturnToReader = onReturnToReader
        self.onOpenDataDirectory = onOpenDataDirectory

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = AppIconFactory.menuBarImage()
            button.setAccessibilityLabel("BooksBridge")
        }

        // 交给 AppKit 托管：位置与尺寸都由系统计算，不会出现位移与折叠
        statusItem.menu = makeMenu()

        refreshTooltip()
    }

    // MARK: - 交互

    /// 建一个空菜单并挂上 delegate。
    ///
    /// 内容由 `menuNeedsUpdate` 在每次弹出前填充——这样"打开前一刻的状态"
    /// 才准确，也不会在前后台切换时反复重建。
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    /// 刷新悬停提示，让用户不点也能看到当前在读什么。
    public func refreshTooltip() {
        let state = stateProvider()
        var parts: [String] = ["BooksBridge"]
        if let title = state.bookTitle {
            let percent = Int((state.bookProgress ?? 0) * 100)
            parts.append("正在读《\(title)》 \(percent)%")
        } else if state.isDetecting {
            parts.append("等待检测图书…")
        } else {
            parts.append("图书 App 未在阅读")
        }
        statusItem.button?.toolTip = parts.joined(separator: " · ")
        if menuIsOpen, let menu = statusItem.menu { rebuild(menu) }
    }

    // MARK: - 菜单构造

    /// 供自动化验证：把菜单结构转成文本。
    ///
    /// 状态栏项不支持 `AXPress`（系统返回 -25204），无法用辅助功能 API 点击验证，
    /// 因此改为直接验证菜单构造结果——这能覆盖"项是否齐全、顺序是否正确"。
    public func describeMenu(state: MenuState) -> String {
        let menu = buildMenu(with: state)
        var lines: [String] = ["菜单共 \(menu.items.count) 项"]
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                lines.append("  [\(index)] ────────")
                continue
            }
            let flags = [
                item.isEnabled ? nil : "只读",
                item.indentationLevel > 0 ? "缩进\(item.indentationLevel)" : nil,
                item.image != nil ? "有图标" : nil,
                item.keyEquivalent.isEmpty ? nil : "⌘\(item.keyEquivalent)",
                item.target != nil ? nil : "无动作",
            ].compactMap { $0 }
            let suffix = flags.isEmpty ? "" : "  (\(flags.joined(separator: ", ")))"
            lines.append("  [\(index)] \(item.title)\(suffix)")
        }
        return lines.joined(separator: "\n")
    }

    private func buildMenu() -> NSMenu {
        buildMenu(with: stateProvider())
    }

    private func buildMenu(with state: MenuState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ══════ 状态区（在上）：一眼看到在读什么、是否就绪 ══════
        menu.addItem(sectionHeader("当前在读"))

        if let title = state.bookTitle {
            let percent = Int((state.bookProgress ?? 0) * 100)
            menu.addItem(readOnly("《\(title)》"))
            menu.addItem(readOnly("进度 \(percent)%" + (state.conversationTitle.map { " · \($0)" } ?? "")))
        } else {
            menu.addItem(readOnly(state.isDetecting ? "正在检测…" : "图书 App 未在阅读"))
        }

        menu.addItem(.separator())

        // 三项就绪状态，紧凑成两行：权限一行，配置一行
        let permissionsOK = state.fullDiskAccess && state.accessibility
        menu.addItem(statusRow(
            permissionsOK ? "权限已就绪" : "权限缺失",
            ok: permissionsOK,
            detail: permissionsOK ? nil : permissionDetail(state)
        ))
        menu.addItem(statusRow(
            state.llmConfigured ? "LLM 已配置" : "LLM 未配置",
            ok: state.llmConfigured
        ))

        menu.addItem(.separator())

        // ══════ 操作区（在下）══════
        menu.addItem(actionItem("打开界面", #selector(menuOpenPage), symbol: "macwindow"))
        menu.addItem(actionItem("设置…", #selector(menuOpenSettings), key: ",", symbol: "gearshape"))
        menu.addItem(actionItem("返回图书 App", #selector(menuReturnToReader), symbol: "book"))

        menu.addItem(.separator())
        menu.addItem(actionItem("退出 BooksBridge", #selector(menuQuit), key: "q"))

        return menu
    }

    /// 权限缺失时把缺哪一项说清楚，而不是笼统的"缺失"。
    private func permissionDetail(_ state: MenuState) -> String? {
        var missing: [String] = []
        if !state.fullDiskAccess { missing.append("磁盘访问") }
        if !state.accessibility { missing.append("辅助功能") }
        return missing.isEmpty ? nil : missing.joined(separator: " + ")
    }

    private func actionItem(
        _ title: String,
        _ selector: Selector,
        key: String = "",
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 一行只读内容。
    private func readOnly(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
    }

    /// 一行只读状态，用 ✓ / ⚠ 图标。
    private func statusRow(_ title: String, ok: Bool, detail: String? = nil) -> NSMenuItem {
        let suffix = detail.map { "（\($0)）" } ?? ""
        let item = NSMenuItem(title: "\(title)\(suffix)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = symbol(ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        return item
    }

    // MARK: - 菜单动作

    @objc private func menuOpenPage() { onOpenPage() }
    @objc private func menuOpenSettings() { onOpenSettings() }
    @objc private func menuReturnToReader() { onReturnToReader() }
    @objc private func menuOpenData() { onOpenDataDirectory() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

// MARK: - 菜单内容刷新

extension StatusItemController: NSMenuDelegate {
    /// 每次弹出前重建菜单，使状态保持最新。
    ///
    /// 返回 false 表示"不复用旧菜单"：AppKit 会直接用我们在 `menuNeedsUpdate` 里
    /// 换上的新菜单，不再做自己的启用状态推断（启用状态由我们显式设置）。
    public func menuNeedsUpdate(_ menu: NSMenu) {
        onRefresh?()
        rebuild(menu)
    }

    public func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    public func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = buildMenu()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
    }

    public func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: UnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
