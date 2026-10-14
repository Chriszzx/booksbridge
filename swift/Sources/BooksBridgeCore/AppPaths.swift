import Foundation

/// BooksBridge 自己的路径。
public enum AppPaths {
    /// 应用支持目录：`~/Library/Application Support/BooksBridge`
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BooksBridge", isDirectory: true)
    }

    /// 会话与书库存放位置。
    public static var storeFile: URL {
        supportDirectory.appendingPathComponent("store.json")
    }

    /// 确保支持目录存在。
    @discardableResult
    public static func ensureSupportDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            NSLog("[BooksBridge] 无法创建数据目录: \(error.localizedDescription)")
            return false
        }
    }
}
