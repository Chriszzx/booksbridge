import XCTest

@testable import BooksBridgeLLM

/// 知识范围与上下文组装。
///
/// 这组测试守住的是**剧透边界**——三档范围的差别必须与界面上给用户的
/// 说明一致，否则用户以为"不会剧透"却被透了后面的情节。
final class ContextBuilderTests: XCTestCase {
    private let builder = ContextBuilder()

    func testLargeBudgetIncludesEntireAllowedSourceBeyondTwelveSnippets() {
        let source = chapters((0..<20).map { "区段\($0)开始" + String(repeating: "连续故事", count: 1000) + "区段\($0)结束" })
        let result = ContextBuilder(maxCharacters: 200000).build(knowledge: "", chapters: source,
            currentChapterIndex: 19, scope: .upToProgress, question: "开头到现在讲了什么", preScoped: true)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.excerpts.map(\.text), source.map(\.text))
        XCTAssertGreaterThan(result.characterCount, 70000)
        XCTAssertLessThanOrEqual(result.render().count, 200000)
        XCTAssertFalse(result.render().contains("第 4 章"))
    }

    func testSmallBudgetOverviewCoversBeginningMiddleEndAndLabelsGaps() {
        let source = chapters((0..<5).map { "开始\($0)" + String(repeating: "内容", count: 3000) + "结束\($0)" })
        let result = ContextBuilder(maxCharacters: 4000).build(knowledge: "", chapters: source,
            currentChapterIndex: 4, scope: .upToProgress, question: "开头到现在讲了什么", preScoped: true)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.excerpts.map(\.chapterIndex), [1,2,3,4,5])
        XCTAssertTrue(result.render().contains("开始0"))
        XCTAssertTrue(result.render().contains("结束4"))
        XCTAssertTrue(result.render().contains("省略"))
        XCTAssertLessThanOrEqual(result.render().count, 4000)
    }

    // MARK: - 范围边界

    func testRestrictedScopesNeverIncludeWholeBookKnowledge() {
        for scope in [KnowledgeScope.upToProgress, .currentChapter] {
            let context = builder.build(knowledge: "结局秘密", chapters: chapters([String(repeating: "故事正文", count: 20)]),
                currentChapterIndex: 0, scope: scope, question: "故事")
            XCTAssertFalse(context.render().contains("结局秘密"))
        }
    }

    func testFirstChapterAndUnknownPositionDoNotRetrieveUnreadText() {
        let books = chapters([String(repeating: "结局秘密", count: 20)])
        for position: Int? in [0, nil] {
            let context = builder.build(knowledge: "结局秘密", chapters: books,
                currentChapterIndex: position, scope: .upToProgress, question: "结局")
            XCTAssertTrue(context.excerpts.isEmpty)
            XCTAssertTrue(context.knowledge.isEmpty)
        }
    }

    func testRangeExcludesCurrentChapterForProgressScope() {
        // 第 5 章在读（下标 4）→ 已读范围不含当前章
        let range = builder.usableChapterRange(count: 10, currentChapterIndex: 4, scope: .upToProgress)
        XCTAssertEqual(range, 0..<4, "读到这为止不应包含正在读的这一章")
    }

    func testRangeIncludesCurrentChapterForChapterScope() {
        let range = builder.usableChapterRange(count: 10, currentChapterIndex: 4, scope: .currentChapter)
        XCTAssertEqual(range, 0..<5, "整章档应包含当前章")
    }

    func testRangeIsWholeBookForWholeBookScope() {
        let range = builder.usableChapterRange(count: 10, currentChapterIndex: 4, scope: .wholeBook)
        XCTAssertEqual(range, 0..<10)
    }

    func testProgressScopeAtFirstChapterStaysInBounds() {
        // 刚开书时"当前章之前"为空，不能产生负数下标
        let range = builder.usableChapterRange(count: 10, currentChapterIndex: 0, scope: .upToProgress)
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 0)
    }

    func testRangesAreProgressive() {
        // 三档必须是单调扩张的：读到这 ⊆ 整章 ⊆ 整本
        let count = 20, current = 8
        let progress = builder.usableChapterRange(count: count, currentChapterIndex: current, scope: .upToProgress)
        let chapter = builder.usableChapterRange(count: count, currentChapterIndex: current, scope: .currentChapter)
        let whole = builder.usableChapterRange(count: count, currentChapterIndex: current, scope: .wholeBook)
        XCTAssertLessThan(progress.upperBound, chapter.upperBound)
        XCTAssertLessThan(chapter.upperBound, whole.upperBound)
    }

    func testUnknownPositionDoesNotLeakWholeBook() {
        // 定位不到位置时，前两档必须保守，不能退化成"给全书"
        XCTAssertEqual(builder.usableChapterRange(count: 10, currentChapterIndex: nil, scope: .upToProgress).upperBound, 0)
        XCTAssertEqual(builder.usableChapterRange(count: 10, currentChapterIndex: nil, scope: .currentChapter).upperBound, 0)
        XCTAssertEqual(builder.usableChapterRange(count: 10, currentChapterIndex: nil, scope: .wholeBook).upperBound, 10)
    }

    func testEmptyChapterListDoesNotCrash() {
        XCTAssertEqual(builder.usableChapterRange(count: 0, currentChapterIndex: nil, scope: .upToProgress), 0..<0)
    }

    // MARK: - 检索

    private func chapters(_ texts: [String]) -> [BookPreprocessor.Chapter] {
        texts.enumerated().map {
            BookPreprocessor.Chapter(spineIndex: $0.offset + 1, href: "ch\($0.offset + 1).xhtml", text: $0.element)
        }
    }

    func testSearchFindsRelevantParagraph() {
        let books = chapters([
            "第一章开头。这里讲的是完全无关的农业技术改良与灌溉系统建设等内容。",
            "第二章里提到了一个关键人物叫做林振声，他是整件事的核心推动者与决策人。",
            "第三章继续发展，讨论了许多别的话题比如气象观测与地质勘探的方法论。",
        ])
        let hits = builder.search(question: "林振声是谁", chapters: books, within: 0..<3, limit: 3)
        XCTAssertFalse(hits.isEmpty, "应检索到含关键词的段落")
        XCTAssertEqual(hits.first?.chapterIndex, 2, "命中的应是第二章")
    }

    func testSearchRespectsRangeBoundary() {
        let books = chapters([
            "第一章讨论了基础概念的定义与边界条件的说明以及相关历史沿革。",
            "第二章出现了关键术语「熵增困境」，并在后续反复使用这个说法。",
        ])
        // 把范围限制在第一章，就不该检索到第二章的内容
        let hits = builder.search(question: "熵增困境", chapters: books, within: 0..<1, limit: 3)
        XCTAssertTrue(hits.isEmpty, "范围之外的内容不得被检索到，否则会剧透")
    }

    func testSearchReturnsEmptyForUnrelatedQuestion() {
        let books = chapters(["这一章讨论灌溉渠道的坡度设计与材料选择等工程问题。"])
        XCTAssertTrue(builder.search(question: "量子纠缠", chapters: books, within: 0..<1, limit: 3).isEmpty)
    }

    func testQueryTermsExtractChineseBigrams() {
        let terms = BookPreprocessor.contentHash(of: "") // 触发类型可用性，无实际用途
        _ = terms
        let extracted = ContextBuilder.queryTerms(from: "林振声是谁")
        XCTAssertTrue(extracted.contains("林振"), "中文应切成 2-gram")
        XCTAssertTrue(extracted.contains("振声"))
    }

    func testQueryTermsKeepEnglishWords() {
        let terms = ContextBuilder.queryTerms(from: "explain the CFI parser")
        XCTAssertTrue(terms.contains("explain"))
        XCTAssertTrue(terms.contains("parser"))
    }

    func testLongerTermsScoreHigher() {
        let paragraph = "这里提到了灌溉与灌溉系统两个说法。"
        let short = ContextBuilder.score(paragraph: paragraph, terms: ["灌溉"])
        let long = ContextBuilder.score(paragraph: paragraph, terms: ["灌溉系统"])
        XCTAssertGreaterThan(long, short, "长词更有区分度，权重应更高")
    }

    // MARK: - 组装

    func testBuildIncludesKnowledgeAndExcerpts() {
        let books = chapters([
            "第一章讲述了主人公的出身背景与家庭环境，以及他所处的那个时代的社会状况。",
            "第二章记录了林振声如何一步步推动改革，过程曲折且充满争议与反复。",
            "第三章收束全书，交代了改革的结果与后续影响，以及作者的评价与反思。",
        ])
        let built = builder.build(
            knowledge: "这是一本关于改革的书。",
            chapters: books,
            currentChapterIndex: 1,
            scope: .currentChapter,
            question: "林振声做了什么"
        )
        XCTAssertTrue(built.knowledge.isEmpty, "受限范围不能混入全书说明")
        XCTAssertFalse(built.excerpts.isEmpty, "应带回原文片段")
        XCTAssertFalse(built.render().contains("全书说明"))
        XCTAssertTrue(built.render().contains("相关原文"))
    }

    func testVisibleTextIsPreferredAsFirstExcerpt() {
        let books = chapters([
            "第一章的内容足够长以便通过长度过滤，这里继续补充一些文字凑够二十个字符以上。",
            "第二章出现了林振声这个名字以及他的主张，还有当时的舆论反应与后续演变过程。",
        ])
        let visible = "第二章出现了林振声这个名字以及他的主张"
        let built = builder.build(
            knowledge: "",
            chapters: books,
            currentChapterIndex: 1,
            scope: .currentChapter,
            question: "这句什么意思",
            visibleText: [visible]
        )
        XCTAssertEqual(built.currentPageText, visible, "完整原文仍需单独标记当前页位置")
    }

    func testExcerptsStayWithinRangeForProgressScope() {
        let books = chapters([
            "第一章讨论了非常独特的概念叫做「甲概念」，这个说法在全书中只出现一次。",
            "第二章又一次提到「甲概念」，并给出了完全不同的解释与另一层含义。",
        ])
        let built = builder.build(
            knowledge: "",
            chapters: books,
            currentChapterIndex: 1,
            scope: .upToProgress,
            question: "甲概念"
        )
        // 当前在下标 1，"读到这为止"只允许下标 0
        XCTAssertTrue(
            built.excerpts.allSatisfy { $0.chapterIndex == 1 },
            "不应带出当前章及之后的内容，实际: \(built.excerpts.map(\.chapterIndex))"
        )
    }

    func testCharacterBudgetIsRespected() {
        let long = String(repeating: "这是一段足够长的正文内容用于测试字符预算限制是否生效。", count: 200)
        let books = chapters([long, long, long])
        let tight = ContextBuilder(maxCharacters: 3_000, maxExcerpts: 4, excerptCharacters: 1_200)
        let built = tight.build(
            knowledge: "", chapters: books, currentChapterIndex: 2,
            scope: .wholeBook, question: "测试"
        )
        XCTAssertLessThanOrEqual(
            built.characterCount, 3_000 + 1_200,
            "带上的原文总量应受预算约束（知识部分为空）"
        )
    }

    func testScopeDescriptionMatchesRange() {
        let books = chapters(["甲", "乙", "丙"])
        let whole = builder.build(knowledge: "", chapters: books, currentChapterIndex: 0, scope: .wholeBook, question: "")
        XCTAssertTrue(whole.scopeDescription.contains("整本书"))

        let progress = builder.build(knowledge: "", chapters: books, currentChapterIndex: 2, scope: .upToProgress, question: "")
        XCTAssertTrue(progress.scopeDescription.contains("已读"), "实际: \(progress.scopeDescription)")
    }
}

/// 长书分块与内容指纹。
final class BookPreprocessorTests: XCTestCase {
    private func chapter(_ text: String, spine: Int = 1) -> BookPreprocessor.Chapter {
        BookPreprocessor.Chapter(spineIndex: spine, href: "c\(spine).xhtml", text: text)
    }

    func testShortBookStaysInOneChunk() {
        let chapters = (1...5).map { chapter(String(repeating: "字", count: 1000), spine: $0) }
        let chunks = BookPreprocessor.split(chapters: chapters, maxCharacters: 20_000)
        XCTAssertEqual(chunks.count, 1, "总量未超限时不该分块")
    }

    func testLongBookSplitsAtChapterBoundaries() {
        // 每章 8000 字，上限 20000 → 每块最多两章
        let chapters = (1...10).map { chapter(String(repeating: "字", count: 8_000), spine: $0) }
        let chunks = BookPreprocessor.split(chapters: chapters, maxCharacters: 20_000)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 20_000, "每块不得超过上限")
        }
        // 不应丢章节：把各块的章节拼回去应与原始章节集合一致
        // （总字符数会比原文略多，因为块内章节用 \n\n 连接）
        let total = chunks.map(\.text.count).reduce(0,+)
        XCTAssertGreaterThanOrEqual(total, 80_000, "不得丢内容")
        XCTAssertLessThan(total, 80_000 + chunks.count * 2 + 2, "只允许连接符带来的额外字符")
    }

    func testOversizedSingleChapterSplitsByParagraph() {
        let paragraphs = (1...50).map { "第\($0)段" + String(repeating: "文", count: 500) }
        let chunks = BookPreprocessor.split(
            chapters: [chapter(paragraphs.joined(separator: "\n"))],
            maxCharacters: 5_000
        )
        XCTAssertGreaterThan(chunks.count, 1, "单章超长应在章内切分")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 5_000 + 600, "按段落切分可能略超，但不应失控")
        }
    }

    func testSplitPreservesAllText() {
        // 每章内容唯一，便于验证既不丢也不重
        let chapters = (1...7).map { index in
            chapter(String(repeating: "内", count: 2_999) + "章\(index)", spine: index)
        }
        let chunks = BookPreprocessor.split(chapters: chapters, maxCharacters: 10_000)
        let joined = chunks.map(\.text).joined(separator: "\n")
        for index in 1...7 {
            XCTAssertTrue(joined.contains("章\(index)"), "第 \(index) 章的结尾标记应保留")
        }
        // 每章恰好出现一次（结尾标记唯一）
        for index in 1...7 {
            let occurrences = joined.components(separatedBy: "章\(index)").count - 1
            XCTAssertEqual(occurrences, 1, "第 \(index) 章不应重复")
        }
    }

    func testContentHashMatchesKnownSHA256AcrossProcesses() {
        XCTAssertEqual(BookPreprocessor.contentHash(of: "abc"),
            "sha256-v1:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testWriterAndReaderUseSameChapterFingerprint() {
        let parts = [chapter("第一章正文"), chapter("第二章正文", spine: 2)]
        XCTAssertEqual(BookPreprocessor.contentHash(of: parts),
                       BookPreprocessor.contentHash(of: parts.map(\.text).joined(separator: "\n\n")))
    }

    func testContentHashIsStable() {
        let text = "一段用于指纹测试的正文内容。"
        XCTAssertEqual(BookPreprocessor.contentHash(of: text), BookPreprocessor.contentHash(of: text))
    }

    func testContentHashDetectsLengthChange() {
        XCTAssertNotEqual(
            BookPreprocessor.contentHash(of: "短文本"),
            BookPreprocessor.contentHash(of: "短文本加上更多内容")
        )
    }

    /// 指纹的用途是"发现这本书换了或变了"，不是做校验和。
    ///
    /// 因此测试聚焦真实会发生的场景：换书、截断、首尾改动。
    /// 采样式指纹无法发现"40 万字里恰好改一个非采样点的字"——这是刻意的取舍，
    /// 用常数开销换取够用的失效判断；真要逐字校验应改用完整哈希。
    func testContentHashDetectsHeadChange() {
        let base = String(repeating: "甲乙丙丁戊己庚辛", count: 5_000)
        let changed = "Ｘ" + String(base.dropFirst())
        XCTAssertNotEqual(BookPreprocessor.contentHash(of: base), BookPreprocessor.contentHash(of: changed))
    }

    func testContentHashDetectsTailChange() {
        let base = String(repeating: "甲乙丙丁戊己庚辛", count: 5_000)
        let changed = String(base.dropLast()) + "Ｘ"
        XCTAssertNotEqual(BookPreprocessor.contentHash(of: base), BookPreprocessor.contentHash(of: changed))
    }

    func testContentHashDetectsTruncation() {
        // 最常见的情况：书被替换或截断
        let base = String(repeating: "甲乙丙丁戊己庚辛", count: 5_000)
        XCTAssertNotEqual(
            BookPreprocessor.contentHash(of: base),
            BookPreprocessor.contentHash(of: String(base.prefix(30_000)))
        )
    }

    /// 完整 SHA-256 也必须覆盖正文内部的单个字符变化。
    /// 缓存失效要的是"这本书还是不是原来那本"，首尾与长度已足够覆盖换书与截断。
    /// 测试写成断言"允许漏判"，以免将来有人误以为它是校验和。
    func testContentHashDetectsInteriorChange() {
        let base = String(repeating: "甲乙丙丁戊己庚辛", count: 5_000)
        var changed = Array(base)
        // 挑一个确定不在采样点上的位置
        changed[11] = "改"
        let before = BookPreprocessor.contentHash(of: base)
        let after = BookPreprocessor.contentHash(of: String(changed))
        XCTAssertNotEqual(before, after, "完整指纹应发现内部字符改动")
    }

    func testContentHashHandlesEmptyAndTinyInput() {
        XCTAssertFalse(BookPreprocessor.contentHash(of: "").isEmpty)
        // 短文本必须仍有区分度：早期实现只看首字符，"甲"与"乙"会撞哈希
        XCTAssertNotEqual(BookPreprocessor.contentHash(of: "甲"), BookPreprocessor.contentHash(of: "乙"))
        XCTAssertNotEqual(BookPreprocessor.contentHash(of: "甲乙"), BookPreprocessor.contentHash(of: "甲丙"))
        XCTAssertNotEqual(BookPreprocessor.contentHash(of: "ab"), BookPreprocessor.contentHash(of: "ac"))
    }
}

/// 知识缓存。
final class BookKnowledgeStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("booksbridge-knowledge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(hash: String = "abc123") -> BookKnowledge {
        BookKnowledge(
            readme: "# 说明\n这是一本书。",
            contentHash: hash,
            model: "deepseek-flash",
            characterCount: 12_345,
            chapterCount: 10,
            chunkCount: 2,
            promptTokens: 100,
            completionTokens: 50
        )
    }

    func testRoundTrip() async {
        let store = BookKnowledgeStore(directory: directory)
        await store.save(sample(), assetID: "A1")

        let loaded = await store.cached(assetID: "A1")
        XCTAssertEqual(loaded?.readme, "# 说明\n这是一本书。")
        XCTAssertEqual(loaded?.contentHash, "abc123")
        XCTAssertEqual(loaded?.chapterCount, 10)
    }

    func testMissingReturnsNil() async {
        let store = BookKnowledgeStore(directory: directory)
        let loaded = await store.cached(assetID: "不存在")
        XCTAssertNil(loaded)
    }

    func testRemove() async {
        let store = BookKnowledgeStore(directory: directory)
        await store.save(sample(), assetID: "A1")
        await store.remove(assetID: "A1")
        let loaded = await store.cached(assetID: "A1")
        XCTAssertNil(loaded)
    }

    func testListsKnownIDs() async {
        let store = BookKnowledgeStore(directory: directory)
        await store.save(sample(), assetID: "B2")
        await store.save(sample(), assetID: "A1")
        let ids = await store.knownAssetIDs()
        XCTAssertEqual(ids, ["A1", "B2"])
    }

    func testUnsafeAssetIDIsSanitized() async {
        // 防止用 ../ 之类拼出越界路径
        let store = BookKnowledgeStore(directory: directory)
        await store.save(sample(), assetID: "../../evil")
        let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files?.count, 1)
        XCTAssertFalse(files?.contains { $0.contains("..") } ?? true, "文件名不得包含路径穿越片段")
    }
}
