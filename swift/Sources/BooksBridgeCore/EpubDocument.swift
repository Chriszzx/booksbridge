import Foundation

/// 一个被 Apple Books 解包成目录的 EPUB。
///
/// 实测结论：图书 App 会把导入的 EPUB **解包成普通目录**（而非保留 zip），
/// 正文 `*.xhtml` / `*.html` 是明文，可直接读取。
/// 因此不需要解压、不需要处理 DRM。
public struct EpubDocument: Sendable {
    /// 书籍根目录。
    public let root: URL
    /// OPF（package document）的路径。
    public let opf: URL
    /// manifest：item id → href（相对 OPF 所在目录）。
    public let manifest: [String: String]
    /// spine：有序的 item id 列表，决定阅读顺序。
    public let spine: [String]

    public enum EpubError: Error, CustomStringConvertible {
        case notUnpacked(String)
        case malformedOPF(String)

        public var description: String {
            switch self {
            case .notUnpacked(let p): "不是解包形式的 EPUB（找不到 OPF）: \(p)"
            case .malformedOPF(let why): "OPF 格式异常: \(why)"
            }
        }
    }

    /// OPF 的常见相对位置，按优先级尝试。
    private static let opfCandidates = [
        "content.opf", "EPUB/content.opf", "OEBPS/content.opf",
    ]

    public init(root: URL) throws {
        guard let opf = Self.locateOPF(root: root) else {
            throw EpubError.notUnpacked(root.path)
        }
        self.root = root
        self.opf = opf

        let html = (try? String(contentsOf: opf, encoding: .utf8))
            ?? (try? String(contentsOf: opf, encoding: .isoLatin1))
            ?? ""
        guard !html.isEmpty else { throw EpubError.malformedOPF("无法读取 \(opf.path)") }

        self.manifest = Self.parseManifest(html)
        self.spine = Self.parseSpine(html)
    }

    // MARK: - 定位

    private static func locateOPF(root: URL) -> URL? {
        let fm = FileManager.default
        for candidate in opfCandidates {
            let url = root.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        // 兜底：在根目录及其一级子目录里找任意 *.opf
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries {
                if entry.pathExtension.lowercased() == "opf" { return entry }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    if let inner = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                        for sub in inner where sub.pathExtension.lowercased() == "opf" {
                            return sub
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - OPF 解析

    private static func parseManifest(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        for tag in Self.tags(named: "item", in: html) {
            guard let id = Self.attribute("id", in: tag),
                  let href = Self.attribute("href", in: tag) else { continue }
            result[id] = href
        }
        return result
    }

    private static func parseSpine(_ html: String) -> [String] {
        Self.tags(named: "itemref", in: html).compactMap { Self.attribute("idref", in: $0) }
    }

    /// 取出所有 `<name ...>` 起始标签（不处理自闭合差异，OPF 里两者皆可）。
    private static func tags(named name: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(name)\\b[^>]*>",
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let r = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }

    // MARK: - 章节定位

    /// 按 spine 序号（1-based）取 href。
    public func href(forSpineIndex index: Int) -> String? {
        guard index >= 1, index <= spine.count else { return nil }
        return manifest[spine[index - 1]]
    }

    /// 按 manifest 的 item id 取 href。
    ///
    /// CFI 的 id 断言会把 `.` `-` 归一化成 `_`，因此需要模糊匹配兜底。
    public func href(forID id: String) -> String? {
        if let exact = manifest[id] { return exact }
        let normalized = Self.normalizeID(id)
        for (key, value) in manifest where Self.normalizeID(key) == normalized {
            return value
        }
        return nil
    }

    static func normalizeID(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// 把 href 解析为绝对文件路径（href 相对 OPF 所在目录）。
    public func fileURL(forHref href: String) -> URL {
        let opfDir = opf.deletingLastPathComponent()
        // 用 URL 拼接以正确处理 ../ 与前向斜杠
        let decoded = href.removingPercentEncoding ?? href
        let base = opfDir.appendingPathComponent(decoded)
        return base.standardizedFileURL
    }

    public func html(forHref href: String) throws -> String {
        let url = fileURL(forHref: href.components(separatedBy: "#")[0])
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw EpubError.malformedOPF("正文编码无法识别：\(href)")
        }
        return raw
    }

    public func text(forHref href: String) throws -> String { HTMLText.plainText(from: try html(forHref: href)) }

    public struct NavigationEntry: Sendable {
        public let title: String
        public let href: String
        public let fragment: String?
        public let level: Int
    }

    public func navigationTitles() throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in try navigationEntries() where result[entry.href] == nil { result[entry.href] = entry.title }
        return result
    }

    /// EPUB 3 toc and EPUB 2 NCX. Page-list/landmarks are not chapter maps.
    public func navigationEntries() throws -> [NavigationEntry] {
        var result: [NavigationEntry] = []
        let opfText = try String(contentsOf: opf, encoding: .utf8)
        let navigation = Self.tags(named: "item", in: opfText).filter {
            (Self.attribute("properties", in: $0) ?? "").split(separator: " ").contains("nav")
                || (Self.attribute("media-type", in: $0) ?? "").contains("ncx")
        }
        for item in navigation {
            guard let href = Self.attribute("href", in: item) else { continue }
            var html = try self.html(forHref: href)
            let isNCX = href.lowercased().hasSuffix(".ncx")
            if !isNCX {
                let nav = try NSRegularExpression(pattern: "(?is)<nav\\b([^>]*)>(.*?)</nav>")
                let nodes = nav.matches(in: html, range: NSRange(html.startIndex..., in: html))
                if let node = nodes.first(where: { match in
                    guard let range = Range(match.range(at: 1), in: html) else { return false }
                    let attributes = String(html[range])
                    return (Self.attribute("epub:type", in: attributes) ?? "").split(separator: " ").contains("toc")
                        || Self.attribute("role", in: attributes) == "doc-toc"
                }) ?? nodes.first(where: { match in
                    guard let range = Range(match.range(at: 1), in: html) else { return false }
                    let attributes = String(html[range])
                    return Self.attribute("epub:type", in: attributes) == nil && Self.attribute("role", in: attributes) == nil
                }), let range = Range(node.range(at: 2), in: html) { html = String(html[range]) }
                else if !nodes.isEmpty { continue }
            }
            let regex = try NSRegularExpression(pattern: "(?is)<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>|<navLabel[^>]*>.*?<text[^>]*>(.*?)</text>.*?</navLabel>\\s*<content[^>]*src\\s*=\\s*[\"']([^\"']+)")
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                let linkIndex = match.range(at: 1).location != NSNotFound ? 1 : 4
                let textIndex = linkIndex == 1 ? 2 : 3
                guard let linkRange = Range(match.range(at: linkIndex), in: html), let titleRange = Range(match.range(at: textIndex), in: html), let fullRange = Range(match.range, in: html) else { continue }
                let parts = String(html[linkRange]).components(separatedBy: "#")
                let target = parts[0].isEmpty ? fileURL(forHref: href) : fileURL(forHref: href).deletingLastPathComponent().appendingPathComponent(parts[0].removingPercentEncoding ?? parts[0]).standardizedFileURL
                guard let source = manifest.values.first(where: { fileURL(forHref: $0) == target }) else { continue }
                let title = HTMLText.plainText(from: String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = String(html[..<fullRange.lowerBound])
                let openTag = isNCX ? "<navPoint\\b" : "<(?:ol|ul)\\b"
                let closeTag = isNCX ? "</navPoint\\s*>" : "</(?:ol|ul)\\s*>"
                func count(_ pattern: String) throws -> Int {
                    try NSRegularExpression(pattern: pattern, options: .caseInsensitive).numberOfMatches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
                }
                let level = max(1, try count(openTag) - count(closeTag))
                if !title.isEmpty { result.append(.init(title: title, href: source, fragment: parts.count > 1 ? parts[1].removingPercentEncoding : nil, level: level)) }
            }
        }
        return result
    }

    /// 解析 CFI 并取出对应章节的正文。
    ///
    /// - Returns: 章节 href、章节全文、以及 CFI 声明的字符偏移。
    public func resolve(cfi: CFI) throws -> (href: String, text: String, charOffset: Int?) {
        var href: String?
        // id 断言优先：它直接对应 manifest，不依赖 spine 计数规则
        if let assertion = cfi.idAssertion {
            href = self.href(forID: assertion)
        }
        if href == nil {
            href = self.href(forSpineIndex: cfi.spineIndex)
        }
        guard let href else {
            throw EpubError.malformedOPF("CFI \(cfi.raw) 无法定位到章节")
        }
        return (href, try text(forHref: href), cfi.charOffset)
    }

    /// 按 spine 顺序拼接整本书的纯文本，用于 RAG 索引。
    ///
    /// - Parameter maxCharacters: 上限保护，避免超大书一次性展开占用过多内存。
    public func fullText(maxCharacters: Int = 8_000_000) -> String {
        var buffer = ""
        buffer.reserveCapacity(min(maxCharacters, 1 << 20))
        for (index, id) in spine.enumerated() {
            guard buffer.count < maxCharacters, let href = manifest[id] else { continue }
            guard let chapter = try? text(forHref: href), !chapter.isEmpty else { continue }
            buffer += "\n\n[spine \(index + 1)] \(chapter)"
        }
        return buffer
    }
}
