import ApplicationServices
import AppKit
import Foundation

/// 本 App 需要的两项系统权限。
///
/// 这是一个"骨架期就必须做对"的部分：权限缺失时的行为必须是
/// **可检测、可解释、可引导**，而不是静默失败或崩溃。
public enum Permission: String, Sendable, CaseIterable {
    /// 完全磁盘访问权限：读取 `~/Library/Containers/com.apple.iBooksX` 必需。
    case fullDiskAccess
    /// 辅助功能权限：读取图书 App 窗口内的正文与选中文本必需。
    case accessibility

    public var title: String {
        switch self {
        case .fullDiskAccess: "完全磁盘访问权限"
        case .accessibility: "辅助功能权限"
        }
    }

    public var reason: String {
        switch self {
        case .fullDiskAccess:
            "用于读取图书 App 的书库与阅读位置数据。macOS 会拦截对其它 App 沙盒容器的访问，需要你手动授权。"
        case .accessibility:
            "用于读取当前书页上可见的正文，以及你划选的文字。这一步不读取任何按键，只读取屏幕上的文字内容。"
        }
    }

    /// 系统设置里对应的锚点，用于一键跳转。
    var settingsAnchor: String {
        switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

/// 权限状态。
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// 无法判定（例如容器尚不存在）。
    case unknown(String)

    public var isGranted: Bool { self == .granted }

    public var label: String {
        switch self {
        case .granted: "已授权"
        case .denied: "未授权"
        case .unknown(let why): "无法判定（\(why)）"
        }
    }
}

/// 权限检查与引导。
public struct Permissions {
    private let paths: BooksPaths
    /// 图书 App 是否安装。默认探测系统路径，测试可注入以摆脱环境依赖。
    private let booksInstalled: Bool

    public init(paths: BooksPaths = BooksPaths(), booksInstalled: Bool? = nil) {
        self.paths = paths
        self.booksInstalled = booksInstalled ?? Self.detectBooksInstalled()
    }

    // MARK: - 完全磁盘访问

    /// 通过实际尝试读取受 TCC 保护的目录来判断权限。
    ///
    /// 两个关键点，都是实测踩出来的：
    ///
    /// 1. **不能用 `FileManager.isReadableFile`**，它对 TCC 拦截会返回 true，
    ///    必须真正 `opendir` / `open`。
    ///
    /// 2. **`ENOENT` 不能直接当成"数据不存在"**。受 TCC 保护时，
    ///    系统会让 `opendir` 返回 `ENOENT`——与路径真的不存在无法从 errno 区分。
    ///    早期实现据此报「图书数据尚未创建」，把"没权限"误报成"还没在图书 App
    ///    里打开过书"，让用户往完全错误的方向排查。
    ///
    /// 区分办法是加一个**对照组**：用户主目录不受 TCC 保护，一定可见。
    /// 主目录可见而图书容器不可见 → 只可能是被拦截，判定为未授权。
    public func fullDiskAccessStatus() -> PermissionStatus {
        // 对照组：主目录必须可见，否则是环境异常而非权限问题
        let homeVisible = Self.canOpen(path: paths.home.path, isDirectory: true)
        guard homeVisible else {
            return .unknown("无法访问用户主目录")
        }

        for directory in [paths.container, paths.documents.appendingPathComponent("BKLibrary")] {
            if let code = Self.openFailure(path: directory.path, isDirectory: true) {
                return Self.readFailure(code, booksInstalled: booksInstalled)
            }
        }

        guard let database = paths.libraryDatabase() else {
            // 容器可读却没有书库文件：这次是真的还没创建
            return .unknown("图书书库尚未创建，请先在图书 App 中打开一本书")
        }
        if let code = Self.openFailure(path: database.path, isDirectory: false) {
            return Self.readFailure(code, booksInstalled: booksInstalled)
        }
        do {
            _ = try SQLite.query(path: database.path, "SELECT name FROM sqlite_master LIMIT 1")
            return .granted
        } catch {
            return .unknown("书库数据库读取失败：\(error)")
        }
    }

    /// 尝试打开路径，成功返回 nil，失败返回 errno。
    private static func openFailure(path: String, isDirectory: Bool) -> Int32? {
        if isDirectory {
            guard let dir = opendir(path) else { return errno }
            closedir(dir)
            return nil
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return errno }
        close(fd)
        return nil
    }

    private static func canOpen(path: String, isDirectory: Bool) -> Bool {
        openFailure(path: path, isDirectory: isDirectory) == nil
    }

    /// 区分「被 TCC 拦截」与「数据本来就不存在」。
    ///
    /// 这两种情况的 errno 都是 `ENOENT`，无法从错误码区分。
    /// 但有一个可靠的外部信号：**图书 App 是否安装**。
    /// 它位于 `/System/Applications`，不受 TCC 保护，可以安全探测。
    ///
    /// - 装了图书 App，却读不到它的容器 → 只可能是被拦截 → 未授权
    /// - 没装图书 App → 数据本来就不存在 → 无法判定（不误导用户去查权限）
    private static func readFailure(_ code: Int32, booksInstalled: Bool) -> PermissionStatus {
        switch code {
        case EPERM, EACCES:
            return .denied
        case ENOENT:
            return booksInstalled
                ? .denied
                : .unknown("尚未安装图书 App，或图书数据还未创建")
        default:
            return .unknown(String(cString: strerror(code)))
        }
    }

    /// 探测图书 App 是否已安装。
    ///
    /// 只查最常见的位置；查不到不等于没装（用户可能移动过），
    /// 因此这个信号只用于"降低误报"，不作为肯定性结论。
    static func detectBooksInstalled() -> Bool {
        let candidates = [
            "/System/Applications/Books.app",
            "/Applications/Books.app",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - 辅助功能

    /// `AXIsProcessTrusted` 只反映当前进程是否被信任，不会弹窗。
    public func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// 请求辅助功能权限。系统会弹出一次引导弹窗（首次），之后只能去系统设置里开。
    ///
    /// 这里直接用字面量键名而非常量 `kAXTrustedCheckOptionPrompt`：
    /// 后者是 Swift 6 并发模型下的全局可变状态，从非隔离上下文引用会报错。
    /// 字符串的值是稳定的 ABI（"AXTrustedCheckOptionPrompt"）。
    @discardableResult
    public func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 真正 open 一个路径，返回可读的结论与 errno。
    ///
    /// `FileManager.isReadableFile` 对 TCC 拦截会误报 true，所以必须真读。
    public static func probeRead(_ path: String) -> String {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return "可读 ✅"
        }
        let code = errno
        if code == ENOENT { return "不存在" }
        let name = String(cString: strerror(code))
        return code == EPERM || code == EACCES
            ? "被拒绝 ❌ (errno \(code) \(name))"
            : "失败 ⚠️ (errno \(code) \(name))"
    }

    // MARK: - 汇总

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .fullDiskAccess: fullDiskAccessStatus()
        case .accessibility: accessibilityStatus()
        }
    }

    public func allStatuses() -> [(Permission, PermissionStatus)] {
        Permission.allCases.map { ($0, status(of: $0)) }
    }

    /// 打开系统设置对应的隐私面板，让用户自己勾选。
    ///
    /// 用 `x-apple.systempreferences:` 直链，比让用户自己找路径友好得多。
    public func openSettings(for permission: Permission) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }
}
