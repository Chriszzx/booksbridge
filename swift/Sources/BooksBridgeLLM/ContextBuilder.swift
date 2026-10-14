import BooksBridgeCore
import Foundation

/// 按知识范围组装送给 LLM 的上下文。
///
/// ## 关于"读到哪为止"的实现依据
///
/// 判断读者位置最直接的想法是用 CFI 尾部的字符偏移换算成章节内百分比。
/// **实测证明这不可行**：本机 53 条真实位置记录里，偏移与章节长度的比值
/// 均值 0.0059 而标准差 0.0237（标准差是均值的 4 倍），典型样本如
/// 「偏移 239 / 章节 39442」= 0.6%。原因是该偏移是相对 XPath 指向的
/// **那个文本节点**的，不是相对章节开头。
///
/// 因此这里采用与三档范围语义一致的边界：
/// - `upToProgress`  → 当前章**之前**的章节（不含当前章正文）
/// - `currentChapter`→ 当前章**及其之前**的章节
/// - `wholeBook`     → 全部章节
///
/// 这样三档之间的实际差别就是"是否包含当前章 → 是否包含后续章节"，
/// 与用户在界面上看到的说明一致，也不会因为不可靠的偏移估算给出错误的剧透边界。
///
/// ## 为什么除了范围还要做检索
///
/// 全书正文动辄十几万字，全塞进去既慢又贵。预处理产出的书籍说明已经压缩了
/// 全局理解，这里再按读者的问题检索出最相关的片段补上原文细节，
/// 兼顾"知道整本"与"引得到原文"。
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

        public struct Excerpt: Sendable {
            public let chapterIndex: Int
            public let href: String
            public let text: String
        }

        /// 拼成最终附在提问前的上下文块。
        public func render() -> String {
            var parts: [String] = []
            if !knowledge.isEmpty {
                parts.append("## 全书说明\n\(knowledge)")
            }
            if !excerpts.isEmpty {
                let body = excerpts.enumerated().map { index, excerpt in
                    "### 原文片段 \(index + 1)（第 \(excerpt.chapterIndex) 章）\n\(excerpt.text)"
                }.joined(separator: "\n\n")
                parts.append("## 相关原文\n\(body)")
            }
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
        visibleText: [String] = []
    ) -> BuiltContext {
        // 1) 按范围确定可用章节
        let usable = usableChapterRange(
            count: chapters.count,
            currentChapterIndex: currentChapterIndex,
            scope: scope
        )

        // 2) 检索相关片段
        var excerpts: [BuiltContext.Excerpt] = []
        var used = 0

        // 2a) 屏幕上可见的正文优先——它最贴近用户此刻的疑问
        if scope != .wholeBook, let index = currentChapterIndex,
           usable.contains(index), !visibleText.isEmpty {
            let joined = visibleText.joined(separator: "\n")
            let clipped = String(joined.prefix(excerptCharacters))
            if !clipped.isEmpty {
                excerpts.append(.init(
                    chapterIndex: index + 1,
                    href: chapters[index].href,
                    text: clipped
                ))
                used += clipped.count
            }
        }

        // 2b) 再按问题检索
        let remaining = max(maxCharacters - knowledge.count - used, 0)
        if remaining > 200 {
            let picked = search(
                question: question,
                chapters: chapters,
                within: usable,
                limit: maxExcerpts - excerpts.count
            )
            for hit in picked {
                let clipped = String(hit.text.prefix(excerptCharacters))
                guard used + clipped.count <= remaining else { break }
                excerpts.append(.init(
                    chapterIndex: hit.chapterIndex,
                    href: hit.href,
                    text: clipped
                ))
                used += clipped.count
            }
        }

        let description = describe(scope: scope, usable: usable, total: chapters.count)
        let context = BuiltContext(
            knowledge: knowledge,
            excerpts: excerpts,
            scope: scope,
            scopeDescription: description,
            characterCount: knowledge.count + used
        )
        return context
    }

    // MARK: - 范围

    /// 返回可用章节的下标范围（闭区间）。
    func usableChapterRange(count: Int, currentChapterIndex: Int?, scope: KnowledgeScope) -> ClosedRange<Int> {
        guard count > 0 else { return 0...0 }
        let last = count - 1
        guard let current = currentChapterIndex, (0...last).contains(current) else {
            // 没定位到位置时：整本书就是全书；其余两档保守地退化为"只给书籍说明"
            return scope == .wholeBook ? 0...last : 0...0
        }
        switch scope {
        case .upToProgress:
            // 不含当前章正文，避免读到一半的章节里后半部分剧透
            return 0...max(current - 1, 0)
        case .currentChapter:
            return 0...current
        case .wholeBook:
            return 0...last
        }
    }

    private func describe(scope: KnowledgeScope, usable: ClosedRange<Int>, total: Int) -> String {
        switch scope {
        case .wholeBook:
            return "整本书（共 \(total) 章）"
        case .currentChapter:
            return "第 1–\(usable.upperBound + 1) 章（含当前整章）"
        case .upToProgress:
            let upTo = usable.upperBound + 1
            return upTo <= 0 ? "尚未进入正文" : "第 1–\(upTo) 章（已读范围）"
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
        within range: ClosedRange<Int>,
        limit: Int
    ) -> [Hit] {
        guard limit > 0, !question.isEmpty, !chapters.isEmpty else { return [] }
        let terms = Self.queryTerms(from: question)
        guard !terms.isEmpty else { return [] }

        var hits: [Hit] = []
        for index in range where index < chapters.count {
            let chapter = chapters[index]
            for paragraph in chapter.text.components(separatedBy: "\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
                // 过短的段落（标题、页码）区分度低
                guard trimmed.count >= 20 else { continue }
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
        let chinese = question.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }
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
