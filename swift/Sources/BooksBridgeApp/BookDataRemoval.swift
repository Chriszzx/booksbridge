import BooksBridgeCore
import BooksBridgeLLM
import Foundation

/// Only allowlisted BooksBridge-owned files are moved or removed. A source path
/// is never accepted by this service, including when the source has aliases.
struct BookDataRemoval {
    let directory: URL
    var fileManager: FileManager = .default

    enum Failure: Error, LocalizedError {
        case unsafeCachePath, writeFailed(String), cleanupFailed
        var errorDescription: String? {
            switch self {
            case .unsafeCachePath: "缓存目录指向 BooksBridge 数据目录之外，已停止删除。"
            case .writeFailed(let message): "保存删除结果失败，书籍记录已保留：\(message)"
            case .cleanupFailed: "书籍记录已删除，但部分缓存清理失败。"
            }
        }
    }

    static func mapFilename(assetID: String) -> String {
        BookPreprocessor.contentHash(of: assetID).replacingOccurrences(of: ":", with: "-") + ".json"
    }

    func removeBook(assetID: String, store: ConversationStore) throws {
        guard let book = store.book(assetID: assetID), book.assetID == assetID else { return }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var files: [URL] = []
        for id in book.sourceAssetIDs {
            files.append(directory.appendingPathComponent("maps").appendingPathComponent(Self.mapFilename(assetID: id)))
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                for ext in ["json", "md"] { files.append(directory.appendingPathComponent("knowledge").appendingPathComponent(id + "." + ext)) }
            }
        }
        files = Array(Set(files)).filter { fileManager.fileExists(atPath: $0.path) }
        for file in files where !file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") {
            throw Failure.unsafeCachePath
        }
        let staging = directory.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for (i, file) in files.enumerated() {
                let target = staging.appendingPathComponent(String(i))
                try fileManager.moveItem(at: file, to: target)
                moved.append((file, target))
            }
            guard store.removeBook(assetID: assetID) else { throw Failure.writeFailed(store.lastWriteError ?? "记录不存在") }
        } catch {
            for item in moved.reversed() { try fileManager.moveItem(at: item.to, to: item.from) }
            try fileManager.removeItem(at: staging)
            throw error
        }
        do { try fileManager.removeItem(at: staging) }
        catch { throw Failure.cleanupFailed }
    }
}
