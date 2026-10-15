import Foundation

/// 仅保存导航显示偏好，不改动书籍、对话和模型上下文。
public final class SidebarLayoutStore {
    private let defaults: UserDefaults
    private static let sidebarKey = "sidebar.collapsed"
    private static let booksKey = "sidebar.collapsedBooks"
    private static let widthKey = "sidebar.width"
    static let defaultWidth: Double = 248
    static let minimumWidth: Double = 210
    static let maximumWidth: Double = 480

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isCollapsed: Bool { defaults.bool(forKey: Self.sidebarKey) }
    public var collapsedBooks: Set<String> { Set(defaults.stringArray(forKey: Self.booksKey) ?? []) }
    public var width: Double {
        guard let value = defaults.object(forKey: Self.widthKey) as? Double, value.isFinite else { return Self.defaultWidth }
        return min(Self.maximumWidth, max(Self.minimumWidth, value.rounded()))
    }

    public func setWidth(_ width: Double) {
        guard width.isFinite else { return }
        defaults.set(min(Self.maximumWidth, max(Self.minimumWidth, width.rounded())), forKey: Self.widthKey)
    }

    public func setCollapsed(_ collapsed: Bool) { defaults.set(collapsed, forKey: Self.sidebarKey) }

    public func setBookCollapsed(assetID: String, collapsed: Bool) {
        var books = collapsedBooks
        if collapsed { books.insert(assetID) } else { books.remove(assetID) }
        defaults.set(books.sorted(), forKey: Self.booksKey)
    }

    public func forgetBook(assetID: String) { setBookCollapsed(assetID: assetID, collapsed: false) }

    public var payload: [String: Any] {
        ["collapsed": isCollapsed, "collapsedBooks": collapsedBooks.sorted(), "width": width]
    }
}
