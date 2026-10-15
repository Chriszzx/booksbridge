import CryptoKit
import Foundation

/// File identity is independent of the displayed title. Fingerprints detect exact copies;
/// they never merge reading positions or conversations without an explicit choice.
public struct BookSourceIdentity: Codable, Sendable, Equatable {
    public let canonicalPath: String
    public let resourceID: String?
    public let volumeID: String?
    public let fingerprint: String

    public static func read(at url: URL) throws -> Self {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .volumeUUIDStringKey]
        let values = try root.resourceValues(forKeys: keys)
        var files = [root]
        if values.isDirectory == true {
            var failure: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
                throw CocoaError(.fileReadUnknown)
            }
            files = try enumerator.compactMap { value -> URL? in
                guard let file = value as? URL else { return nil }
                let attributes = try file.resourceValues(forKeys: keys)
                guard attributes.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                return attributes.isRegularFile == true ? file : nil
            }.sorted { $0.path < $1.path }
            if let failure { throw failure }
        }
        guard !files.isEmpty else { throw CocoaError(.fileReadUnknown) }
        var hash = SHA256()
        for file in files {
            try Task.checkCancellation()
            // Foundation's enumerator can return /private/var while the root URL
            // uses /var. Normalize both sides before taking a package-relative path.
            let normalized = file.standardizedFileURL.resolvingSymlinksInPath()
            if values.isDirectory == true, !normalized.path.hasPrefix(root.path + "/") { throw CocoaError(.fileReadInvalidFileName) }
            let relative = values.isDirectory == true ? String(normalized.path.dropFirst(root.path.count + 1)) : "source"
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(size):".utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 524_288), !chunk.isEmpty {
                try Task.checkCancellation(); hash.update(data: chunk)
            }
        }
        return Self(canonicalPath: root.path,
                    resourceID: (values.fileResourceIdentifier as? Data)?.base64EncodedString(),
                    volumeID: values.volumeUUIDString,
                    fingerprint: "file-sha256-v1:" + hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public func isSameFile(as other: Self) -> Bool {
        if let resourceID, let volumeID, resourceID == other.resourceID, volumeID == other.volumeID { return true }
        return canonicalPath == other.canonicalPath
    }

    public static func contains(documentURL: URL, sourcePath: String) -> Bool {
        guard documentURL.isFileURL else { return false }
        let path = URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath().path
        let document = documentURL.standardizedFileURL.resolvingSymlinksInPath().path
        return document == path || document.hasPrefix(path + "/")
    }
}

public extension Book {
    func identified(by assetID: String) -> Book {
        Book(assetID: assetID, title: title, author: author, progress: progress, contentType: contentType, path: path, lastOpened: lastOpened)
    }
}

public extension ReadingContext {
    func identified(by assetID: String) -> ReadingContext {
        ReadingContext(book: book.identified(by: assetID), position: position, visibleText: visibleText, selection: selection, selectionIsExact: selectionIsExact, capturedAt: capturedAt)
    }
}
