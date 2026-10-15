import Foundation

/// App-owned metadata. Boundaries refer to the read-only EPUB; no source copy is persisted.
public struct BookStatistics: Codable, Sendable, Equatable {
    public struct Section: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let start: ReadingBoundary
        public let end: ReadingBoundary
        public let sourceHash: String
        public let characterCount: Int
        public let estimatedTokens: Int
        public var kind: String {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["目录", "目次", "contents", "table of contents"].contains(name) { return "目录" }
            if name.hasPrefix("文档区段") || name == "正文前置内容" { return "未分类区段" }
            if ["封面", "扉页", "版权", "copyright", "cover"].contains(where: { name.hasPrefix($0) }) { return "附页" }
            if ["后记", "後記", "跋", "afterword"].contains(where: { name.hasPrefix($0) }) { return "后记" }
            if ["前言", "序言", "序", "preface"].contains(name) { return "前言" }
            return "章节"
        }
    }
    public let sourceHash: String
    public let characterCount: Int
    public let estimatedTokens: Int
    public let documentCount: Int
    public let headingCount: Int
    public let sections: [Section]
    public var chapterCount: Int { sections.filter { $0.kind == "章节" }.count }

    public static func build(map: BookMap, chapters: [BookPreprocessor.Chapter]) -> Self {
        let level = map.entries.map(\.level).min() ?? 1
        var starts = map.entries.filter { $0.level == level }.map { ($0.title, $0.start) }.sorted { $0.1 < $1.1 }
        let zero = ReadingBoundary(chapter: 0, end: 0)
        if starts.first?.1 != zero { starts.insert(("正文前置内容", zero), at: 0) }
        let last = ReadingBoundary(chapter: max(0, chapters.count - 1), end: chapters.last.map { ScopedReading.normalized($0.text).unicodeScalars.count } ?? 0)
        var sections: [Section] = []
        for (i, item) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].1 : last
            guard item.1 < end else { continue }
            let text = text(chapters: chapters, from: item.1, through: end)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sections.append(.init(id: BookPreprocessor.contentHash(of: "\(item.1.chapter):\(item.1.end):\(item.0)"), title: item.0,
                start: item.1, end: end, sourceHash: BookPreprocessor.contentHash(of: text),
                characterCount: text.count, estimatedTokens: text.utf8.count))
        }
        return Self(sourceHash: map.sourceHash, characterCount: chapters.reduce(0) { $0 + $1.text.count },
            estimatedTokens: chapters.reduce(0) { $0 + $1.text.utf8.count }, documentCount: chapters.count,
            headingCount: map.entries.count, sections: sections)
    }

    /// Offsets count normalized scalars, while output preserves paragraphs and spaces.
    public static func text(chapters: [BookPreprocessor.Chapter], from start: ReadingBoundary, through end: ReadingBoundary) -> String {
        var pieces: [String] = []
        for i in chapters.indices where start.chapter <= i && i <= end.chapter {
            let low = i == start.chapter ? start.end : 0
            let high = i == end.chapter ? end.end : Int.max
            var position = 0, text = ""
            for scalar in chapters[i].text.precomposedStringWithCanonicalMapping.unicodeScalars {
                let counted = !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar.value != 0xad && scalar.value != 0x200b
                if counted && position >= high { break }
                if position >= low { text.unicodeScalars.append(scalar) }
                if counted { position += 1 }
            }
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: "\n\n")
    }
}

public struct ChapterDigest: Codable, Sendable, Equatable {
    public let sectionID: String
    public let sourceHash: String
    public let text: String
    public let model: String
    public let generatedAt: Date
    public init(section: BookStatistics.Section, text: String, model: String) {
        sectionID = section.id; sourceHash = section.sourceHash; self.text = text; self.model = model; generatedAt = Date()
    }
}

public struct BookStudy: Codable, Sendable, Equatable {
    public var statistics: BookStatistics
    public var chapters: [ChapterDigest] = []
    public var whole: ReadingSummary?
    public var wholeModel: String?
    public var status: String = "尚未生成章节摘要"
    public var completedCount: Int { statistics.sections.filter { digest(for: $0) != nil }.count }
    public init(statistics: BookStatistics) { self.statistics = statistics }
    public func digest(for section: BookStatistics.Section) -> ChapterDigest? {
        chapters.first { $0.sectionID == section.id && $0.sourceHash == section.sourceHash }
    }
    public mutating func reconcile(_ updated: BookStatistics) {
        guard statistics != updated else { return }
        chapters = chapters.filter { digest in updated.sections.contains { $0.id == digest.sectionID && $0.sourceHash == digest.sourceHash } }
        if statistics.sourceHash != updated.sourceHash { whole = nil; wholeModel = nil; status = "原文已变化，保留未变章节摘要，其余待更新" }
        statistics = updated
    }
    public func allowedSections(snapshot: ReadingSnapshot, scope: KnowledgeScope) -> [BookStatistics.Section] {
        guard snapshot.sourceHash == statistics.sourceHash else { return [] }
        if scope == .wholeBook { return statistics.sections }
        guard let page = snapshot.page else { return [] }
        if scope == .upToProgress { return statistics.sections.filter { $0.end <= page } }
        guard let current = statistics.sections.last(where: { $0.start < page && page <= $0.end }) else { return [] }
        return statistics.sections.filter { $0.end <= current.end }
    }
    /// Only safe summaries leave the book store for a conversation.
    public func summary(snapshot: ReadingSnapshot, scope: KnowledgeScope) -> ReadingSummary? {
        guard snapshot.sourceHash == statistics.sourceHash else { return nil }
        if scope == .wholeBook, let whole, whole.sourceHash == snapshot.sourceHash { return whole }
        let sections = allowedSections(snapshot: snapshot, scope: scope)
        let available = sections.compactMap { section -> (BookStatistics.Section, ChapterDigest)? in digest(for: section).map { (section, $0) } }
        guard let last = available.last else { return nil }
        return ReadingSummary(text: available.map { "## \($0.0.title)\n\($0.1.text)" }.joined(separator: "\n\n"),
            sourceHash: snapshot.sourceHash, boundary: last.0.end, scope: scope,
            coverageLabel: "已生成的 \(available.count)/\(sections.count) 个允许章节；缺失章节需查原文")
    }

    public func readingMaterial(snapshot: ReadingSnapshot, scope: KnowledgeScope, source: [BookPreprocessor.Chapter]) -> String {
        guard snapshot.sourceHash == statistics.sourceHash else { return "" }
        if scope == .wholeBook, let whole, whole.sourceHash == snapshot.sourceHash { return "全书摘要（细节需核对原文）：\n" + whole.text }
        let sections = allowedSections(snapshot: snapshot, scope: scope)
        var parts = sections.map { section -> String in
            if let digest = digest(for: section) { return "## \(section.title) · 章节摘要\n" + digest.text }
            return "## \(section.title) · 摘要尚未生成，以下为原文\n" + BookStatistics.text(chapters: source, from: section.start, through: section.end)
        }
        if scope == .upToProgress, let page = snapshot.page,
           let current = statistics.sections.first(where: { $0.start < page && page < $0.end }) {
            parts.append("## 当前章已读原文（截至阅读节点）\n" + BookStatistics.text(chapters: source, from: current.start, through: page))
        }
        return parts.joined(separator: "\n\n")
    }
}
