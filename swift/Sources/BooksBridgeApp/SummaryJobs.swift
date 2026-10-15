import Foundation
import BooksBridgeCore
import BooksBridgeLLM

/// Background jobs belong to a conversation, not a view. Inputs are already scoped.
@MainActor
final class SummaryJobs {
    typealias Processor = @Sendable (Book, [BookPreprocessor.Chapter], @escaping @Sendable (BookPreprocessor.Progress) -> Void) async throws -> BookKnowledge
    var processOverride: Processor?
    var onUpdate: ((String, String, String, ReadingSummary?) -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private func key(_ book: String, _ conversation: String) -> String { book + "/" + conversation }
    func isRunning(assetID: String, conversationID: String) -> Bool { tasks[key(assetID, conversationID)] != nil }

    func start(book: Book, conversationID: String, snapshot: ReadingSnapshot, reading: ScopedReading,
               scope: KnowledgeScope, settings: AppSettings, apiKey: String) {
        let key = key(book.assetID, conversationID)
        guard tasks[key] == nil else { return }
        let generation = UUID(); generations[key] = generation
        onUpdate?(book.assetID, conversationID, "正在生成范围摘要", nil)
        let processor = processOverride
        tasks[key] = Task {
            defer { if generations[key] == generation { tasks[key] = nil; generations[key] = nil } }
            do {
                let progress: @Sendable (BookPreprocessor.Progress) -> Void = { update in
                    Task { @MainActor in
                        guard self.generations[key] == generation else { return }
                        let status: String
                        switch update {
                        case .started(let count): status = "正在生成摘要 0/\(count)"
                        case .chunkDone(let done, let count): status = "正在生成摘要 \(done)/\(count)"
                        case .reducing: status = "正在汇总范围摘要"
                        case .finished: return
                        }
                        self.onUpdate?(book.assetID, conversationID, status, nil)
                    }
                }
                let result: BookKnowledge
                if let processor { result = try await processor(book, reading.chapters, progress) }
                else { result = try await BookPreprocessor(client: ChatClient(baseURL: settings.baseURL, apiKey: apiKey), model: settings.model)
                    .process(book: book, chapters: reading.chapters, scopeDescription: scope.label + " · " + snapshot.chapterTitle, onProgress: progress) }
                try Task.checkCancellation()
                guard !result.readme.isEmpty else { throw ReadingAssistant.AssistantError.notLoaded }
                let summary = ReadingSummary(text: result.readme, sourceHash: snapshot.sourceHash,
                    boundary: reading.boundary, scope: scope, generatedAt: Date(),
                    coverageLabel: scope == .wholeBook ? "全书" : "书首 → " + snapshot.chapterTitle + (scope == .currentChapter ? "章末" : String(format: " · %.1f%%", snapshot.progress * 100)))
                onUpdate?(book.assetID, conversationID, "摘要已完成 · \(scope.label)", summary)
            } catch {
                guard generations[key] == generation, !Task.isCancelled else { return }
                onUpdate?(book.assetID, conversationID, "摘要失败：\(error)", nil)
            }
        }
    }
    func cancel(assetID: String, conversationID: String) {
        let key = key(assetID, conversationID)
        generations[key] = nil
        tasks.removeValue(forKey: key)?.cancel()
        onUpdate?(assetID, conversationID, "摘要已取消", nil)
    }
}
