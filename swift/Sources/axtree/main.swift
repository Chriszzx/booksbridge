// axtree —— 把任意进程的辅助功能（Accessibility）树打印出来。
//
// 用途：在设计阶段"读"出一个正在运行的 App 的真实界面结构，
// 比翻源码更快也更准，且不依赖该 App 是否开源。
//
// 用法：
//   axtree <pid> [maxDepth] [maxNodes]
//   axtree --find <App名片段>

import ApplicationServices
import AppKit
import Foundation

// MARK: - AX 取值

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

/// 有些容器把自己的内容放在 AXContents / AXVisibleChildren 里。
private func extraChildren(of element: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    for name in ["AXContents", "AXVisibleChildren", "AXRows", "AXColumns"] {
        if let list = attribute(element, name) as? [AXUIElement] {
            result.append(contentsOf: list)
        }
    }
    return result
}

private func frameDescription(_ element: AXUIElement) -> String? {
    guard let positionRef = attribute(element, kAXPositionAttribute as String),
          let sizeRef = attribute(element, kAXSizeAttribute as String),
          CFGetTypeID(positionRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
    return "\(Int(point.x)),\(Int(point.y)) \(Int(size.width))×\(Int(size.height))"
}

// MARK: - 遍历器

/// 值得打印的角色——过滤掉噪音，只留下能体现布局的节点。
private let interestingRoles: Set<String> = [
    "AXWindow", "AXSheet", "AXDrawer", "AXGroup", "AXSplitGroup", "AXScrollArea",
    "AXList", "AXOutline", "AXTable", "AXRow", "AXColumn", "AXToolbar", "AXTabGroup",
    "AXRadioGroup", "AXButton", "AXTextField", "AXTextArea", "AXStaticText",
    "AXImage", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXWebArea", "AXLink",
    "AXHeading", "AXDisclosureTriangle", "AXProgressIndicator", "AXSlider",
]

private final class TreeWalker {
    private let maxDepth: Int
    private let maxNodes: Int
    private var nodeCount = 0
    private var seen = Set<CFHashCode>()

    init(maxDepth: Int, maxNodes: Int) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    var visitedCount: Int { nodeCount }

    func walk(_ element: AXUIElement, depth: Int = 0) {
        guard depth <= maxDepth, nodeCount < maxNodes else { return }
        let hash = CFHash(element)
        guard !seen.contains(hash) else { return }
        seen.insert(hash)
        nodeCount += 1

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? "?"
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let title = stringAttribute(element, kAXTitleAttribute as String)
        let description = stringAttribute(element, kAXDescriptionAttribute as String)
        let value = stringAttribute(element, kAXValueAttribute as String)
        let help = stringAttribute(element, kAXHelpAttribute as String)

        let printable = role == "AXStaticText" || interestingRoles.contains(role)
        if printable {
            let indent = String(repeating: "  ", count: depth)
            var line = "\(indent)\(role)"
            if let subrole, !subrole.isEmpty { line += "/\(subrole)" }
            if let frame = frameDescription(element) { line += "  [\(frame)]" }
            var labels: [String] = []
            if let title, !title.isEmpty { labels.append("title=\(title.prefix(60))") }
            if let description, !description.isEmpty { labels.append("desc=\(description.prefix(60))") }
            if let value, !value.isEmpty { labels.append("value=\(value.prefix(70))") }
            if let help, !help.isEmpty { labels.append("help=\(help.prefix(40))") }
            if !labels.isEmpty { line += "  " + labels.joined(separator: " | ") }
            print(line)
        }

        // 只有结构节点才增加缩进，避免被大量匿名容器淹没
        let nextDepth = printable && role != "AXStaticText" ? depth + 1 : depth
        for child in children(of: element) + extraChildren(of: element) {
            walk(child, depth: nextDepth)
        }
    }
}

// MARK: - CLI

private func main() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var pid: pid_t?
    var maxDepth = 12
    var maxNodes = 600

    if let findIndex = args.firstIndex(of: "--find"), findIndex + 1 < args.count {
        let needle = args[findIndex + 1].lowercased()
        let match = NSWorkspace.shared.runningApplications.first { app in
            (app.localizedName ?? "").lowercased().contains(needle)
                || (app.bundleIdentifier ?? "").lowercased().contains(needle)
        }
        guard let match else {
            FileHandle.standardError.write(Data("找不到名称含 '\(needle)' 的运行中 App\n".utf8))
            return 1
        }
        pid = match.processIdentifier
        print("匹配到：\(match.localizedName ?? "?")  pid=\(match.processIdentifier)  bundle=\(match.bundleIdentifier ?? "?")")
        args.removeFirst(2)
    }

    if pid == nil, let first = args.first, let parsed = pid_t(first) {
        pid = parsed
        args.removeFirst()
    }
    if let depthArg = args.first, let parsed = Int(depthArg) {
        maxDepth = parsed
        args.removeFirst()
    }
    if let nodeArg = args.first, let parsed = Int(nodeArg) {
        maxNodes = parsed
    }

    guard let targetPID = pid else {
        FileHandle.standardError.write(Data("用法：axtree <pid> [maxDepth] [maxNodes]  或  axtree --find <App名>\n".utf8))
        return 1
    }
    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(Data("缺少辅助功能权限\n".utf8))
        return 1
    }

    let app = AXUIElementCreateApplication(targetPID)
    let walker = TreeWalker(maxDepth: maxDepth, maxNodes: maxNodes)
    print("=== pid \(targetPID) 的辅助功能树（maxDepth=\(maxDepth)）===\n")
    walker.walk(app)
    print("\n=== 共 \(walker.visitedCount) 个节点 ===")
    return 0
}

exit(main())
