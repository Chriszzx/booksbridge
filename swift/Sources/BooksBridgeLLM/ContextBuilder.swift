import BooksBridgeCore
import Foundation

/// 按知识范围组装送给 LLM 的上下文。
///
/// 原文先由 ScopedReading 裁到权限边界，再检索；磁盘不保存正文副本。
public struct ContextBuilder: Sendable {
    public struct BuiltContext: Sendable {
        /// 送进 system 的书籍知识（预处理说明）。
        public let knowledge: String
        /// 随问题一起送去的原文片段，已标注出处。
        public let excerpts: [Excerpt]
        /// 本上下文使用的知识范围。直接带上枚举值，避免下游靠描述字符串反推。
        public let scope: KnowledgeScope
        /// 人类可读的范围描述，用于在界面上与消息里标注。
        public let scopeDescription: String
        /// 组装后的字符数，用于成本可见。
        public let characterCount: Int
        public let isComplete: Bool
        public let currentPageText: String

        public struct Excerpt: Sendable {
            public let chapterIndex: Int
            public let href: String
            public let text: String
        }

        /// 拼成最终附在提问前的上下文块。
        public func render() -> String {
            var parts: [String] = [isComplete
                ? "以下是本轮允许范围内的完整原文，按原书顺序排列。文档区段编号不是书中的章节编号。"
                : "以下是允许范围内的选段，不代表完整覆盖。选段之间可能有省略，不要把不相邻事件连成连续情节，也不要把区段编号当作书中章节编号。"]
            if !knowledge.isEmpty {
                parts.append("## 全书说明\n\(knowledge)")
            }
            if !excerpts.isEmpty {
                let body = excerpts.enumerated().map { index, excerpt in
                    "### 原文片段 \(index + 1)（文档区段 \(excerpt.chapterIndex)，来源 \(excerpt.href)）\n\(excerpt.text)"
                }.joined(separator: "\n\n")
                parts.append("## 相关原文\n\(body)")
            }
            if !currentPageText.isEmpty { parts.append("## 当前页定位（与上方原文重复，仅标记读者位置）\n" + currentPageText) }
            return parts.joined(separator: "\n\n")
        }
    }

    /// 单次请求允许的上下文上限（字符）。超出则裁剪检索片段。
    public var maxCharacters: Int
    /// 最多带几段原文。
    public var maxExcerpts: Int
    /// 每段原文的字符数上限。
    public var excerptCharacters: Int

    public init(maxCharacters: Int = 12_000, maxExcerpts: Int = 4, excerptCharacters: Int = 1_200) {
        self.maxCharacters = maxCharacters
        self.maxExcerpts = maxExcerpts
        self.excerptCharacters = excerptCharacters
    }

    /// 组装上下文。
    ///
    /// - Parameters:
    ///   - knowledge: 预处理产出的书籍说明。为空时退化为"只有原文片段"。
    ///   - chapters: 按 spine 顺序的章节。
    ///   - currentChapterIndex: 当前阅读位置所在章节在 `chapters` 中的下标。nil 表示未定位到。
    ///   - scope: 知识范围。
    ///   - question: 用户的问题，用于检索相关片段。
    ///   - visibleText: 屏幕上当前可见的正文，作为最贴近的原文优先带上。
    public func build(
        knowledge: String,
        chapters: [BookPreprocessor.Chapter],
        currentChapterIndex: Int?,
        scope: KnowledgeScope,
        question: String,
        visibleText: [String] = [],
        preScoped: Bool = false
    ) -> BuiltContext {
        // 全书摘要只供全书范围使用，受限范围只检索允许的原文。
        let knowledge = scope == .wholeBook ? String(knowledge.prefix(max(0, maxCharacters / 3))) : ""
        // 1) 按范围确定可用章节
        let usable = preScoped ? 0..<chapters.count : usableChapterRange(
            count: chapters.count,
            currentChapterIndex: currentChapterIndex,
            scope: scope
        )

        let description = preScoped && scope == .upToProgress
            ? "书首至当前页末尾（含当前章已读部分）"
            : describe(scope: scope, usable: usable, total: chapters.count)
        let page = visibleText.filter { fragment in
            let anchor = ScopedReading.normalized(fragment)
            return !anchor.isEmpty && usable.contains { ScopedReading.normalized(chapters[$0].text).contains(anchor) }
        }.joined(separator: "\n")
        let currentPage = String(page.suffix(min(1400, max(0, maxCharacters / 5))))
        let all = usable.map { BuiltContext.Excerpt(chapterIndex: $0 + 1, href: chapters[$0].href, text: chapters[$0].text) }
        let complete = BuiltContext(knowledge: "", excerpts: all, scope: scope, scopeDescription: description,
            characterCount: all.reduce(0) { $0 + $1.text.count }, isComplete: true, currentPageText: currentPage)
        // Respect the configured budget, including source labels. Do not cap full
        // reading at an unrelated number of snippets when the source fits.
        if !all.isEmpty, complete.render().count <= maxCharacters { return complete }

        // 2) 检索相关片段
        var excerpts: [BuiltContext.Excerpt] = []
        var used = 0

        let contentBudget = max(0, maxCharacters - knowledge.count - currentPage.count - 400 - usable.count * 90)
        let broad = ["开头", "到现在", "到这里", "梳理", "概括", "总结", "讲了什么", "发生了什么", "主线"].contains { question.contains($0) }
        if broad {
            // Spread coverage over the entire allowed range instead of only the
            // latest chapter tails. Explicit omissions prevent false continuity.
            let total = max(1, usable.reduce(0) { $0 + chapters[$1].text.count })
            for i in usable {
                let text = chapters[i].text
                let allowance = min(text.count, contentBudget * text.count / total)
                guard allowance > 0 else { continue }
                let selected: String
                if allowance >= text.count { selected = text }
                else {
                    let part = max(1, (allowance - 50) / 3)
                    let middle = max(0, text.count / 2 - part / 2)
                    selected = String(text.prefix(part)) + "\n[中间原文省略]\n" + String(text.dropFirst(middle).prefix(part))
                        + "\n[中间原文省略]\n" + String(text.suffix(part))
                }
                excerpts.append(.init(chapterIndex: i + 1, href: chapters[i].href, text: selected))
                used += selected.count
            }
        } else {
            let limit = max(maxExcerpts, contentBudget / max(1, excerptCharacters))
            var picked = search(question: question, chapters: chapters, within: usable, limit: limit)
            if picked.isEmpty {
                for i in usable.reversed() {
                    picked.append(Hit(chapterIndex: i + 1, href: chapters[i].href,
                        text: String(chapters[i].text.suffix(excerptCharacters)), score: 0))
                }
            }
            for hit in picked {
                let remaining = contentBudget - used
                guard remaining > 0 else { break }
                let clipped = String(hit.text.prefix(remaining))
                excerpts.append(.init(chapterIndex: hit.chapterIndex, href: hit.href, text: clipped))
                used += clipped.count
            }
            excerpts.sort { a, b in
                if a.chapterIndex != b.chapterIndex { return a.chapterIndex < b.chapterIndex }
                let source = chapters[a.chapterIndex - 1].text
                return (source.range(of: a.text)?.lowerBound ?? source.endIndex) < (source.range(of: b.text)?.lowerBound ?? source.endIndex)
            }
        }

        func result() -> BuiltContext { BuiltContext(
            knowledge: knowledge,
            excerpts: excerpts,
            scope: scope,
            scopeDescription: description,
            characterCount: knowledge.count + excerpts.reduce(0) { $0 + $1.text.count }, isComplete: false, currentPageText: currentPage
        ) }
        while result().render().count > maxCharacters, let last = excerpts.popLast() {
            let overflow = result().render().count + last.text.count + last.href.count + 90 - maxCharacters
            let count = max(0, last.text.count - max(1, overflow))
            if count > 0 { excerpts.append(.init(chapterIndex: last.chapterIndex, href: last.href, text: String(last.text.prefix(count)))) }
        }
        return result()
    }

    // MARK: - 范围

    /// 返回可用章节下标的半开区间，可表达空范围。
    func usableChapterRange(count: Int, currentChapterIndex: Int?, scope: KnowledgeScope) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let last = count - 1
        guard let current = currentChapterIndex, (0...last).contains(current) else {
            // 定位未知时受限范围不返回任何章节，更不能使用全书说明。
            return scope == .wholeBook ? 0..<count : 0..<0
        }
        switch scope {
        case .upToProgress:
            // 不含当前章正文，避免读到一半的章节里后半部分剧透
            return 0..<current
        case .currentChapter:
            return 0..<(current + 1)
        case .wholeBook:
            return 0..<count
        }
    }

    private func describe(scope: KnowledgeScope, usable: Range<Int>, total: Int) -> String {
        switch scope {
        case .wholeBook:
            return "整本书（共 \(total) 个文档区段）"
        case .currentChapter:
            return "书首至当前章末尾"
        case .upToProgress:
            let upTo = usable.upperBound
            return upTo <= 0 ? "无已完成章节，仅使用当前可见正文" : "此前已读区段及当前可见正文"
        }
    }

    // MARK: - 检索

    struct Hit {
        let chapterIndex: Int
        let href: String
        let text: String
        let score: Double
    }

    /// 无向量的关键词检索。
    ///
    /// 为什么不上向量检索：这本书是单本、单次会话的规模（十几万字），
    /// 朴素的关键词打分已经够用，而且零依赖、零额外成本、结果可解释。
    /// 若将来要跨书检索再引入嵌入。
    ///
    /// 打分策略：
    /// - 把问题切成 2-gram 与英文单词作为查询词
    /// - 对每个段落统计命中词数，并按词长加权（长词更有区分度）
    /// - 位置越靠后的段落给极小加成（同一关键词多次出现时优先靠后的，更贴近当前进度）
    func search(
        question: String,
        chapters: [BookPreprocessor.Chapter],
        within range: Range<Int>,
        limit: Int
    ) -> [Hit] {
        guard limit > 0, !question.isEmpty, !chapters.isEmpty else { return [] }
        let terms = Self.queryTerms(from: question)
        guard !terms.isEmpty else { return [] }

        var hits: [Hit] = []
        for index in range where index < chapters.count {
            let chapter = chapters[index]
            for paragraph in Self.chunks(chapter.text, size: max(200, excerptCharacters)) {
                let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
                // 过短的段落（标题、页码）区分度低
                guard !trimmed.isEmpty else { continue }
                let score = Self.score(paragraph: trimmed, terms: terms)
                guard score > 0 else { continue }
                hits.append(Hit(chapterIndex: index + 1, href: chapter.href, text: trimmed, score: score))
            }
        }

        // 分数优先；同分时取更靠后的（更接近读者当前进度）
        hits.sort {
            $0.score == $1.score ? $0.chapterIndex > $1.chapterIndex : $0.score > $1.score
        }
        return Array(hits.prefix(limit))
    }

    static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(start, offsetBy: max(1, size - 100), limitedBy: text.endIndex) ?? text.endIndex
        }
        return result
    }

    /// 从问题里抽出查询词：中文用 2-gram，英文/数字用整词。
    static func queryTerms(from question: String) -> [String] {
        var terms: [String] = []
        // 英文与数字整词
        for token in question.components(separatedBy: CharacterSet.alphanumerics.inverted) {
            if token.count >= 2, token.rangeOfCharacter(from: .letters) != nil {
                terms.append(token.lowercased())
            }
        }
        // 中文 2-gram：汉字连续段上滑窗
        let chinese = question.unicodeScalars.filter { (0x4E00..<0x9FFF).contains($0.value) }
        if chinese.count >= 2 {
            let scalars = Array(chinese)
            for i in 0..<(scalars.count - 1) {
                terms.append(String(String.UnicodeScalarView(scalars[i...i + 1])))
            }
        }
        // 去重，长词优先
        return Array(Set(terms)).sorted { $0.count > $1.count }
    }

    static func score(paragraph: String, terms: [String]) -> Double {
        let haystack = paragraph.lowercased()
        var total = 0.0
        for term in terms {
            let occurrences = haystack.components(separatedBy: term).count - 1
            guard occurrences > 0 else { continue }
            // 长词权重更高；出现次数做对数压缩，避免单一高频词主导
            total += Double(term.count) * (1 + log(Double(occurrences)))
        }
        return total
    }
}
