import Foundation
import BooksBridgeCore
import BooksBridgeLLM

/// Book-scoped analysis with no chat history or tools. All writes go through the app store.
@MainActor
final class StructureJobs {
    var completionOverride: ChapterClassifier.Completion?
    var onUpdate: ((String) -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var failures: [String: String] = [:]
    func isRunning(_ assetID: String) -> Bool { tasks[assetID] != nil }
    func failure(_ assetID: String) -> String? { failures[assetID] }

    func start(book: Book, settings: AppSettings, apiKey: String, store: ConversationStore, mapDirectory: URL? = nil) {
        let key = book.assetID
        guard tasks[key] == nil, let libraryID = store.book(assetID: key)?.libraryID else { return }
        let generation = UUID(), completion = completionOverride
        generations[key] = generation; failures[key] = nil
        tasks[key] = Task {
            defer { if generations[key] == generation { tasks[key] = nil; generations[key] = nil; onUpdate?(key) } }
            @MainActor func valid() throws {
                try Task.checkCancellation()
                guard generations[key] == generation, store.book(assetID: key)?.libraryID == libraryID else { throw CancellationError() }
            }
            @MainActor func save(_ study: BookStudy) throws {
                try valid()
                guard store.saveStudy(assetID: key, study: study) else { throw SummaryJobs.JobError.writeFailed }
                onUpdate?(key)
            }
            do {
                if var study = store.book(assetID: key)?.study {
                    study.structureStatus = "正在读取本地章节候选"; try save(study)
                }
                let loader = ReadingAssistant(settings: settings, apiKey: "", knowledgeDirectory: mapDirectory)
                _ = try await loader.refresh(book: book, live: nil, previous: nil, persistMap: false)
                try valid()
                guard let local = loader.currentStatistics, let map = loader.currentMap else { throw ChapterStructure.Failure.invalid }
                guard store.updateStatistics(assetID: key, statistics: local), let base = store.book(assetID: key)?.study?.statistics else { throw SummaryJobs.JobError.writeFailed }
                let source = loader.currentChapters
                let candidates = await Task.detached { ChapterStructure.candidates(map: map, chapters: source) }.value
                try valid()
                let classifier = ChapterClassifier(contextTokens: settings.summaryContextTokens, characterBudget: settings.maxContextCharacters) { messages, output in
                    if let completion { return try await completion(messages, output) }
                    return try await ChatClient(baseURL: settings.baseURL, apiKey: apiKey, requiresAPIKey: settings.requiresAPIKey, sendsThinking: settings.sendsThinking).complete(model: settings.model, messages: messages,
                        thinking: settings.thinkingLevel.thinkingMode, temperature: settings.sendsTemperature ? settings.temperature : nil, maxTokens: min(output, settings.outputTokens), requireComplete: true).0
                }
                let proposal = try await classifier.classify(candidates: candidates, chapters: source, base: base, model: settings.model) { @MainActor [weak self] done,total in
                    try self?.progress(key: key, libraryID: libraryID, generation: generation, version: base.structureVersion,
                                             done: done, total: total, store: store)
                }
                try valid()
                guard var study = store.book(assetID: key)?.study, study.statistics.structureVersion == base.structureVersion else { throw CancellationError() }
                study.proposedStructure = proposal
                study.structureStatus = "章节建议待确认 · \(proposal.statistics.sections.count) 个区段 · \(proposal.uncertainCount) 个不确定节点"
                try save(study)
            } catch is CancellationError {
                if generations[key] == generation, store.book(assetID: key)?.libraryID == libraryID, var study = store.book(assetID: key)?.study {
                    study.structureStatus = "原文或章节结构已变化，分析已停止"; _ = store.saveStudy(assetID: key, study: study)
                }
            } catch {
                if generations[key] == generation, store.book(assetID: key)?.libraryID == libraryID {
                    let status = "章节分析失败：\(error.localizedDescription)"
                    failures[key] = status
                    if var study = store.book(assetID: key)?.study { study.structureStatus = status; _ = store.saveStudy(assetID: key, study: study) }
                    onUpdate?(key)
                }
            }
        }
        onUpdate?(key)
    }
    private func progress(key: String, libraryID: UUID, generation: UUID, version: String, done: Int, total: Int, store: ConversationStore) throws {
        try Task.checkCancellation()
        guard generations[key] == generation, let book = store.book(assetID: key), book.libraryID == libraryID,
              var study = book.study, study.statistics.structureVersion == version else { throw CancellationError() }
        study.structureStatus = "正在分析章节 \(done)/\(total) · 原有结构继续使用"
        guard store.saveStudy(assetID: key, study: study) else { throw SummaryJobs.JobError.writeFailed }
        onUpdate?(key)
    }
    func cancel(_ assetID: String, store: ConversationStore) {
        generations[assetID] = nil; tasks.removeValue(forKey: assetID)?.cancel(); failures[assetID] = nil
        if var study = store.book(assetID: assetID)?.study {
            study.structureStatus = "章节分析已取消，原有结构保留"; _ = store.saveStudy(assetID: assetID, study: study)
        }
        onUpdate?(assetID)
    }
}
