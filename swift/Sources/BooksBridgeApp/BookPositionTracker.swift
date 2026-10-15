import Foundation
import BooksBridgeCore
import BooksBridgeLLM

/// Verifies foreground observations before the reader disappears into the background.
/// Unimported books stay in bounded memory; only app-owned books are persisted by the host.
@MainActor
final class BookPositionTracker {
    typealias Loader = @MainActor (ReadingContext) async throws -> ReadingSnapshot
    var loadOverride: Loader?
    var onVerified: ((ReadingSnapshot) -> Void)?
    private var observations: [String: ReadingContext] = [:]
    private var snapshots: [String: ReadingSnapshot] = [:]
    private var unverified = Set<String>()
    private var signatures: [String: String] = [:]
    private var generations: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let capacity: Int
    init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    func observe(_ context: ReadingContext) {
        let key = context.book.assetID
        guard context.book.contentType == .epub, context.book.path != nil else { return }
        if let previous = observations[key], previous.capturedAt > context.capturedAt { return }
        let previous = observations[key]
        observations[key] = context
        while observations.count > capacity, let oldest = observations.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key { forget([oldest]) }
        guard observations[key] != nil else { return }
        if context.visibleText.isEmpty {
            if let previous, ReadingPositionEvidence(previous).matches(context, capturedAt: previous.capturedAt), previous.book.path == context.book.path { return }
            invalidate(key)
            return
        }
        let signature = BookPreprocessor.contentHash(of: context.visibleText.joined(separator: "\n"))
        if signatures[key] == signature, let previous, previous.book.path == context.book.path,
           ReadingPositionEvidence(previous) == ReadingPositionEvidence(context), snapshots[key] != nil || tasks[key] != nil { return }
        invalidate(key)
        unverified.insert(key)
        signatures[key] = signature
        let generation = UUID(); generations[key] = generation
        let loader = loadOverride
        tasks[key] = Task { @MainActor in
            defer { if generations[key] == generation { tasks[key] = nil } }
            do {
                let result: ReadingSnapshot
                if let loader { result = try await loader(context) }
                else {
                    let reader = ReadingAssistant(settings: AppSettings(), apiKey: "")
                    result = try await reader.refresh(book: context.book, live: context, previous: nil, persistMap: false)
                }
                try Task.checkCancellation()
                guard generations[key] == generation, result.assetID == key, result.page != nil, !result.reused,
                      let latest = observations[key], latest.book.path == context.book.path,
                      ReadingPositionEvidence(context) == ReadingPositionEvidence(latest) else { return }
                unverified.remove(key)
                snapshots[key] = result
                onVerified?(result)
            } catch { /* An unverified observation must never replace a valid boundary in a conversation. */ }
        }
    }
    /// Waiting here closes the race between adding a book and the foreground parser finishing.
    func position(for sourceIDs: [String], canonicalID: String) async -> ReadingSnapshot? {
        for id in sourceIDs { await tasks[id]?.value }
        return sourceIDs.compactMap { snapshots[$0] }.max { $0.capturedAt < $1.capturedAt }?.identified(by: canonicalID)
    }
    func hasUnverifiedObservation(for sourceIDs: [String]) -> Bool { sourceIDs.contains { unverified.contains($0) } }
    private func invalidate(_ key: String) {
        tasks.removeValue(forKey: key)?.cancel(); generations[key] = nil
        snapshots[key] = nil; signatures[key] = nil
    }
    func forget(_ sourceIDs: [String]) {
        for id in sourceIDs { invalidate(id); observations[id] = nil; unverified.remove(id) }
    }
    func reset() { forget(Array(observations.keys)) }
}
