import BooksBridgeCore
import Foundation
import CryptoKit

/// 把整本书交给 LLM 做一次预处理，产出后续提问用的「书籍说明」。
///
/// 为什么要预处理而不是每次提问都塞全文：
/// 一本 10 万字的书约 15 万 token，每次提问都带上既慢又贵。
/// 预处理把"整本书的理解"压缩成一份结构化说明（几 k token），
/// 之后每次提问带上它就够了；需要原文细节时再按范围补检索片段。
///
/// 长书走 map-reduce：先分块各自摘要（map），再把各块摘要汇总成总说明（reduce）。
/// 短书直接一次调用，省一半成本。
public struct BookPreprocessor: Sendable {
    /// 单次请求能塞下的正文字符数上限。
    ///
    /// 取值考虑：中文大致 1 字 ≈ 1.5~2 token，24 万字符已接近模型上下文上限，
    /// 因此 6 万字符留足余量（约 10 万 token 输入）。超过就分块。
    public static let singlePassLimit = 60_000
    /// map 阶段每块的字符数。
    public static let chunkSize = 20_000

    public enum Progress: Sendable {
        case started(chunkCount: Int)
        case chunkDone(index: Int, total: Int)
        case reducing
        case finished(BookKnowledge)
    }

    private let client: ChatClient
    private let model: String

    public init(client: ChatClient, model: String) {
        self.client = client
        self.model = model
    }

    /// 读取一本书的正文并产出知识说明。
    ///
    /// - Parameters:
    ///   - book: 书目信息（用于提示词里的书名作者）。
    ///   - epub: 已解析的 EPUB。非 EPUB（如 PDF）暂不支持。
    ///   - onProgress: 进度回调，用于界面上显示"正在读第几块"。
    public func process(
        book: Book,
        epub: EpubDocument,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> BookKnowledge {
        let chapters = Self.extractChapters(epub: epub)
        let fullText = chapters.map(\.text).joined(separator: "\n\n")
        let hash = Self.contentHash(of: fullText)

        let chunks = Self.split(chapters: chapters, maxCharacters: Self.chunkSize)
        onProgress?(.started(chunkCount: chunks.count))

        var promptTokens = 0
        var completionTokens = 0

        let readme: String
        if fullText.count <= Self.singlePassLimit {
            // 短书：一次调用，直接产出成品
            let (text, usage) = try await client.complete(
                model: model,
                messages: [
                    .system(Self.systemPrompt),
                    .user(Self.buildSinglePassPrompt(book: book, text: fullText)),
                ],
                thinking: .disabled,
                temperature: 0.3
            )
            readme = text
            promptTokens += usage?.promptTokens ?? 0
            completionTokens += usage?.completionTokens ?? 0
            onProgress?(.chunkDone(index: 1, total: 1))
        } else {
            // 长书：map → reduce
            var partials: [String] = []
            for (index, chunk) in chunks.enumerated() {
                let (text, usage) = try await client.complete(
                    model: model,
                    messages: [
                        .system(Self.mapSystemPrompt),
                        .user(Self.buildMapPrompt(book: book, index: index + 1, total: chunks.count, text: chunk.text)),
                    ],
                    thinking: .disabled,
                    temperature: 0.3
                )
                partials.append(text)
                promptTokens += usage?.promptTokens ?? 0
                completionTokens += usage?.completionTokens ?? 0
                onProgress?(.chunkDone(index: index + 1, total: chunks.count))
            }

            onProgress?(.reducing)
            let (text, usage) = try await client.complete(
                model: model,
                messages: [
                    .system(Self.systemPrompt),
                    .user(Self.buildReducePrompt(book: book, partials: partials)),
                ],
                thinking: .disabled,
                temperature: 0.3
            )
            readme = text
            promptTokens += usage?.promptTokens ?? 0
            completionTokens += usage?.completionTokens ?? 0
        }

        let knowledge = BookKnowledge(
            readme: readme.trimmingCharacters(in: .whitespacesAndNewlines),
            contentHash: hash,
            model: model,
            characterCount: fullText.count,
            chapterCount: chapters.count,
            chunkCount: chunks.count,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
        onProgress?(.finished(knowledge))
        return knowledge
    }

    // MARK: - 正文抽取与分块

    public struct Chapter: Sendable {
        public let spineIndex: Int
        public let href: String
        public let text: String
        public init(spineIndex: Int, href: String, text: String) {
            self.spineIndex = spineIndex; self.href = href; self.text = text
        }
    }

    /// 按 spine 顺序抽出各章正文。
    ///
    /// 空白章节（纯图片页、目录页）会被跳过，避免浪费上下文。
    public static func extractChapters(epub: EpubDocument) -> [Chapter] {
        var result: [Chapter] = []
        for (index, id) in epub.spine.enumerated() {
            guard let href = epub.manifest[id],
                  let text = try? epub.text(forHref: href) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 少于 200 字的多半是扉页/版权页/目录，对理解全书帮助很小
            guard !trimmed.isEmpty else { continue }
            result.append(Chapter(spineIndex: index + 1, href: href, text: trimmed))
        }
        return result
    }

    /// 把章节按顺序切成不超过 `maxCharacters` 的块。
    ///
    /// 切分点尽量落在章节边界上，避免把一章从中间劈开导致摘要丢失上下文；
    /// 单章超长时才在章内切。
    public static func split(chapters: [Chapter], maxCharacters: Int) -> [Chapter] {
        var chunks: [Chapter] = []
        var buffer: [String] = []
        var bufferCount = 0
        var startSpine = chapters.first?.spineIndex ?? 1

        func flush() {
            guard !buffer.isEmpty else { return }
            chunks.append(Chapter(
                spineIndex: startSpine,
                href: "chunk-\(chunks.count + 1)",
                text: buffer.joined(separator: "\n\n")
            ))
            buffer.removeAll()
            bufferCount = 0
        }

        for chapter in chapters {
            if chapter.text.count > maxCharacters {
                // 单章超长：先结算已有缓冲，再按段落切这一章
                flush()
                for piece in splitByParagraph(chapter.text, maxCharacters: maxCharacters) {
                    chunks.append(Chapter(spineIndex: chapter.spineIndex, href: chapter.href, text: piece))
                }
                startSpine = chapter.spineIndex
                continue
            }
            if bufferCount + chapter.text.count > maxCharacters, !buffer.isEmpty {
                flush()
                startSpine = chapter.spineIndex
            }
            if buffer.isEmpty { startSpine = chapter.spineIndex }
            buffer.append(chapter.text)
            bufferCount += chapter.text.count
        }
        flush()
        return chunks
    }

    /// 按段落边界切分超长章节，保证不把一句话劈成两半。
    static func splitByParagraph(_ text: String, maxCharacters: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count + 1 > maxCharacters, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += paragraph
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// 正文内容指纹。
    ///
    /// SHA-256 基于完整 UTF-8 正文，跨进程稳定且覆盖内部改动。
    public static func contentHash(of text: String) -> String {
        "sha256-v1:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func contentHash(of chapters: [Chapter]) -> String {
        contentHash(of: chapters.map(\.text).joined(separator: "\n\n"))
    }

    // MARK: - 提示词

    /// 最终产出的说明要满足两件事：让模型"理解全书"，以及"知道哪里讲了什么"。
    /// 后者是为了支持按范围检索时定位。
    static let systemPrompt = """
    你是一位资深的图书编辑与阅读分析者。你的任务是通读一本书，产出一份给 AI 助手使用的书籍说明书。

    这份说明书的读者是另一个 AI：它之后要在你产出的基础上回答读者关于这本书的提问。
    因此它需要同时具备两种信息：
    1. **整体理解** —— 这本书在讲什么、怎么组织的、核心概念与论证/叙事线索
    2. **定位能力** —— 哪个内容大致在书的哪个位置，以便需要原文时能找到

    写作要求：
    - 用中文，Markdown 格式，层级清晰
    - 客观、具体，不要写"本书非常精彩"这类空泛评价
    - 涉及人物、概念、术语时给出准确名称
    - 篇幅控制在 1500-3000 字：足够让 AI 建立全局认知，又不至于臃肿
    """

    static func buildSinglePassPrompt(book: Book, text: String) -> String {
        """
        请通读以下书籍，产出书籍说明书。

        书名：《\(book.title)》
        作者：\(book.displayAuthor ?? "未知")

        === 正文开始 ===
        \(text)
        === 正文结束 ===

        请按以下结构产出说明书：

        ## 一、书籍概览
        题材、体裁、成书背景、作者视角、阅读门槛。三到五句话。

        ## 二、内容脉络
        按书的自然结构（部/章/幕）梳理主线，说明每一部分在讲什么、承担什么作用。
        这是最重要的一节，要让读者能据此快速定位"某个内容大概在哪"。

        ## 三、核心概念与术语
        列出理解本书必须掌握的概念、术语、人物、设定，各给一句话解释。

        ## 四、结构形式
        叙述方式（线性/多线/倒叙/论述式等）、语言风格、章节体量特征。
        若书中有特殊形式（书信体、剧本体、大量图表、代码示例等）要指出。

        ## 五、关键线索
        贯穿全书的主线、反复出现的意象或母题、论证的核心链条。
        这一节用于回答"这本书想表达什么"类的问题。
        """
    }

    static let mapSystemPrompt = """
    你是一位资深的图书编辑与阅读分析者。现在你拿到的是**一本书的一部分**，
    请为这一部分产出结构化摘要，供后续汇总成全书说明书使用。
    摘要要保留：这一段讲了什么、涉及哪些概念与人物、在整体结构中可能的位置。
    用中文，Markdown，控制在 500-900 字。不要臆测尚未读到的内容。
    """

    static func buildMapPrompt(book: Book, index: Int, total: Int, text: String) -> String {
        """
        书名：《\(book.title)》
        这是全书的第 \(index)/\(total) 部分。

        === 正文开始 ===
        \(text)
        === 正文结束 ===

        请产出这一部分的结构化摘要，包含：
        1. 本部分内容概要
        2. 出现的关键概念 / 人物 / 术语（附一句话说明）
        3. 本部分在整体结构中可能承担的作用
        4. 若有值得注意的形式特征（体裁、叙述人称、特殊排版），一并指出
        """
    }

    static func buildReducePrompt(book: Book, partials: [String]) -> String {
        let joined = partials.enumerated()
            .map { "### 第 \($0.offset + 1) 部分摘要\n\($0.element)" }
            .joined(separator: "\n\n")
        return """
        书名：《\(book.title)》
        作者：\(book.displayAuthor ?? "未知")

        以下是全书各部分的分段摘要（按阅读顺序）：

        \(joined)

        请把它们汇总成一份完整的书籍说明书，按以下结构：

        ## 一、书籍概览
        ## 二、内容脉络
        ## 三、核心概念与术语
        ## 四、结构形式
        ## 五、关键线索

        注意：请把分段摘要整合成连贯的整体认识，不要简单罗列各部分摘要。
        若某些部分的信息不足，宁可少写也不要编造。
        """
    }
}
