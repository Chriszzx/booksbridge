import AppKit
import Foundation

/// 构建应用主菜单栏。
///
/// 为什么需要：应用进入 Dock（`activationPolicy == .regular`）后，成为前台应用时
/// 系统会显示菜单栏。若不自己设置 `NSApp.mainMenu`，只会出现一个空的应用菜单——
/// 用户既看不到「设置」也找不到「退出」，按 ⌘Q 也没反应。
///
/// 只建最必要的几项，不做文档/编辑/窗口那套模板。
public enum ApplicationMenu {
    @MainActor
    public static func install(
        appName: String,
        onSettings: @escaping () -> Void,
        onShowPage: @escaping () -> Void
    ) {
        let mainMenu = NSMenu()

        // ---- 应用菜单 ----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            withTitle: "关于 \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(MenuActions.openSettings),
            keyEquivalent: ","
        )
        settings.target = MenuActions.shared
        MenuActions.shared.onSettings = onSettings
        appMenu.addItem(settings)

        let showPage = NSMenuItem(
            title: "打开界面",
            action: #selector(MenuActions.showPage),
            keyEquivalent: "0"
        )
        showPage.target = MenuActions.shared
        MenuActions.shared.onShowPage = onShowPage
        appMenu.addItem(showPage)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // ---- 编辑菜单（只为让输入框的 ⌘C/⌘V/⌘A 生效）----
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ---- 窗口菜单 ----
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

/// 菜单项的 Objective-C 动作目标。
///
/// 单独放一个类是因为菜单项需要稳定的 target；用闭包需要额外包一层。
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    var onSettings: (() -> Void)?
    var onShowPage: (() -> Void)?

    @objc func openSettings() { onSettings?() }
    @objc func showPage() { onShowPage?() }
}
