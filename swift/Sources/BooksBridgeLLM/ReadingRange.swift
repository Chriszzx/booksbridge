import Foundation

/// One local source, three permissions. Offsets are in normalized Unicode scalars.
public struct ReadingBoundary: Codable, Sendable, Equatable, Comparable {
    public let chapter: Int
    public let end: Int
    public init(chapter: Int, end: Int) { self.chapter = chapter; self.end = end }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.chapter == rhs.chapter ? lhs.end < rhs.end : lhs.chapter < rhs.chapter
    }
}

public struct ScopedReading: Sendable {
    public let chapters: [BookPreprocessor.Chapter]
    public let boundary: ReadingBoundary
    public let currentChapter: Int?

    public enum Failure: Error, CustomStringConvertible {
        case cannotLocatePage
        public var description: String { "无法可靠定位当前页末尾。请在 Apple Books 中打开本书并保持阅读页面可见后重试；本次没有发送正文。" }
    }

    public static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0x00ad && $0.value != 0x200b
        }))
    }

    /// Require a unique ordered match. Never choose the last occurrence of repeated text.
    public static func pageEnd(in text: String, visible: [String]) -> Int? {
        let source = normalized(text)
        let anchors = visible.map(normalized).filter { $0.count >= 12 }
        guard !anchors.isEmpty else { return nil }
        var cursor = source.startIndex
        var end: String.Index?
        for anchor in anchors {
            guard let hit = source.range(of: anchor, range: cursor..<source.endIndex) else { return nil }
            if source.range(of: anchor, range: hit.upperBound..<source.endIndex) != nil { return nil }
            cursor = hit.upperBound
            end = cursor
        }
        return end.map { source.unicodeScalars.distance(from: source.unicodeScalars.startIndex, to: $0) }
    }

    public static func prefix(chapters: [BookPreprocessor.Chapter], through boundary: ReadingBoundary, current: Int?) throws -> Self {
        guard chapters.indices.contains(boundary.chapter), boundary.end >= 0 else { throw Failure.cannotLocatePage }
        let original = chapters[boundary.chapter]
        let source = original.text.precomposedStringWithCanonicalMapping
        guard boundary.end == Int.max || boundary.end <= normalized(source).unicodeScalars.count else { throw Failure.cannotLocatePage }
        var count = 0
        var text = ""
        for scalar in source.unicodeScalars {
            let counted = !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar.value != 0xad && scalar.value != 0x200b
            if counted { if count == boundary.end { break }; count += 1 }
            text.unicodeScalars.append(scalar)
        }
        var result = Array(chapters.prefix(boundary.chapter))
        if !text.isEmpty { result.append(.init(spineIndex: original.spineIndex, href: original.href, text: text)) }
        return Self(chapters: result, boundary: boundary, currentChapter: current)
    }

    public static func resolve(chapters: [BookPreprocessor.Chapter], current: Int?, scope: KnowledgeScope,
                               visible: [String]) throws -> Self {
        guard !chapters.isEmpty else { throw Failure.cannotLocatePage }
        if scope == .wholeBook {
            return Self(chapters: chapters, boundary: .init(chapter: chapters.count - 1, end: Int.max), currentChapter: current)
        }
        // Live page text can locate the chapter even before Books flushes its CFI.
        let anchors = visible.map(normalized).filter { $0.count >= 12 }
        let sources = chapters.map { normalized($0.text) }
        var matched: ReadingBoundary?
        var valid = !anchors.isEmpty
        for anchor in anchors {
            var hits: [ReadingBoundary] = []
            for (i, source) in sources.enumerated() {
                if let hit = source.range(of: anchor) {
                    if source.range(of: anchor, range: hit.upperBound..<source.endIndex) != nil { valid = false }
                    hits.append(.init(chapter: i, end: source.unicodeScalars.distance(from: source.unicodeScalars.startIndex, to: hit.upperBound)))
                }
            }
            guard hits.count == 1, let hit = hits.first, matched == nil || matched! < hit else { valid = false; break }
            matched = hit
        }
        let live: (Int, Int)? = valid ? matched.map { ($0.chapter, $0.end) } : nil
        guard let index = live?.0 ?? (visible.isEmpty ? current : nil), chapters.indices.contains(index) else { throw Failure.cannotLocatePage }
        if scope == .currentChapter {
            return Self(chapters: Array(chapters.prefix(index + 1)), boundary: .init(chapter: index, end: Int.max), currentChapter: index)
        }
        guard let live else { throw Failure.cannotLocatePage }
        return try prefix(chapters: chapters, through: .init(chapter: index, end: live.1), current: index)
    }
}
