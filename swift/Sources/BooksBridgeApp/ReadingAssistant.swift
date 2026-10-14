import BooksBridgeCore
import BooksBridgeLLM
import Foundation

/// 阅读问答的编排层。
///
/// 职责：
/// 1. 打开一本书时后台做一次预处理（把整本书压缩成「书籍说明」），带缓存与去重
/// 2. 提问时按范围组装上下文、拼接提示词、流式取回答案
///
/// 刻意不做的事：不碰 UI、不碰持久化以外的存储。
/// 界面只消费这里产出的 `Event` 流。
@MainActor
public final class ReadingAssistant {
    /// 预处理状态，用于在界面上显示进度。
    public enum PreparationState: Sendable, Equatable {
        case idle
        /// 正在预处理，进度为「已完成块数 / 总块数」。
        case processing(done: Int, total: Int)
        case ready(characterCount: Int, chapterCount: Int, generatedAt: Date)
        case failed(String)

        public var label: String {
            switch self {
            case .idle: "未预处理"
            case .processing(let done, let total): "正在理解全书 \(done)/\(total)"
            case .ready(let characters, let chapters, _):
                "已理解全书 · \(chapters) 章 / \(characters / 1000)k 字"
            case .failed(let why): "预处理失败：\(why)"
            }
        }
    }

    /// 问答过程中产生的事件。
    public enum Event: Sendable {
        case preparationChanged(PreparationState)
        case reasoningDelta(String)
        case answerDelta(String)
        case finished(answer: String, scopeDescription: String, usage: TokenUsage?)
        case failed(String)
    }

    // MARK: - 依赖

    private let knowledgeStore: BookKnowledgeStore
    private let promptBuilder = PromptBuilder()

    /// 当前使用的设置与客户端，由外部在设置变更时刷新。
    private var settings: AppSettings
    private var apiKey: String
    private var client: ChatClient {
        ChatClient(baseURL: settings.baseURL, apiKey: apiKey)
    }

    // MARK: - 运行时状态

    public private(set) var preparation: PreparationState = .idle
    /// 当前已加载的书与正文，供提问时使用。
    private var loaded: LoadedBook?
    /// 正在进行的预处理任务，用于切换书目时取消。
    private var preparationTask: Task<Void, Never>?
    /// 正在进行的问答任务，用于用户中断。
    private var answerTask: Task<Void, Never>?

    public init(settings: AppSettings, apiKey: String, knowledgeDirectory: URL? = nil) {
        self.settings = settings
        self.apiKey = apiKey
        self.knowledgeStore = BookKnowledgeStore(directory: knowledgeDirectory)
    }

    /// 设置变更后刷新。已加载的书保持不动，只影响后续提问。
    public func update(settings: AppSettings, apiKey: String) {
        self.settings = settings
        self.apiKey = apiKey
    }

    /// 每次提问按当前设置构造：字符预算会随设置变化。
    private var contextBuilder: ContextBuilder {
        ContextBuilder(maxCharacters: settings.maxContextCharacters)
    }

    /// 是否已配置到可以发请求。
    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var currentBook: Book? { loaded?.book }
    public var currentChapters: [BookPreprocessor.Chapter] { loaded?.chapters ?? [] }
    public var currentKnowledge: BookKnowledge? { loaded?.knowledge }

    // MARK: - 已加载的书

    struct LoadedBook {
        let book: Book
        let epub: EpubDocument
        let chapters: [BookPreprocessor.Chapter]
        var knowledge: BookKnowledge?
        /// 当前阅读位置所在章节在 chapters 中的下标。
        var currentChapterIndex: Int?
    }

    /// 打开一本书：解析正文、定位当前章、按需触发预处理。
    ///
    /// 预处理在后台进行，不阻塞界面；未完成时提问会退化为"只用原文片段"。
    public func open(
        book: Book,
        currentCFI: String?,
        forceReprocess: Bool = false
    ) -> AsyncStream<Event> {
        preparationTask?.cancel()
        answerTask?.cancel()

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    let loaded = try self.load(book: book, currentCFI: currentCFI)
                    self.loaded = loaded
                    self.emit(.preparationChanged(.idle), to: continuation)

                    guard self.isConfigured else {
                        self.preparation = .failed("未配置 API Key")
                        self.emit(.preparationChanged(self.preparation), to: continuation)
                        continuation.finish()
                        return
                    }

                    // 缓存命中且正文未变就不重做
                    if !forceReprocess,
                       let cached = await self.knowledgeStore.cached(assetID: book.assetID),
                       cached.contentHash == loaded.epub.contentHash {
                        self.loaded?.knowledge = cached
                        self.preparation = .ready(
                            characterCount: cached.characterCount,
                            chapterCount: cached.chapterCount,
                            generatedAt: cached.generatedAt
                        )
                        self.emit(.preparationChanged(self.preparation), to: continuation)
                        continuation.finish()
                        return
                    }

                    self.preparation = .processing(done: 0, total: 1)
                    self.emit(.preparationChanged(self.preparation), to: continuation)

                    let preprocessor = BookPreprocessor(client: self.client, model: self.settings.model)
                    let knowledge = try await preprocessor.process(book: book, epub: loaded.epub) { progress in
                        Task { @MainActor in
                            switch progress {
                            case .started(let count):
                                self.preparation = .processing(done: 0, total: count)
                            case .chunkDone(let index, let total):
                                self.preparation = .processing(done: index, total: total)
                            case .reducing:
                                self.preparation = .processing(done: 1, total: 1)
                            case .finished:
                                break
                            }
                            self.emit(.preparationChanged(self.preparation), to: continuation)
                        }
                    }

                    await self.knowledgeStore.save(knowledge, assetID: book.assetID)
                    self.loaded?.knowledge = knowledge
                    self.preparation = .ready(
                        characterCount: knowledge.characterCount,
                        chapterCount: knowledge.chapterCount,
                        generatedAt: knowledge.generatedAt
                    )
                    self.emit(.preparationChanged(self.preparation), to: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    let message = (error as? ChatClient.ClientError)?.description
                        ?? error.localizedDescription
                    self.preparation = .failed(message)
                    self.emit(.preparationChanged(self.preparation), to: continuation)
                    continuation.finish()
                }
            }
            self.preparationTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func load(book: Book, currentCFI: String?) throws -> LoadedBook {
        guard let path = book.path else {
            throw AssistantError.noLocalFile
        }
        let epub = try EpubDocument(root: URL(fileURLWithPath: path))
        let chapters = BookPreprocessor.extractChapters(epub: epub)
        return LoadedBook(
            book: book,
            epub: epub,
            chapters: chapters,
            knowledge: nil,
            currentChapterIndex: Self.locateChapter(cfi: currentCFI, epub: epub, chapters: chapters)
        )
    }

    /// 把 CFI 映射到 `chapters` 的下标。
    ///
    /// 注意 `chapters` 已过滤掉过短的页面（扉页、目录），
    /// 所以不能直接用 spine 序号当下标，必须按 spineIndex 反查。
    static func locateChapter(
        cfi: String?,
        epub: EpubDocument,
        chapters: [BookPreprocessor.Chapter]
    ) -> Int? {
        guard let cfi, let parsed = CFI(raw: cfi) else { return nil }
        let href = parsed.idAssertion.flatMap { epub.href(forID: $0) }
            ?? epub.href(forSpineIndex: parsed.spineIndex)
        guard let href else { return nil }
        return chapters.firstIndex { $0.href == href }
    }

    // MARK: - 问答

    /// 提问并流式取回答案。
    public func ask(
        question: String,
        scope: KnowledgeScope,
        visibleText: [String] = [],
        history: [ChatMessage] = []
    ) -> AsyncStream<Event> {
        answerTask?.cancel()

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                guard let loaded = self.loaded else {
                    self.emit(.failed("尚未打开任何书籍"), to: continuation)
                    continuation.finish()
                    return
                }
                guard self.isConfigured else {
                    self.emit(.failed("未配置 API Key，请先在设置里填写"), to: continuation)
                    continuation.finish()
                    return
                }

                let context = self.contextBuilder.build(
                    knowledge: loaded.knowledge?.readme ?? "",
                    chapters: loaded.chapters,
                    currentChapterIndex: loaded.currentChapterIndex,
                    scope: scope,
                    question: question,
                    visibleText: visibleText
                )

                let messages = self.promptBuilder.build(
                    book: loaded.book,
                    question: question,
                    context: context,
                    visibleText: visibleText,
                    progress: loaded.book.progress,
                    history: history
                )

                var answer = ""
                var usage: TokenUsage?
                do {
                    let stream = self.client.stream(
                        model: self.settings.model,
                        messages: messages,
                        thinking: self.settings.thinkingLevel.thinkingMode,
                        temperature: self.settings.temperature
                    )
                    for try await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case .content(let delta):
                            answer += delta
                            self.emit(.answerDelta(delta), to: continuation)
                        case .reasoning(let delta):
                            self.emit(.reasoningDelta(delta), to: continuation)
                        case .finished(let reported, _):
                            usage = reported
                        }
                    }
                    self.emit(.finished(
                        answer: answer,
                        scopeDescription: context.scopeDescription,
                        usage: usage
                    ), to: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    let message = (error as? ChatClient.ClientError)?.description
                        ?? error.localizedDescription
                    self.emit(.failed(message), to: continuation)
                    continuation.finish()
                }
            }
            self.answerTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
    }

    // MARK: - 工具

    private func emit(_ event: Event, to continuation: AsyncStream<Event>.Continuation) {
        continuation.yield(event)
    }

    public enum AssistantError: Error, CustomStringConvertible {
        case noLocalFile
        case notLoaded

        public var description: String {
            switch self {
            case .noLocalFile: "这本书的正文文件不在本地，无法读取内容"
            case .notLoaded: "尚未打开任何书籍"
            }
        }
    }
}

private extension EpubDocument {
    /// 正文指纹，用于判断缓存是否失效。
    var contentHash: String {
        var hasher = Hasher()
        hasher.combine(manifest.count)
        hasher.combine(spine.count)
        for id in spine {
            guard let href = manifest[id] else { continue }
            hasher.combine(href)
        }
        return String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }
}
