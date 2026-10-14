import Foundation

/// Apple Books 在磁盘上的位置集合。
///
/// 所有路径都基于实测（macOS 27 / 图书 9.0）：
/// - 书库与阅读位置在沙盒容器的 `Data/Documents` 下；
/// - 当前在读书的 assetID 记在容器偏好设置 plist 里；
/// - EPUB 本体在 iCloud 容器 `iCloud~com~apple~iBooks/Documents`。
public struct BooksPaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var container: URL {
        home.appendingPathComponent("Library/Containers/com.apple.iBooksX/Data")
    }

    public var documents: URL {
        container.appendingPathComponent("Documents")
    }

    public var preferences: URL {
        container.appendingPathComponent("Library/Preferences/com.apple.iBooksX.plist")
    }

    public var iCloudDocuments: URL {
        home.appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")
    }

    /// 书库数据库（书名 / 作者 / 进度 / 文件路径）。返回 nil 表示尚未创建或不可访问。
    public func libraryDatabase() -> URL? {
        firstMatch(in: documents.appendingPathComponent("BKLibrary"), suffix: ".sqlite", prefix: "BKLibrary")
    }

    /// 标注 / 阅读位置数据库。返回 nil 表示该用户从未标注过。
    public func annotationDatabase() -> URL? {
        firstMatch(in: documents.appendingPathComponent("AEAnnotation"), suffix: ".sqlite", prefix: "AEAnnotation")
    }

    /// 需要在变化时被监听的 WAL 文件（实时性来源）。
    public func watchedFiles() -> [URL] {
        var urls: [URL] = []
        for db in [libraryDatabase(), annotationDatabase()].compactMap({ $0 }) {
            // SQLite 在 WAL 模式下，事务提交会改写 -wal；
            // 同时监听 db 本身与其 -shm，覆盖 checkpoint 等场景。
            urls.append(URL(fileURLWithPath: db.path + "-wal"))
            urls.append(db)
        }
        if FileManager.default.fileExists(atPath: preferences.path) {
            urls.append(preferences)
        }
        return urls
    }

    private func firstMatch(in directory: URL, suffix: String, prefix: String) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.path.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
