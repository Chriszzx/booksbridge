import Foundation

/// Tools receive only the permitted prefix, never the full book or a file path.
public struct ReadingTools: Sendable {
    public let reading: ScopedReading
    public init(reading: ScopedReading) { self.reading = reading }

    public func read(chapter: Int, offset: Int, length: Int) -> String {
        guard reading.chapters.indices.contains(chapter), offset >= 0, length > 0 else { return "读取请求超出允许范围" }
        let text = reading.chapters[chapter].text
        guard offset < text.count else { return "已到本轮允许读取的末尾" }
        return "文档区段 \(chapter + 1)（来源 \(reading.chapters[chapter].href)），字符 \(offset)：\n" + String(text.dropFirst(offset).prefix(min(length, 2400)))
    }

    public func search(_ query: String) -> String {
        let builder = ContextBuilder(maxCharacters: 3000, maxExcerpts: 3, excerptCharacters: 900)
        return builder.build(knowledge: "", chapters: reading.chapters,
            currentChapterIndex: reading.currentChapter, scope: .wholeBook, question: query, preScoped: true).render()
    }

    public var catalog: String {
        reading.chapters.enumerated().map { "区段ID \($0.offset) [\($0.element.href)]: \($0.element.text.count) 字" }.joined(separator: "; ")
    }

    public func execute(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String else { return nil }
        switch tool {
        case "read":
            guard let chapter = object["chapter"] as? Int, let offset = object["offset"] as? Int else { return nil }
            return read(chapter: chapter, offset: offset, length: object["length"] as? Int ?? 1800)
        case "search": return search(String((object["query"] as? String ?? "").prefix(300)))
        default: return nil
        }
    }
}
