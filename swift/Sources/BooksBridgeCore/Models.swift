import Foundation

/// 书籍内容类型。取值来自 `ZBKLIBRARYASSET.ZCONTENTTYPE`。
public enum BookContentType: Int, Sendable {
    case epub = 1
    case pdf = 3
    case audiobook = 5

    public var label: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .audiobook: "有声书"
        }
    }
}

/// 书库里的一本书。
public struct Book: Sendable, Equatable {
    public let assetID: String
    public let title: String
    public let author: String
    /// 0.0 ~ 1.0 的阅读进度。
    public let progress: Double
    public let contentType: BookContentType
    /// 书籍文件（或解包目录）在磁盘上的路径。
    public let path: String?
    public let lastOpened: Date?

    public init(
        assetID: String,
        title: String,
        author: String,
        progress: Double,
        contentType: BookContentType,
        path: String?,
        lastOpened: Date?
    ) {
        self.assetID = assetID
        self.title = title
        self.author = author
        self.progress = progress
        self.contentType = contentType
        self.path = path
        self.lastOpened = lastOpened
    }

    /// 作者字段常有 "UnknownAuthor" 之类的占位值，也常带不可见字符与多余空白。
    ///
    /// 实测坑：图书 App 里有些书的作者是 `\u{E83A}UnknownAuthor`——
    /// 开头带一个 Unicode 私有区字符（U+E000–U+F8FF，常被用作图标字体占位）。
    /// 直接和 "UnknownAuthor" 比较会漏判，因此先剥掉所有控制/格式/私有区字符。
    public var displayAuthor: String? {
        var cleaned = author.unicodeScalars.filter { scalar in
            // 去掉控制字符、格式字符、代理区与私有使用区
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse:
                return false
            default:
                return true
            }
        }
        let trimmed = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknownauthor" else { return nil }
        return trimmed
    }

    public var displayTitle: String { "《\(title)》" }
}

/// 阅读位置。
///
/// 实测结论：图书 App 对每本书只保留**一条** `ZANNOTATIONTYPE = 3` 的记录，
/// 并在翻页时**原地更新**，因此这条记录就是"当前读到哪"。
/// EPUB 的位置是标准 EPUB CFI；PDF 的位置是页码形式的字符串。
public struct ReadingPosition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case epubCFI(String)
        case page(Int)
        case other(String)
        case unknown
    }

    public let kind: Kind
    public let raw: String
    public let updated: Date?
    /// 用户最近一次划选/高亮的文本，如果这条记录携带的话。
    public let selectedText: String?

    public init(kind: Kind, raw: String, updated: Date?, selectedText: String?) {
        self.kind = kind
        self.raw = raw
        self.updated = updated
        self.selectedText = selectedText
    }

    public var cfi: String? {
        if case .epubCFI(let s) = kind { return s }
        return nil
    }
}

/// 一次完整的"用户此刻在读什么"快照。
///
/// 这是喂给 LLM 的上下文来源，也是 UI 渲染的唯一数据源。
public struct ReadingContext: Sendable {
    /// Visible page labels from the reader chrome, not a source-text offset.
    public let pageIdentity: String?
    public let book: Book
    public let position: ReadingPosition?
    /// 屏幕上此刻可见的正文（来自辅助功能 API），可能为 nil（未授权或不在阅读视图）。
    public let visibleText: [String]
    /// 用户当前划选的文本。
    public let selection: String?
    public let selectionIsExact: Bool
    public let capturedAt: Date

    public init(
        book: Book,
        position: ReadingPosition?,
        visibleText: [String],
        selection: String?,
        selectionIsExact: Bool = false,
        capturedAt: Date = Date(),
        pageIdentity: String? = nil
    ) {
        self.book = book
        self.position = position
        self.visibleText = visibleText
        self.selection = selection
        self.selectionIsExact = selectionIsExact
        self.capturedAt = capturedAt
        self.pageIdentity = pageIdentity
    }
}
