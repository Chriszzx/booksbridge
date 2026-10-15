import Foundation

/// 仅保存导航显示偏好，不改动书籍、对话和模型上下文。
public final class SidebarLayoutStore {
    private let defaults: UserDefaults
    private static let sidebarKey = "sidebar.collapsed"
    private static let booksKey = "sidebar.collapsedBooks"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isCollapsed: Bool { defaults.bool(forKey: Self.sidebarKey) }
    public var collapsedBooks: Set<String> { Set(defaults.stringArray(forKey: Self.booksKey) ?? []) }

    public func setCollapsed(_ collapsed: Bool) { defaults.set(collapsed, forKey: Self.sidebarKey) }

    public func setBookCollapsed(assetID: String, collapsed: Bool) {
        var books = collapsedBooks
        if collapsed { books.insert(assetID) } else { books.remove(assetID) }
        defaults.set(books.sorted(), forKey: Self.booksKey)
    }

    public var payload: [String: Any] {
        ["collapsed": isCollapsed, "collapsedBooks": collapsedBooks.sorted()]
    }
}
