import Foundation
import BooksBridgeCore

/// Local navigation metadata only. Text remains in the source EPUB.
public struct BookMap: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let title: String
        public let level: Int
        public let start: ReadingBoundary
        public let end: ReadingBoundary
        public let href: String
    }
    public let sourceHash: String
    public let entries: [Entry]

    public func entry(at boundary: ReadingBoundary) -> Entry? {
        // A page ending exactly at the next heading still belongs to the preceding chapter.
        entries.last { $0.start < boundary && boundary <= $0.end }
            ?? entries.first { $0.start.chapter == boundary.chapter }
    }

    public static func build(epub: EpubDocument, chapters: [BookPreprocessor.Chapter]) throws -> Self {
        var starts: [(String, Int, ReadingBoundary, String)] = []
        let toc = try epub.navigationEntries()
        for (i, chapter) in chapters.enumerated() {
            let html = try epub.html(forHref: chapter.href)
            let normalized = ScopedReading.normalized(chapter.text)
            let pattern = "(?is)<h([1-6])\\b[^>]*>(.*?)</h[1-6]\\s*>"
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var headings: [(String, Int, ReadingBoundary, String)] = []
            for match in matches {
                guard let content = Range(match.range(at: 2), in: html), let rank = Range(match.range(at: 1), in: html),
                      let tag = Range(match.range, in: html) else { continue }
                let title = HTMLText.plainText(from: String(html[content])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ScopedReading.normalized(title).isEmpty else { continue }
                let offset = ScopedReading.normalized(HTMLText.plainText(from: String(html[..<tag.lowerBound]))).unicodeScalars.count
                headings.append((title, Int(html[rank]) ?? 1, .init(chapter: i, end: offset), chapter.href))
            }
            var local: [(String, Int, ReadingBoundary, String)] = []
            for entry in toc where entry.href == chapter.href {
                var offset = 0
                if let fragment = entry.fragment, !fragment.isEmpty {
                    let escaped = NSRegularExpression.escapedPattern(for: fragment)
                    let anchor = try NSRegularExpression(pattern: "(?is)<[^>]+\\b(?:id|name)\\s*=\\s*[\"']" + escaped + "[\"'][^>]*>")
                    guard let match = anchor.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range, in: html) else { continue }
                    offset = ScopedReading.normalized(HTMLText.plainText(from: String(html[..<range.lowerBound]))).unicodeScalars.count
                }
                guard offset <= normalized.unicodeScalars.count else { continue }
                local.append((entry.title, entry.level, .init(chapter: i, end: offset), chapter.href))
            }
            for heading in headings {
                if !local.contains(where: { $0.2 == heading.2 }) { local.append(heading) }
            }
            // Documents without a new heading can continue the preceding TOC chapter.
            if local.isEmpty && (toc.isEmpty || starts.isEmpty) {
                local.append(("文档区段 \(i + 1)（未提供章名）", 1, .init(chapter: i, end: 0), chapter.href))
            }
            if starts.isEmpty, local.first?.2.end ?? 0 > 0 {
                starts.append(("正文前置内容", 1, .init(chapter: i, end: 0), chapter.href))
            }
            starts.append(contentsOf: local.sorted { $0.2 < $1.2 })
        }

        var entries: [Entry] = []
        for (i, item) in starts.enumerated() {
            // A heading includes its subordinate headings, ending at the next peer or parent.
            let next = starts.dropFirst(i + 1).first { $0.1 <= item.1 }
            let end = next?.2 ?? ReadingBoundary(chapter: max(0, chapters.count - 1), end: Int.max)
            entries.append(.init(title: item.0, level: item.1, start: item.2, end: end, href: item.3))
        }
        return Self(sourceHash: BookPreprocessor.contentHash(of: chapters), entries: entries)
    }
}

/// Evidence that an unreadable/background reader still reports the same page.
/// These values only validate reuse; they never become source offsets.
public struct ReadingPositionEvidence: Codable, Sendable, Equatable {
    public let raw: String?
    public let updated: TimeInterval?
    public let progress: Double
    public let pageIdentity: String?
    public init(_ context: ReadingContext) {
        raw = context.position?.raw; updated = context.position?.updated?.timeIntervalSince1970
        progress = context.book.progress; pageIdentity = context.pageIdentity
    }
    public func matches(_ context: ReadingContext, capturedAt: Date) -> Bool {
        let current = ReadingPositionEvidence(context)
        guard progress.isFinite, current.progress == progress, current.raw == raw,
              current.updated == updated, current.pageIdentity == pageIdentity else { return false }
        if let pageIdentity, !pageIdentity.isEmpty { return true }
        // Without visible page labels, only a recent observation with a database position is usable.
        let age = context.capturedAt.timeIntervalSince(capturedAt)
        return raw?.isEmpty == false && updated != nil && age >= 0 && age <= 15
    }
}

/// The last verified page of one conversation. No source text is persisted here.
public struct ReadingSnapshot: Codable, Sendable, Equatable {
    public let assetID: String
    public let sourceHash: String
    public let page: ReadingBoundary?
    public let chapterTitle: String
    public let progress: Double
    public let capturedAt: Date
    public var reused: Bool
    public var positionEvidence: ReadingPositionEvidence?
    public var reportedProgress: Double?

    public init(assetID: String, sourceHash: String, page: ReadingBoundary?, chapterTitle: String,
                progress: Double, capturedAt: Date = Date(), reused: Bool = false,
                positionEvidence: ReadingPositionEvidence? = nil, reportedProgress: Double? = nil) {
        self.assetID = assetID; self.sourceHash = sourceHash; self.page = page
        self.chapterTitle = chapterTitle; self.progress = progress; self.capturedAt = capturedAt; self.reused = reused
        self.positionEvidence = positionEvidence; self.reportedProgress = reportedProgress
    }
    public var label: String {
        guard page != nil else {
            if let reportedProgress { return "已识别本书 · 书库进度 \(String(format: "%.1f%%", reportedProgress * 100)) · 页末尚未定位，请将 Books 阅读窗口置于前台片刻" }
            return "尚未取得有效阅读位置 · 请在 Books 中打开本书，等待页末定位"
        }
        return "\(chapterTitle) · \(String(format: "%.1f%%", progress * 100)) · \(reused ? "沿用上次位置" : "已刷新") · \(capturedAt.formatted(date: .omitted, time: .standard))"
    }

    public static func resolve(assetID: String, map: BookMap, chapters: [BookPreprocessor.Chapter],
                               live: ReadingContext?, previous: Self?, shared: Self? = nil) throws -> Self {
        if let live, live.book.assetID == assetID, !live.visibleText.isEmpty {
            let located = try ScopedReading.resolve(chapters: chapters, current: nil, scope: .upToProgress, visible: live.visibleText)
            return Self(assetID: assetID, sourceHash: map.sourceHash, page: located.boundary,
                chapterTitle: map.entry(at: located.boundary)?.title ?? "未识别章节", progress: live.book.progress, capturedAt: live.capturedAt, positionEvidence: ReadingPositionEvidence(live))
        }
        let candidates = [previous, shared].compactMap { $0 }.filter {
            guard $0.assetID == assetID, $0.sourceHash == map.sourceHash, let page = $0.page,
                  page.end != Int.max, (try? ScopedReading.prefix(chapters: chapters, through: page, current: page.chapter)) != nil else { return false }
            if let live, live.book.assetID == assetID { return $0.positionEvidence?.matches(live, capturedAt: $0.capturedAt) == true }
            return true
        }
        // With no active content, preserve this chat's established position. New chats may inherit the book's verified position.
        let selected = live?.book.assetID == assetID ? candidates.max(by: { $0.capturedAt < $1.capturedAt }) : candidates.first
        if var selected { selected.reused = true; return selected }
        let progress = live?.book.assetID == assetID ? live?.book.progress : nil
        return Self(assetID: assetID, sourceHash: map.sourceHash, page: nil, chapterTitle: "尚未定位", progress: progress ?? 0, reportedProgress: progress)
    }
    public func identified(by assetID: String) -> Self {
        Self(assetID: assetID, sourceHash: sourceHash, page: page, chapterTitle: chapterTitle, progress: progress,
             capturedAt: capturedAt, reused: reused, positionEvidence: positionEvidence, reportedProgress: reportedProgress)
    }

    public func reading(chapters: [BookPreprocessor.Chapter], map: BookMap, scope: KnowledgeScope, statistics: BookStatistics? = nil) throws -> ScopedReading {
        guard map.sourceHash == sourceHash, BookPreprocessor.contentHash(of: chapters) == sourceHash else { throw ScopedReading.Failure.cannotLocatePage }
        if scope == .wholeBook { return try ScopedReading.resolve(chapters: chapters, current: page?.chapter, scope: scope, visible: []) }
        guard let page else { throw ScopedReading.Failure.cannotLocatePage }
        let statistics = statistics ?? (scope == .currentChapter ? BookStatistics.build(map: map, chapters: chapters) : nil)
        if let statistics, statistics.sourceHash != sourceHash { throw ScopedReading.Failure.cannotLocatePage }
        let boundary = scope == .currentChapter ? (statistics?.sections.first { $0.start < page && page <= $0.end }?.end ?? page) : page
        return try ScopedReading.prefix(chapters: chapters, through: boundary, current: page.chapter)
    }
}

public struct ReadingSummary: Codable, Sendable, Equatable {
    public let text: String
    public let sourceHash: String
    public let boundary: ReadingBoundary
    public let scope: KnowledgeScope
    public let generatedAt: Date
    public let coverageLabel: String?

    public init(text: String, sourceHash: String, boundary: ReadingBoundary, scope: KnowledgeScope, generatedAt: Date = Date(), coverageLabel: String? = nil) {
        self.text = text; self.sourceHash = sourceHash; self.boundary = boundary; self.scope = scope; self.generatedAt = generatedAt
        self.coverageLabel = coverageLabel
    }
    public func isAllowed(snapshot: ReadingSnapshot, reading: ScopedReading) -> Bool {
        sourceHash == snapshot.sourceHash && boundary <= reading.boundary
    }
}
