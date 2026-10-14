import AppKit
import ApplicationServices
import Foundation

/// 通过辅助功能（Accessibility）API 读取图书 App 窗口内**当前可见**的文字。
///
/// 为什么需要它：数据库里的 CFI 只能告诉你"读到哪一章的哪个位置"，
/// 但 CFI 尾部的字符偏移是相对图书 App 自己的排版文档的，
/// 与剥离 HTML 后的纯文本字符数**不同源**，不能直接用来切片。
/// 实测两条路线的正文一致率 97%，说明 AX 拿到的是同一份内容，
/// 因此分工是：**CFI 定位章节，AX 提供"此刻眼睛看到的那一页"**。
///
/// 实测（macOS 27 / 图书 9.0）：EPUB 正文由 WebKit 渲染，
/// AX 树里是大量 `AXStaticText` 节点，内容干净，无需 OCR。
public struct AccessibilityReader: Sendable {
    /// 图书 App 的 bundle identifier。
    public static let booksBundleID = "com.apple.iBooksX"

    /// 单次遍历的节点上限，防止异常深的树拖垮调用方。
    private let maxNodes: Int
    private let maxDepth: Int

    public init(maxNodes: Int = 400, maxDepth: Int = 24) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }

    public enum ReaderError: Error, CustomStringConvertible {
        case notRunning
        case noAccessibilityPermission
        case noApplicationElement

        public var description: String {
            switch self {
            case .notRunning: "图书 App 未在运行"
            case .noAccessibilityPermission: "缺少辅助功能权限"
            case .noApplicationElement: "无法创建图书 App 的辅助功能元素"
            }
        }
    }

    /// 读取结果。
    public struct Snapshot: Sendable {
        /// 窗口标题（阅读时通常是书名）。
        public let windowTitles: [String]
        /// 可见正文段落，按 AX 树顺序。
        public let visibleText: [String]
        /// 用户当前划选的文本。
        public let selection: String?
        /// 划选所在文本节点的完整内容。
        ///
        /// 实测：图书 App 的 WebKit 正文里，`AXSelectedText` 返回的是**整个段落**
        /// 而不是用户划的那几个字，因此这个字段往往等于 `selection` 所在的节点全文。
        public let selectionNodeText: String?
        /// 划选在节点内的字符范围（若 Books 上报 `AXSelectedTextRange`）。
        ///
        /// 有了它就能从 `selectionNodeText` 里精确切出用户划的片段。
        public let selectionRange: NSRange?
        /// 划选文本在屏幕上的矩形（Cocoa 坐标，原点左下）。
        public let selectionFrame: CGRect?

        public init(
            windowTitles: [String],
            visibleText: [String],
            selection: String?,
            selectionNodeText: String? = nil,
            selectionRange: NSRange? = nil,
            selectionFrame: CGRect? = nil
        ) {
            self.windowTitles = windowTitles
            self.visibleText = visibleText
            self.selection = selection
            self.selectionNodeText = selectionNodeText
            self.selectionRange = selectionRange
            self.selectionFrame = selectionFrame
        }

        /// 是否处于阅读视图（而非书库列表）。
        public var isReaderView: Bool { !visibleText.isEmpty }

        /// 用户真正划中的那几个字。
        ///
        /// 优先用 `selectionRange` 精确切分；拿不到范围时退回整段
        /// （实测多数情况下 Books 只给段落，这时"整段"也是合理的上下文）。
        public var preciseSelection: String? {
            guard let selection else { return nil }
            guard let node = selectionNodeText, let range = selectionRange,
                  range.location >= 0,
                  range.location + range.length <= node.utf16.count,
                  range.length > 0
            else { return selection }
            let utf16 = Array(node.utf16)
            let slice = Array(utf16[range.location..<(range.location + range.length)])
            return String(decoding: slice, as: UTF16.self)
        }

        /// 把可见正文拼成一段文本。
        public var joinedText: String {
            visibleText.joined(separator: "\n")
        }
    }

    /// 抓取当前快照。
    public func snapshot() throws -> Snapshot {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.booksBundleID)
            .first else {
            throw ReaderError.notRunning
        }
        guard AXIsProcessTrusted() else {
            throw ReaderError.noAccessibilityPermission
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        var titles: [String] = []
        var texts: [String] = []
        var selectionInfo: SelectionInfo?

        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef)
        if windowRef == nil { AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &windowRef) }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { throw ReaderError.noApplicationElement }
        let window = windowRef as! AXUIElement
        let readers = readerElements(window)
        if let title = string(window, kAXTitleAttribute as String) { titles.append(title) }
        let counter = Counter()
        if let windowFrame = frame(window) {
            for reader in readers {
                guard let box = frame(reader) else { continue }
                let effectiveViewport = Self.readingViewport(reader: box, window: windowFrame)
                walk(reader, depth: 0, titles: &titles, texts: &texts,
                    selectionInfo: &selectionInfo, counter: counter, viewport: effectiveViewport)
            }
        }

        let selection = selectionInfo?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return Snapshot(
            windowTitles: titles,
            visibleText: texts,
            selection: (selection?.isEmpty ?? true) ? nil : selection,
            selectionNodeText: selectionInfo?.nodeText,
            selectionRange: selectionInfo?.range,
            selectionFrame: selectionInfo?.frame
        )
    }

    /// 划选相关的原始信息。
    private struct SelectionInfo {
        var text: String
        var nodeText: String?
        var range: NSRange?
        var frame: CGRect?
    }

    // MARK: - 遍历

    private final class Counter {
        var incomplete = false
        var value = 0
        var seen = Set<CFHashCode>()
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        titles: inout [String],
        texts: inout [String],
        selectionInfo: inout SelectionInfo?,
        counter: Counter, viewport: CGRect?
    ) {
        guard depth <= maxDepth, counter.value < maxNodes else { counter.incomplete = true; return }
        counter.value += 1

        // 用 CFHash 去重，避免同一元素被多条路径重复访问
        let hash = CFHash(element)
        guard !counter.seen.contains(hash) else { return }
        counter.seen.insert(hash)

        let role = string(element, kAXRoleAttribute as String)
        switch role {
        case kAXWindowRole as String, "AXSheet":
            if let title = string(element, kAXTitleAttribute as String), !title.isEmpty {
                titles.append(title)
            }
        case kAXStaticTextRole as String, kAXTextAreaRole as String:
            if let value = string(element, kAXValueAttribute as String), value.count > 8 {
                if let box = frame(element), let viewport, viewport.intersects(box) {
                    if viewport.contains(box) { texts.append(value) }
                    else if let visible = range(element, "AXVisibleCharacterRange"),
                            visible.location >= 0, visible.length > 0,
                            visible.location + visible.length <= (value as NSString).length {
                        texts.append((value as NSString).substring(with: visible))
                    } else {
                        // WebKit often exposes an entire paragraph across several pages.
                        // Query range geometry rather than rejecting the complete snapshot.
                        var budget = 512
                        texts.append(contentsOf: visibleFragments(element, value: value,
                            viewport: viewport, budget: &budget))
                    }
                }
            }
        default:
            break
        }

        // 选中文本可能挂在不同角色的节点上；只记录第一个非空的
        if selectionInfo == nil,
           let selected = string(element, kAXSelectedTextAttribute as String),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectionInfo = SelectionInfo(
                text: selected,
                nodeText: string(element, kAXValueAttribute as String),
                range: range(element, kAXSelectedTextRangeAttribute as String),
                frame: frame(element)
            )
        }

        guard let children = children(of: element) else { return }
        for child in children {
            walk(
                child,
                depth: depth + 1,
                titles: &titles,
                texts: &texts,
                selectionInfo: &selectionInfo,
                counter: counter, viewport: viewport
            )
        }
    }

    /// Books' paginated WebKit container may sit thousands of points offscreen,
    /// while its descendant text uses correct screen coordinates. Never discard
    /// those descendants based solely on the container frame.
    static func readingViewport(reader: CGRect, window: CGRect) -> CGRect {
        let intersection = reader.intersection(window)
        return !intersection.isNull && intersection.width > 20 && intersection.height > 20 ? intersection : window
    }

    private func visibleFragments(_ element: AXUIElement, value: String,
                                  viewport: CGRect, budget: inout Int) -> [String] {
        let source = value as NSString
        var ranges: [NSRange] = []
        func visit(_ range: NSRange) {
            guard range.length > 0, budget > 0 else { return }
            budget -= 1
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForRange" as CFString,
                parameter, &result) == .success, let result,
                CFGetTypeID(result) == AXValueGetTypeID() else { return }
            var bounds = CGRect.zero
            guard AXValueGetValue(result as! AXValue, .cgRect, &bounds) else { return }
            let height = NSScreen.screens.first?.frame.height ?? 0
            bounds.origin.y = height - bounds.maxY
            guard !bounds.isEmpty, viewport.intersects(bounds) else { return }
            if viewport.contains(bounds) {
                if let last = ranges.last, NSMaxRange(last) == range.location {
                    ranges[ranges.count - 1].length += range.length
                } else { ranges.append(range) }
            } else if range.length > 1 {
                let half = range.length / 2
                visit(NSRange(location: range.location, length: half))
                visit(NSRange(location: range.location + half, length: range.length - half))
            }
        }
        visit(NSRange(location: 0, length: source.length))
        return ranges.map { source.substring(with: $0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func readerElements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 16 else { return [] }
        if string(element, kAXRoleAttribute as String) == "AXWebArea" { return [element] }
        return (children(of: element) ?? []).prefix(100).flatMap { readerElements($0, depth: depth + 1) }
    }

    // MARK: - AX 取值

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        return value as? [AXUIElement]
    }

    /// 读取 `AXSelectedTextRange`（一个 `CFRange` 装箱成 `AXValue`）。
    private func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &cfRange) else { return nil }
        return NSRange(location: cfRange.location, length: cfRange.length)
    }

    /// 读取元素的屏幕矩形，并转换成 Cocoa 坐标（原点左下）。
    ///
    /// AX 的坐标系原点在**左上**，而 AppKit 在左下，
    /// 直接把 AX 坐标喂给窗口定位会导致浮层出现在屏幕外或错位。
    private func frame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        // AX 的 y 是"距屏幕顶部"，换算到 Cocoa 需要翻折
        let cocoaY = screenHeight - point.y - size.height
        return CGRect(x: point.x, y: cocoaY, width: size.width, height: size.height)
    }
}
