import BooksBridgeCore
import BooksBridgeLLM
import Foundation

/// One local source map, one frozen position per request, one model call.
@MainActor
public final class ReadingAssistant {
    public enum Event: Sendable {
        case contextPrepared(String)
        case reasoningDelta(String)
        case answerDelta(String)
        case finished(answer: String, scopeDescription: String, usage: TokenUsage?)
        case failed(String)
    }

    private var settings: AppSettings
    private var apiKey: String
    private var client: ChatClient { ChatClient(baseURL: settings.baseURL, apiKey: apiKey) }
    private let promptBuilder = PromptBuilder()
    private var answerTask: Task<Void, Never>?
    private var loaded: LoadedBook?
    private let mapDirectory: URL
    private var sourceGenerations: [String: Int] = [:]
    public private(set) var lastBoundary: ReadingBoundary?
    public private(set) var lastSourceHash: String?
    public var currentBook: Book? { loaded?.book }
    public var currentChapters: [BookPreprocessor.Chapter] { loaded?.chapters ?? [] }
    public var currentMap: BookMap? { loaded?.map }
    public var currentStatistics: BookStatistics? { loaded?.statistics }
    var currentChapterIndex: Int? { loaded?.currentChapterIndex }
    public var isConfigured: Bool { !apiKey.isEmpty && !settings.baseURL.isEmpty && !settings.model.isEmpty }

    public init(settings: AppSettings, apiKey: String, knowledgeDirectory: URL? = nil) {
        self.settings = settings; self.apiKey = apiKey
        mapDirectory = knowledgeDirectory ?? AppPaths.supportDirectory.appendingPathComponent("maps")
    }
    public func update(settings: AppSettings, apiKey: String) { self.settings = settings; self.apiKey = apiKey }
    struct LoadedBook: Sendable {
        var book: Book
        let epub: EpubDocument
        let chapters: [BookPreprocessor.Chapter]
        let map: BookMap
        let statistics: BookStatistics
        var currentChapterIndex: Int?
    }

    /// Reparse locally so changed source cannot reuse an old page or summary.
    public func refresh(book: Book, live: ReadingContext?, previous: ReadingSnapshot?) async throws -> ReadingSnapshot {
        let generation = sourceGenerations[book.assetID, default: 0]
        let cfi = live?.book.assetID == book.assetID ? live?.position?.cfi : nil
        let value = try await Task.detached { try Self.load(book: book, currentCFI: cfi) }.value
        try Task.checkCancellation()
        guard sourceGenerations[book.assetID, default: 0] == generation else { throw CancellationError() }
        loaded = value
        try FileManager.default.createDirectory(at: mapDirectory, withIntermediateDirectories: true)
        // Hash identifiers so imported names cannot become paths.
        try JSONEncoder().encode(value.map).write(to: mapDirectory.appendingPathComponent(BookDataRemoval.mapFilename(assetID: book.assetID)), options: .atomic)
        return try ReadingSnapshot.resolve(assetID: book.assetID, map: value.map, chapters: value.chapters, live: live, previous: previous)
    }
    public func reading(snapshot: ReadingSnapshot, scope: KnowledgeScope) throws -> ScopedReading {
        guard let loaded, snapshot.assetID == loaded.book.assetID else { throw AssistantError.notLoaded }
        return try snapshot.reading(chapters: loaded.chapters, map: loaded.map, scope: scope)
    }
    public func cancelAnswer() { answerTask?.cancel(); answerTask = nil }
    public func forgetBook(assetID: String) {
        sourceGenerations[assetID, default: 0] += 1
        if loaded?.book.assetID == assetID { cancelAnswer(); loaded = nil; lastBoundary = nil; lastSourceHash = nil }
    }
    private func emit(_ event: Event, to continuation: AsyncStream<Event>.Continuation) { continuation.yield(event) }

    nonisolated private static func load(book: Book, currentCFI: String?) throws -> LoadedBook {
        guard let path = book.path else {
            throw AssistantError.noLocalFile
        }
        let epub = try EpubDocument(root: URL(fileURLWithPath: path))
        let chapters = try epub.spine.enumerated().compactMap { index, id -> BookPreprocessor.Chapter? in
            guard let href = epub.manifest[id] else { throw EpubDocument.EpubError.malformedOPF("正文目录缺项") }
            let text = try epub.text(forHref: href).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .init(spineIndex: index + 1, href: href, text: text)
        }
        let map = try BookMap.build(epub: epub, chapters: chapters)
        return LoadedBook(
            book: book,
            epub: epub,
            chapters: chapters,
            map: map,
            statistics: BookStatistics.build(map: map, chapters: chapters),
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

    public func ask(
        book: Book,
        currentCFI: String?,
        question: String,
        scope: KnowledgeScope,
        visibleText: [String] = [],
        history: [ChatMessage] = [],
        historyBoundaries: [ReadingBoundary?] = [],
        historySourceHashes: [String?] = [],
        snapshot: ReadingSnapshot? = nil,
        summary: ReadingSummary? = nil,
        study: BookStudy? = nil
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
                    if let snapshot {
                        guard snapshot.assetID == book.assetID else { throw ScopedReading.Failure.cannotLocatePage }
                        allowed = try snapshot.reading(chapters: loaded.chapters, map: loaded.map, scope: scope)
                    } else {
                        allowed = try ScopedReading.resolve(chapters: loaded.chapters,
                            current: loaded.currentChapterIndex, scope: scope, visible: visibleText)
                    }
                } catch {
                    self.emit(.failed(String(describing: error)), to: continuation)
                    continuation.finish(); return
                }
                self.lastBoundary = allowed.boundary
                self.lastSourceHash = loaded.map.sourceHash
                let safeHistory = history.enumerated().compactMap { i, message -> ChatMessage? in
                    guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          historyBoundaries.indices.contains(i), let boundary = historyBoundaries[i],
                          boundary <= allowed.boundary,
                          historySourceHashes.indices.contains(i), historySourceHashes[i] == loaded.map.sourceHash else { return nil }
                    return message
                }
                // Reserve room for system instructions, history, question and the response.
                let totalBudget = max(4000, min(self.settings.maxContextCharacters, 200000))
                let historyBudget = min(6000, totalBudget / 4)
                let boundedHistory = PromptBuilder.trimHistory(safeHistory, characters: historyBudget)
                let materialBudget = max(500, totalBudget - 2200 - question.count - boundedHistory.reduce(0) { $0 + $1.content.count })
                let guide = snapshot.flatMap { snapshot in study.flatMap { study in
                    study.summary(snapshot: snapshot, scope: scope) == nil ? nil : study.readingMaterial(snapshot: snapshot, scope: scope, source: loaded.chapters)
                } } ?? ""
                let guideBudget = max(0, materialBudget * 2 / 3 - 150)
                let boundedGuide = guide.isEmpty ? "" : (guide.count <= guideBudget ? guide : String(guide.prefix(guideBudget)) + "\n[阅读材料超出预算，后续已省略；不能视为完整覆盖]")
                let context = ContextBuilder(maxCharacters: max(300, materialBudget - boundedGuide.count - 100), maxExcerpts: 12, excerptCharacters: 1400).build(
                    knowledge: "",
                    chapters: allowed.chapters,
                    currentChapterIndex: allowed.currentChapter,
                    scope: scope,
                    question: Self.retrievalQuestion(question, history: boundedHistory),
                    visibleText: visibleText, preScoped: true
                )

                self.emit(.contextPrepared(boundedGuide.isEmpty
                    ? "正在思考 · 已读取\(context.isComplete ? "完整原文" : "原文选段") \(context.characterCount) 字"
                    : "正在思考 · 已读取权限内章节摘要与原文 \(boundedGuide.count + context.characterCount) 字"), to: continuation)
                var messages = self.promptBuilder.build(
                    book: loaded.book,
                    question: question,
                    context: context,
                    visibleText: [],
                    progress: snapshot?.progress ?? loaded.book.progress,
                    history: boundedHistory
                )
                if !boundedGuide.isEmpty { messages.append(.user("本轮阅读材料（章节摘要可能省略细节，原文选段用于核对）：\n" + boundedGuide)) }

                var answer = ""
                var usage: TokenUsage?
                var outputLimited = false
                do {
                    if boundedGuide.isEmpty, let snapshot, let summary, summary.isAllowed(snapshot: snapshot, reading: allowed) {
                        let remaining = max(0, totalBudget - messages.reduce(0) { $0 + $1.content.count } - 100)
                        if remaining > summary.text.count {
                            messages.append(.user("权限内的已生成摘要（原文优先，摘要可能有省略）：\n" + summary.text))
                        }
                    }
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
