// axmenubar —— 读取 App 的菜单栏结构（含 AXMenuBar 与展开的菜单）。
//
// 与 axtree 的分工：axtree 看窗口内的界面，axmenubar 看菜单栏与弹出菜单，
// 后者挂在 AXMenuBar / AXMenu 上，不在常规窗口树里。
//
// 用法：
//   axmenubar <pid>              列出菜单栏顶层项
//   axmenubar <pid> --tree       递归展开所有菜单项
//   axmenubar <pid> --open <序号> 打开第 N 个顶层菜单后打印其内容（1 起）

import ApplicationServices
import AppKit
import Foundation

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func str(_ element: AXUIElement, _ name: String) -> String? {
    (attribute(element, name) as? String)
}

private func kids(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

private func describe(_ element: AXUIElement) -> String {
    let role = str(element, kAXRoleAttribute as String) ?? "?"
    var parts: [String] = []
    for key in [kAXTitleAttribute as String, kAXValueAttribute as String] {
        if let v = str(element, key), !v.isEmpty { parts.append(v) }
    }
    if let mark = attribute(element, kAXMenuItemMarkCharAttribute as String) as? String, !mark.isEmpty {
        parts.append("[\(mark)]")
    }
    if let enabled = attribute(element, kAXEnabledAttribute as String) as? Bool, !enabled {
        parts.append("(禁用)")
    }
    if let key = str(element, kAXMenuItemCmdCharAttribute as String), !key.isEmpty {
        parts.append("⌘\(key)")
    }
    return "\(role)  \(parts.joined(separator: " "))"
}

/// 递归展开一个菜单（菜单项在 AXChildren 里，子菜单挂在 AXChildren 的第一个 AXMenu 上）
private func dump(_ element: AXUIElement, indent: Int, depth: Int) {
    guard depth <= 6 else { return }
    let pad = String(repeating: "  ", count: indent)
    for child in kids(element) {
        print("\(pad)\(describe(child))")
        // 子菜单：AXMenuItem 下挂一个 AXMenu
        for sub in kids(child) {
            let role = str(sub, kAXRoleAttribute as String) ?? ""
            if role == "AXMenu" || role == "AXMenuBar" {
                dump(sub, indent: indent + 1, depth: depth + 1)
            }
        }
    }
}

private func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first, let pid = pid_t(first) else {
        FileHandle.standardError.write(Data("用法：axmenubar <pid> [--tree] [--open N]\n".utf8))
        return 1
    }
    let tree = args.contains("--tree")
    var openIndex: Int?
    if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
        openIndex = Int(args[i + 1])
    }

    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(Data("缺少辅助功能权限\n".utf8))
        return 1
    }

    let app = AXUIElementCreateApplication(pid)
    guard let menuBarRef = attribute(app, kAXMenuBarAttribute as String) else {
        print("该进程没有菜单栏（AXMenuBar 不可用）")
        return 1
    }
    let menuBar = menuBarRef as! AXUIElement

    let topItems = kids(menuBar)
    print("菜单栏顶层项: \(topItems.count)")
    for (i, item) in topItems.enumerated() {
        print("  [\(i + 1)] \(describe(item))")
    }

    if let openIndex {
        guard openIndex >= 1, openIndex <= topItems.count else {
            print("序号超出范围")
            return 1
        }
        let item = topItems[openIndex - 1]
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        print("\n打开第 \(openIndex) 项 -> \(result == .success ? "成功" : "失败(\(result.rawValue))")")
        Thread.sleep(forTimeInterval: 0.6)
        print("--- 内容 ---")
        for sub in kids(item) {
            let role = str(sub, kAXRoleAttribute as String) ?? ""
            if role == "AXMenu" { dump(sub, indent: 0, depth: 0) }
        }
        // 关掉菜单，避免影响用户
        AXUIElementPerformAction(item, kAXCancelAction as CFString)
        return 0
    }

    if tree {
        print("\n--- 全部菜单项 ---")
        dump(menuBar, indent: 0, depth: 0)
    }
    return 0
}

exit(main())
