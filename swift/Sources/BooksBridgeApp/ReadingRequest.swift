import Foundation
import BooksBridgeLLM

struct ReadingCommand {
    let refreshOnlyOrFirst: Bool
    let question: String
    init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text.dropFirst(4)
        refreshOnlyOrFirst = text.hasPrefix("/now") && (tail.isEmpty || tail.first?.isWhitespace == true)
        question = refreshOnlyOrFirst ? String(tail).trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

struct ConfirmedReference {
    let token: String
    let assetID: String
    let conversationID: String
    let sourceHash: String
    let text: String
    /// Persisted quotes must still be inside the refreshed scope when retrying an older turn.
    static func canReplay(question: String, reading: ScopedReading) -> Bool {
        guard let marker = question.range(of: "\n\n引用：\n") else { return true }
        let quote = ScopedReading.normalized(String(question[marker.upperBound...]))
        return !quote.isEmpty && reading.chapters.contains { ScopedReading.normalized($0.text).contains(quote) }
    }

    func validated(token: String, confirmed: Bool, snapshot: ReadingSnapshot,
                   conversationID: String, reading: ScopedReading) -> String? {
        guard confirmed, token == self.token, assetID == snapshot.assetID,
              conversationID == self.conversationID, sourceHash == snapshot.sourceHash,
              !ScopedReading.normalized(text).isEmpty,
              reading.chapters.contains(where: { ScopedReading.normalized($0.text).contains(ScopedReading.normalized(text)) }) else { return nil }
        return text
    }
}
