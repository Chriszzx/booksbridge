import BooksBridgeCore
import BooksBridgeLLM
import Foundation

/// 阅读问答的编排层。
///
/// 职责：
/// 1. 打开书只读取本地正文；用户确认后，按书籍运行独立的后台摘要任务
/// 2. 提问时按范围组装上下文、拼接提示词、流式取回答案
///
/// 刻意不做的事：不碰 UI、不碰持久化以外的存储。
/// 界面只消费这里产出的 `Event` 流。
@MainActor
public final class ReadingAssistant {
    /// 预处理状态，用于在界面上显示进度。
    public enum PreparationState: Sendable, Equatable, Codable {
        case idle
        /// 正在预处理，进度为「已完成块数 / 总块数」。
        case processing(done: Int, total: Int)
        case reducing
        case ready(characterCount: Int, chapterCount: Int, generatedAt: Date)
        case failed(String)

        public var label: String {
            switch self {
            case .idle: "直接读取本地原文 · 未生成有效摘要"
            case .processing(let done, let total): "正在理解全书 \(done)/\(total)"
            case .reducing: "正在汇总全书摘要"
            case .ready(let characters, let chapters, _):
                "已理解全书 · \(chapters) 章 / \(characters / 1000)k 字"
            case .failed(let why): "预处理失败：\(why)"
            }
        }
    }

    /// 问答过程中产生的事件。
    public enum Event: Sendable {
        case preparationChanged(PreparationState)
        case contextPrepared(String)
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

    public private(set) var lastBoundary: ReadingBoundary?
    public private(set) var preparation: PreparationState = .idle
    /// 当前已加载的书与正文，供提问时使用。
    private var loaded: LoadedBook?
    /// 摘要由书籍拥有，只有显式取消才停止；页面观察者不拥有任务。
    private var preparationGenerations: [String: UUID] = [:]
    private var preparationTasks: [String: Task<Void, Never>] = [:]
    private var preparationStates: [String: PreparationState] = [:]
    private var preparationTitles: [String: String] = [:]
    public var preparationStatuses: [[String: String]] {
        preparationStates.keys.sorted().compactMap { id in
            guard let state = preparationStates[id], state != .idle else { return nil }
            return ["assetID": id, "title": preparationTitles[id] ?? "书籍摘要", "status": state.label]
        }
    }
    private var openGeneration = UUID()
    private let preparationFile: URL
    private struct PreparationRecord: Codable {
        let title: String
        let state: PreparationState
    }
    typealias Processor = @Sendable (Book, EpubDocument, @escaping @Sendable (BookPreprocessor.Progress) -> Void) async throws -> BookKnowledge
    var processOverride: Processor?
    public var onPreparationChanged: ((String, PreparationState) -> Void)?
    public func preparationState(assetID: String) -> PreparationState { preparationStates[assetID] ?? .idle }
    private func setPreparation(_ state: PreparationState, assetID: String) {
        preparationStates[assetID] = state
        do {
            try FileManager.default.createDirectory(at: preparationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let named = preparationStates.map { id, state in
                (id, PreparationRecord(title: preparationTitles[id] ?? "书籍摘要", state: state))
            }
            try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: named)).write(to: preparationFile, options: .atomic)
        } catch { NSLog("[BooksBridge] 摘要状态保存失败：%@", error.localizedDescription) }
        if loaded?.book.assetID == assetID { preparation = state }
        onPreparationChanged?(assetID, state)
    }
    /// 正在进行的问答任务，用于用户中断。
    private var answerTask: Task<Void, Never>?

    public init(settings: AppSettings, apiKey: String, knowledgeDirectory: URL? = nil) {
        self.settings = settings
        self.apiKey = apiKey
        self.knowledgeStore = BookKnowledgeStore(directory: knowledgeDirectory)
        self.preparationFile = (knowledgeDirectory ?? AppPaths.supportDirectory.appendingPathComponent("knowledge"))
            .appendingPathComponent("preparation-status.json")
        if let data = try? Data(contentsOf: preparationFile),
           let saved = try? JSONDecoder().decode([String: PreparationRecord].self, from: data) {
            preparationTitles = saved.mapValues(\.title)
            preparationStates = saved.mapValues { record in
                switch record.state {
                case .processing, .reducing: return .failed("应用退出导致任务中断，请手动重新生成")
                default: return record.state
                }
            }
        }
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

    var currentChapterIndex: Int? { loaded?.currentChapterIndex }
    public var currentBook: Book? { loaded?.book }
    public var currentChapters: [BookPreprocessor.Chapter] { loaded?.chapters ?? [] }
    public var currentKnowledge: BookKnowledge? { loaded?.knowledge }

    // MARK: - 已加载的书

    struct LoadedBook: Sendable {
        var book: Book
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
        preparationTitles[book.assetID] = book.title
        openGeneration = UUID()
        let opening = openGeneration
        let generation = UUID()
        if preparationTasks[book.assetID] != nil {
            return AsyncStream { $0.yield(.preparationChanged(preparationState(assetID: book.assetID))); $0.finish() }
        }
        preparationGenerations[book.assetID] = generation

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                var state: PreparationState = self.preparationState(assetID: book.assetID)
                defer {
                    if self.preparationGenerations[book.assetID] == generation {
                        self.preparationTasks[book.assetID] = nil
                        self.preparationGenerations[book.assetID] = nil
                    }
                }
                do {
                    let loaded = try await Task.detached { try Self.load(book: book, currentCFI: currentCFI) }.value
                    try Task.checkCancellation()
                    if self.openGeneration == opening { self.loaded = loaded }

                    // 缓存命中且正文未变就不重做
                    if !forceReprocess,
                       let cached = await self.knowledgeStore.cached(assetID: book.assetID),
                       cached.contentHash == BookPreprocessor.contentHash(of: loaded.chapters) {
                        try Task.checkCancellation()
                        if self.loaded?.book.assetID == book.assetID { self.loaded?.knowledge = cached }
                        state = .ready(
                            characterCount: cached.characterCount,
                            chapterCount: cached.chapterCount,
                            generatedAt: cached.generatedAt
                        )
                        self.setPreparation(state, assetID: book.assetID)
                        self.emit(.preparationChanged(state), to: continuation)
                        continuation.finish()
                        return
                    }

                    // 打开书只加载本地正文/缓存；付费预处理由明确操作触发。
                    guard forceReprocess else {
                        if case .failed = state {} else { state = .idle }
                        self.setPreparation(state, assetID: book.assetID)
                        self.emit(.preparationChanged(state), to: continuation)
                        continuation.finish()
                        return
                    }
                    guard self.isConfigured else { throw ChatClient.ClientError.missingAPIKey }
                    try Task.checkCancellation()
                    state = .processing(done: 0, total: 1)
                    self.setPreparation(state, assetID: book.assetID)
                    self.emit(.preparationChanged(state), to: continuation)

                    let preprocessor = BookPreprocessor(client: self.client, model: self.settings.model)
                    let progressHandler: @Sendable (BookPreprocessor.Progress) -> Void = { progress in
                        Task { @MainActor in
                            guard self.preparationGenerations[book.assetID] == generation else { return }
                            let state: PreparationState
                            switch progress {
                            case .started(let count):
                                state = .processing(done: 0, total: count)
                            case .chunkDone(let index, let total):
                                state = .processing(done: index, total: total)
                            case .reducing:
                                state = .reducing
                            case .finished:
                                return
                            }
                            self.setPreparation(state, assetID: book.assetID)
                            self.emit(.preparationChanged(state), to: continuation)
                        }
                    }

                    let knowledge: BookKnowledge
                    if let process = self.processOverride {
                        knowledge = try await process(book, loaded.epub, progressHandler)
                    } else {
                        knowledge = try await preprocessor.process(book: book, epub: loaded.epub, onProgress: progressHandler)
                    }
                    try Task.checkCancellation()
                    await self.knowledgeStore.save(knowledge, assetID: book.assetID)
                    try Task.checkCancellation()
                    if self.loaded?.book.assetID == book.assetID { self.loaded?.knowledge = knowledge }
                    state = .ready(
                        characterCount: knowledge.characterCount,
                        chapterCount: knowledge.chapterCount,
                        generatedAt: knowledge.generatedAt
                    )
                    self.setPreparation(state, assetID: book.assetID)
                    self.emit(.preparationChanged(state), to: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    guard self.preparationGenerations[book.assetID] == generation, !Task.isCancelled else { continuation.finish(); return }
                    let message = (error as? ChatClient.ClientError)?.description
                        ?? error.localizedDescription
                    state = .failed(message)
                    self.setPreparation(state, assetID: book.assetID)
                    self.emit(.preparationChanged(state), to: continuation)
                    continuation.finish()
                }
            }
            self.preparationTasks[book.assetID] = task
            // The book owns this task; closing a view only detaches its observer.
        }
    }

    nonisolated private static func load(book: Book, currentCFI: String?) throws -> LoadedBook {
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
    nonisolated static func locateChapter(
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

    /// 提问前更新本书快照；受限范围无法定位时停止，避免使用旧位置。
    func refreshReading(book: Book, currentCFI: String?, scope: KnowledgeScope) throws {
        if loaded?.book.assetID != book.assetID || loaded?.book.path != book.path {
            loaded = try Self.load(book: book, currentCFI: currentCFI)
        }
        guard var snapshot = loaded else { throw AssistantError.notLoaded }
        snapshot.book = book
        snapshot.currentChapterIndex = Self.locateChapter(cfi: currentCFI, epub: snapshot.epub, chapters: snapshot.chapters)
        loaded = snapshot
        if scope != .wholeBook, snapshot.currentChapterIndex == nil {
            throw AssistantError.unknownPosition
        }
    }

    // MARK: - 问答

    /// 提问并流式取回答案。
    public func ask(
        book: Book,
        currentCFI: String?,
        question: String,
        scope: KnowledgeScope,
        visibleText: [String] = [],
        history: [ChatMessage] = [],
        historyBoundaries: [ReadingBoundary?] = []
    ) -> AsyncStream<Event> {
        answerTask?.cancel()

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    if self.loaded?.book.assetID != book.assetID || self.loaded?.book.path != book.path {
                        self.loaded = try await Task.detached { try Self.load(book: book, currentCFI: currentCFI) }.value
                        try Task.checkCancellation()
                    }
                    try self.refreshReading(book: book, currentCFI: currentCFI, scope: .wholeBook)
                } catch {
                    self.emit(.failed(String(describing: error)), to: continuation)
                    continuation.finish()
                    return
                }
                guard let loaded = self.loaded else { continuation.finish(); return }
                guard self.isConfigured else {
                    self.emit(.failed("未配置 API Key，请先在设置里填写"), to: continuation)
                    continuation.finish()
                    return
                }

                let allowed: ScopedReading
                do {
                    allowed = try ScopedReading.resolve(chapters: loaded.chapters,
                        current: loaded.currentChapterIndex, scope: scope, visible: visibleText)
                } catch {
                    self.emit(.failed(String(describing: error)), to: continuation)
                    continuation.finish(); return
                }
                self.lastBoundary = allowed.boundary
                let safeHistory = history.enumerated().compactMap { i, message -> ChatMessage? in
                    guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          historyBoundaries.indices.contains(i), let boundary = historyBoundaries[i],
                          boundary <= allowed.boundary else { return nil }
                    return message
                }
                // Reserve room for system instructions, history, question and the response.
                let totalBudget = max(4000, min(self.settings.maxContextCharacters, 200000))
                let historyBudget = min(6000, totalBudget / 4)
                let boundedHistory = PromptBuilder.trimHistory(safeHistory, characters: historyBudget)
                let materialBudget = max(500, totalBudget - 2200 - question.count - boundedHistory.reduce(0) { $0 + $1.content.count })
                let context = ContextBuilder(maxCharacters: materialBudget, maxExcerpts: 12, excerptCharacters: 1400).build(
                    knowledge: loaded.knowledge?.readme ?? "",
                    chapters: allowed.chapters,
                    currentChapterIndex: allowed.currentChapter,
                    scope: scope,
                    question: Self.retrievalQuestion(question, history: boundedHistory),
                    visibleText: visibleText, preScoped: true
                )

                self.emit(.contextPrepared("正在思考 · 已读取\(context.isComplete ? "完整原文" : "原文选段") \(context.characterCount) 字"), to: continuation)
                var messages = self.promptBuilder.build(
                    book: loaded.book,
                    question: question,
                    context: context,
                    visibleText: [],
                    progress: loaded.book.progress,
                    history: boundedHistory
                )

                var answer = ""
                var usage: TokenUsage?
                var outputLimited = false
                do {
                    // Bounded tool loop: the model can ask for extra local evidence.
                    // Only permitted chapters enter the tool object; no file access is exposed.
                    let tools = ReadingTools(reading: allowed)
                    var evidence = ""
                    let toolBudget = max(0, totalBudget - messages.reduce(0) { $0 + $1.content.count } - 500)
                    if !context.isComplete && toolBudget >= 500 {
                        for _ in 0..<2 {
                            try Task.checkCancellation()
                            let instruction = "你是阅读材料检索器，不回答问题。判断是否需要补充材料。只返回一个 JSON 对象，不用代码围栏：{\"tool\":\"search\",\"query\":\"关键词\"} 或 {\"tool\":\"read\",\"chapter\":0,\"offset\":0,\"length\":1200}；材料足够返回 {\"tool\":\"done\"}。文档区段ID从0开始，不是书中章号。仅可读目录：" + String(tools.catalog.prefix(1200))
                            let plan = try await self.client.complete(model: self.settings.model,
                                messages: PromptBuilder.retrievalMessages(instruction: instruction, question: Self.retrievalQuestion(question, history: boundedHistory), material: context.render() + evidence, budget: min(totalBudget, 5000)), maxTokens: 200)
                            guard let result = tools.execute(plan.text) else { break }
                            let remaining = toolBudget - evidence.count
                            guard remaining > 0 else { break }
                            evidence += String(result.prefix(remaining))
                        }
                    }
                    if !evidence.isEmpty { messages.append(.user("本轮读取工具返回的补充原文（仍在权限内）：\n" + evidence)) }
                    guard messages.reduce(0, { $0 + $1.content.count }) <= totalBudget else {
                        self.emit(.failed("组装后的请求超过字符预算，本次未发送；请增大请求预算。"), to: continuation)
                        continuation.finish(); return
                    }
                    let stream = self.client.stream(
                        model: self.settings.model,
                        messages: messages,
                        thinking: self.settings.thinkingLevel.thinkingMode,
                        temperature: self.settings.temperature, maxTokens: 8192
                    )
                    for try await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case .content(let delta):
                            answer += delta
                            self.emit(.answerDelta(delta), to: continuation)
                        case .reasoning(let delta):
                            self.emit(.reasoningDelta(delta), to: continuation)
                        case .finished(let reported, let reason):
                            usage = reported
                            outputLimited = reason == "length"
                        }
                    }
                    try Task.checkCancellation()
                    if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.emit(.failed(outputLimited ? "模型在输出上限内未生成正文，思考可能已占满预算；请降低思考档位后重试。" : "模型未返回回答正文，请重试。"), to: continuation)
                        continuation.finish(); return
                    }
                    if outputLimited { answer += "\n\n> 本次回答达到输出上限，内容尚未完成。" }
                    self.emit(.finished(
                        answer: answer,
                        scopeDescription: context.scopeDescription + " · " + (context.isComplete ? "完整原文" : "选段，存在省略") + " \(context.characterCount) 字",
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

    static func retrievalQuestion(_ question: String, history: [ChatMessage]) -> String {
        let previous = history.filter { $0.role == .user }.suffix(2).map(\.content)
        return (previous + [question]).joined(separator: "\n")
    }

    public func cancelPreparation(assetID: String? = nil) {
        guard let id = assetID ?? loaded?.book.assetID else { return }
        preparationGenerations[id] = UUID()
        preparationTasks.removeValue(forKey: id)?.cancel()
        setPreparation(.failed("已取消，可重新生成"), assetID: id)
    }

    public func clearKnowledge(assetID: String) async {
        cancelPreparation(assetID: assetID)
        await knowledgeStore.remove(assetID: assetID)
        if loaded?.book.assetID == assetID { loaded?.knowledge = nil }
        setPreparation(.idle, assetID: assetID)
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
        case unknownPosition

        public var description: String {
            switch self {
            case .noLocalFile: "这本书的正文文件不在本地，无法读取内容"
            case .unknownPosition: "无法定位本书最新阅读进度，本次未发送请求；请在图书 App 中打开本书并翻页后重试"
            case .notLoaded: "尚未打开任何书籍"
            }
        }
    }
}
