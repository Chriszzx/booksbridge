import CryptoKit
import Foundation

/// A manual binding is limited to this exact visible page. Reusing a window for
/// another same-titled book must never silently reuse its previous confirmation.
public final class ActiveBookResolver: @unchecked Sendable {
    public static let shared = ActiveBookResolver()
    private let lock = NSLock()
    private var confirmation: (token: String, assetID: String)?
    public init() {}

    public func token(for snapshot: AccessibilityReader.Snapshot) -> String {
        let parts = [snapshot.windowIdentity ?? "", snapshot.windowTitles.joined(separator: "\n"), snapshot.documentURLs.map(\.absoluteString).sorted().joined(separator: "\n"), snapshot.joinedText]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func confirm(snapshot: AccessibilityReader.Snapshot, assetID: String) {
        lock.withLock { confirmation = (token(for: snapshot), assetID) }
    }

    public func forget(assetIDs: [String]) {
        lock.withLock { if let confirmation, assetIDs.contains(confirmation.assetID) { self.confirmation = nil } }
    }

    public func resolve(snapshot: AccessibilityReader.Snapshot, books: [Book]) -> Book? {
        let fileMatches = books.filter { book in
            guard let path = book.path else { return false }
            return snapshot.documentURLs.contains { BookSourceIdentity.contains(documentURL: $0, sourcePath: path) }
        }
        if fileMatches.count == 1 { return fileMatches.first }
        // A reported but unknown document must not fall back to a same-named book.
        let candidates = fileMatches.isEmpty ? books : fileMatches
        if let selected = lock.withLock({ confirmation }), selected.token == token(for: snapshot) {
            return candidates.first { $0.assetID == selected.assetID }
        }
        guard snapshot.documentURLs.isEmpty, let title = snapshot.windowTitles.first else { return nil }
        let matches = books.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines) }
        return matches.count == 1 ? matches.first : nil
    }
}
