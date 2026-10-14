// axact —— 对指定进程的辅助功能元素执行动作，并打印可用动作。
//
// 用途：在设计阶段触发某个控件（比如打开菜单），再读它展开后的结构。
//
// 用法：
//   axact <pid> <元素描述片段> [press|showmenu|list]
//   例：axact 1234 "账号菜单" press

import ApplicationServices
import AppKit
import Foundation

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    var result = (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    for name in ["AXContents", "AXVisibleChildren", "AXChildrenInNavigationOrder"] {
        if let list = attribute(element, name) as? [AXUIElement] { result.append(contentsOf: list) }
    }
    return result
}

/// 元素的"可读标签"：title / description / value 任一。
private func label(_ element: AXUIElement) -> String {
    for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
        if let s = stringAttribute(element, key), !s.isEmpty { return s }
    }
    return ""
}

private final class Finder {
    var matches: [(AXUIElement, String)] = []
    var visited = Set<CFHashCode>()
    let needle: String
    let maxNodes = 4000

    init(needle: String) { self.needle = needle.lowercased() }

    func search(_ element: AXUIElement, depth: Int = 0) {
        guard depth <= 30, matches.count < 20, visited.count < maxNodes else { return }
        let hash = CFHash(element)
        guard !visited.contains(hash) else { return }
        visited.insert(hash)

        let text = label(element)
        if !text.isEmpty, text.lowercased().contains(needle) {
            matches.append((element, text))
        }
        for child in children(of: element) { search(child, depth: depth + 1) }
    }
}

private func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2, let pid = pid_t(args[0]) else {
        FileHandle.standardError.write(Data("用法：axact <pid> <元素描述片段> [press|showmenu|list]\n".utf8))
        return 1
    }
    let needle = args[1]
    let action = args.count > 2 ? args[2] : "list"

    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(Data("缺少辅助功能权限\n".utf8))
        return 1
    }

    let app = AXUIElementCreateApplication(pid)
    let finder = Finder(needle: needle)
    finder.search(app)

    guard !finder.matches.isEmpty else {
        print("未找到含 '\(needle)' 的元素")
        return 1
    }

    for (index, (element, text)) in finder.matches.enumerated() {
        print("[\(index)] \(text)")

        // 可用动作
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let actions = actionsRef as? [String] {
            print("      动作: \(actions.joined(separator: ", "))")
        }

        switch action {
        case "press":
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            print("      press -> \(result == .success ? "成功" : "失败(\(result.rawValue))")")
        case "showmenu":
            let result = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            print("      showmenu -> \(result == .success ? "成功" : "失败(\(result.rawValue))")")
        default:
            break
        }
    }
    return 0
}

exit(main())
