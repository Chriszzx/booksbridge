import Foundation
import BooksBridgeCore
import BooksBridgeLLM

/// A single resumable job per app-owned book. Inputs and authorization are frozen at start.
@MainActor
final class SummaryJobs {
    typealias Processor = @Sendable (String, String) async throws -> String
    var processOverride: Processor?
    var onUpdate: ((String) -> Void)?
    private var loading: [String: Task<Void, Never>] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var failures: [String: String] = [:]
    func isRunning(assetID: String) -> Bool { tasks[assetID] != nil || loading[assetID] != nil }
    func failureStatus(assetID: String) -> String? { failures[assetID] }

    /// Preparing a book is also a book-owned job, independent of navigation and chat permissions.
    func startWholeBook(assetID: String, settings: AppSettings, apiKey: String, store: ConversationStore,
                        loadBook: @escaping @Sendable () async throws -> Book) {
        guard !isRunning(assetID: assetID), let saved = store.book(assetID: assetID) else { return }
        let generation = UUID(), libraryID = saved.libraryID
        generations[assetID] = generation; failures[assetID] = nil
        loading[assetID] = Task {
            defer { if generations[assetID] == generation { loading[assetID] = nil; onUpdate?(assetID) } }
            do {
                let book = try await loadBook()
                let reader = ReadingAssistant(settings: settings, apiKey: "")
                let snapshot = try await reader.refresh(book: book, live: nil, previous: nil, persistMap: false)
                try Task.checkCancellation()
                guard generations[assetID] == generation, book.assetID == assetID,
                      store.book(assetID: assetID)?.libraryID == libraryID,
                      let statistics = reader.currentStatistics else { throw CancellationError() }
                guard store.updateStatistics(assetID: assetID, statistics: statistics) else { throw JobError.writeFailed }
                loading[assetID] = nil
                start(book: book, snapshot: snapshot, chapters: reader.currentChapters,
                      scope: .wholeBook, settings: settings, apiKey: apiKey, store: store)
            } catch is CancellationError {} catch {
                if generations[assetID] == generation { failures[assetID] = "摘要失败：\(error.localizedDescription)" }
            }
            onUpdate?(assetID)
        }
        onUpdate?(assetID)
    }

    func start(book: Book, snapshot: ReadingSnapshot, chapters: [BookPreprocessor.Chapter],
               scope: KnowledgeScope, settings: AppSettings, apiKey: String, store: ConversationStore) {
        let key = book.assetID
        guard tasks[key] == nil, let stored = store.book(assetID: key), let original = stored.study,
              original.statistics.sourceHash == snapshot.sourceHash else { return }
        let generation = UUID(), libraryID = stored.libraryID
        failures[key] = nil
        generations[key] = generation
        let sections = original.allowedSections(snapshot: snapshot, scope: scope)
        let processor = processOverride
        tasks[key] = Task {
            defer { if generations[key] == generation { tasks[key] = nil; generations[key] = nil; onUpdate?(key) } }
            @MainActor func current() throws -> BookStudy {
                try Task.checkCancellation()
                guard generations[key] == generation, let saved = store.book(assetID: key), saved.libraryID == libraryID,
                      let study = saved.study, study.statistics.sourceHash == snapshot.sourceHash,
                      study.statistics.structureVersion == original.statistics.structureVersion else { throw CancellationError() }
                return study
            }
            @MainActor func save(_ study: BookStudy) throws {
                _ = try current()
                guard store.saveStudy(assetID: key, study: study) else { throw JobError.writeFailed }
                onUpdate?(key)
            }
            let summarizer = ChapterSummarizer(characterBudget: settings.maxContextCharacters, contextTokens: settings.summaryContextTokens, outputTokens: min(2048, settings.outputTokens)) { messages, output in
                let result = try await ChatClient(baseURL: settings.baseURL, apiKey: apiKey, requiresAPIKey: settings.requiresAPIKey, sendsThinking: settings.sendsThinking).complete(
                    model: settings.model, messages: messages, thinking: settings.thinkingLevel.thinkingMode, temperature: settings.sendsTemperature ? settings.temperature : nil, maxTokens: output, requireComplete: true)
                return result.0
            }
            @MainActor func generate(_ text: String, title: String) async throws -> String {
                let result: String
                if let processor { result = try await processor(text, title) }
                else { result = try await summarizer.summarize(text, title: title) }
                _ = try current()
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChapterSummarizer.Failure.empty }
                return result
            }
            do {
                var study = try current()
                study.status = "正在准备章节摘要 · 已完成 \(study.completedCount)/\(study.statistics.sections.count) 个章节/区段"
                try save(study)
                for section in sections {
                    study = try current()
                    if study.digest(for: section) != nil { continue }
                    let index = study.statistics.sections.firstIndex(where: { $0.id == section.id })! + 1
                    study.status = "正在生成第 \(index)/\(study.statistics.sections.count) 个章节/区段 · 已完成 \(study.completedCount) 个章节/区段"
                    try save(study)
                    let text = BookStatistics.text(chapters: chapters, from: section.start, through: section.end)
                    guard BookPreprocessor.contentHash(of: text) == section.sourceHash else { throw CancellationError() }
                    let result = try await generate(text, title: "本章：" + section.title)
                    study = try current()
                    study.chapters.removeAll { $0.sectionID == section.id }
                    study.chapters.append(ChapterDigest(section: section, text: result, model: settings.model))
                    try save(study)
                }
                study = try current()
                if scope == .wholeBook, (study.whole == nil || study.wholeModel == nil), study.completedCount == study.statistics.sections.count, !sections.isEmpty {
                    study.status = "正在汇总全书摘要 · \(study.completedCount) 个章节/区段已完成"; try save(study)
                    let material = study.statistics.sections.map { "## \($0.title)\n\(study.digest(for: $0)!.text)" }.joined(separator: "\n\n")
                    let result = try await generate(material, title: "全书章节摘要汇总：" + book.title)
                    study = try current()
                    study.whole = ReadingSummary(text: result, sourceHash: snapshot.sourceHash,
                        boundary: sections.last!.end, scope: .wholeBook, coverageLabel: "全书摘要")
                    study.wholeModel = settings.model
                }
                study.status = "摘要 \(study.completedCount)/\(study.statistics.sections.count) · " + (study.whole == nil ? "全书摘要待汇总" : "全书摘要已完成")
                if sections.isEmpty { study.status += " · 当前范围没有完整章节，当前章使用已读原文" }
                try save(study)
            } catch is CancellationError {
                if generations[key] == generation, var study = store.book(assetID: key)?.study {
                    study.status = "原文或任务已变化，生成已停止"; _ = store.saveStudy(assetID: key, study: study); onUpdate?(key)
                }
            } catch {
                if var study = try? current() {
                    study.status = "摘要失败：\(error.localizedDescription)；已完成章节保留"
                    if !store.saveStudy(assetID: key, study: study) { failures[key] = study.status }
                    onUpdate?(key)
                }
            }
        }
    }
    func cancel(assetID: String, store: ConversationStore) {
        generations[assetID] = nil
        failures[assetID] = nil
        loading.removeValue(forKey: assetID)?.cancel()
        tasks.removeValue(forKey: assetID)?.cancel()
        if var study = store.book(assetID: assetID)?.study {
            study.status = "摘要已取消；已完成章节保留，可继续生成"
            _ = store.saveStudy(assetID: assetID, study: study); onUpdate?(assetID)
        }
    }
    enum JobError: Error, LocalizedError {
        case writeFailed
        var errorDescription: String? { "摘要保存失败，已停止后续请求。" }
    }
}
