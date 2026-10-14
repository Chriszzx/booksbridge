import BooksBridgeCore
import Foundation

/// 把「问题 + 书籍知识 + 原文片段 + 对话历史」拼成发给模型的消息序列。
///
/// 拆成独立类型是为了可单测——提示词里的**剧透边界**必须与用户选的范围严格一致，
/// 这是本应用最容易出错也最伤人的地方（用户选了"读到这为止"却被透了结局）。
public struct PromptBuilder: Sendable {
    public init() {}

    /// 系统提示词。
    ///
    /// 三件事必须说清：
    /// 1. 助手是"辅助阅读"的，不是替读者读书
    /// 2. 当前知识范围是什么，**明确禁止越界补充**
    /// 3. 不确定时要说不知道，不要用预训练记忆里的"这本书的情节"编造
    ///
    /// 第 3 点尤其重要：LLM 很可能在预训练里见过这本书，
    /// 如果不加约束，它会无视我们给的范围直接凭记忆回答，剧透就失效了。
    public static func systemPrompt(
        book: Book,
        scope: KnowledgeScope,
        scopeDescription: String
    ) -> String {
        var lines: [String] = []
        lines.append("你是一位辅助阅读助手，正在陪伴读者阅读《\(book.title)》\(book.displayAuthor.map { "（\($0)）" } ?? "")。")
        lines.append("")
        lines.append("## 当前知识范围")
        lines.append("你可以使用的内容范围是：**\(scopeDescription)**。")
        switch scope {
        case .upToProgress:
            lines.append("读者还在阅读途中，**严格禁止提及超出此范围的任何情节、结论或人物命运**。")
            lines.append("如果不确定某个信息是否在范围内，就不要说。")
        case .currentChapter:
            lines.append("可以使用到当前这一章为止的全部内容，但**不得提及之后章节的任何信息**。")
        case .wholeBook:
            lines.append("可以使用全书内容。若涉及读者尚未读到的情节，请在回答前提示「以下涉及后续内容」。")
        }
        lines.append("")
        lines.append("## 回答方式")
        lines.append("- 优先引用原文：回答具体问题时指出依据来自哪一章、哪一段")
        lines.append("- 结合读者当前读到的位置来组织回答，不要一次倾倒全部背景")
        lines.append("- 读者问的是当下的困惑，先直接回答，再按需补充背景")
        lines.append("- 若给定材料不足以回答，明确说「按目前掌握的内容无法确定」，不要用你对该书的既有印象补全")
        lines.append("")
        lines.append("## 重要约束")
        lines.append("即使你在训练数据中见过这本书，也必须**只依据下面提供的材料**回答。")
        lines.append("材料没写到的情节，一律视为你不知道。")
        return lines.joined(separator: "\n")
    }

    /// 用户这一轮的消息：上下文材料 + 当前屏幕 + 问题。
    public static func userPrompt(
        question: String,
        context: ContextBuilder.BuiltContext,
        visibleText: [String],
        progress: Double
    ) -> String {
        var sections: [String] = []

        let material = context.render()
        if !material.isEmpty {
            sections.append("# 可用材料\n\n\(material)")
        } else {
            sections.append("# 可用材料\n\n（暂无预处理说明，只能依据读者当前所见的原文回答）")
        }

        // 屏幕可见正文单独列出：这是读者提问时眼前的东西，往往就是问题的指向
        if !visibleText.isEmpty {
            let body = visibleText.joined(separator: "\n")
            sections.append("# 读者此刻屏幕上可见的正文\n\n\(body)")
        }

        sections.append(String(
            format: "# 读者进度\n\n已读约 %.1f%%，当前范围：%@",
            progress * 100,
            context.scopeDescription
        ))

        sections.append("# 读者的问题\n\n\(question)")
        return sections.joined(separator: "\n\n")
    }

    /// 组装完整消息序列。
    ///
    /// - Parameter history: 之前轮次的消息（不含本轮）。按需截断以免无限增长。
    public func build(
        book: Book,
        question: String,
        context: ContextBuilder.BuiltContext,
        visibleText: [String],
        progress: Double,
        history: [ChatMessage] = [],
        maxHistoryMessages: Int = 8
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            .system(Self.systemPrompt(
                book: book,
                scope: context.scope,
                scopeDescription: context.scopeDescription
            )),
        ]
        // 只保留最近若干轮，避免上下文无界增长
        if history.count > maxHistoryMessages {
            messages.append(contentsOf: history.suffix(maxHistoryMessages))
        } else {
            messages.append(contentsOf: history)
        }
        messages.append(.user(Self.userPrompt(
            question: question,
            context: context,
            visibleText: visibleText,
            progress: progress
        )))
        return messages
    }
}
