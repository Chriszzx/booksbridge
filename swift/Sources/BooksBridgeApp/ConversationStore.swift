import BooksBridgeCore
import BooksBridgeLLM
import Foundation

/// 一本书在侧栏里的记录。
///
/// 注意与 `BooksBridgeCore.Book` 的区别：那个是**从图书 App 读到的实时状态**，
/// 这个是**用户主动加进 BooksBridge 的**。两者刻意分开——
/// 检测到但用户没点过的书，只存在于内存里，不会变成 `StoredBook`。
public struct StoredBook: Codable, Sendable, Equatable, Identifiable {
    public var assetID: String
    public var title: String
    public var author: String
    public var addedAt: Date
    public var conversations: [Conversation]

    public var id: String { assetID }

    public init(assetID: String, title: String, author: String, addedAt: Date = Date(), conversations: [Conversation] = []) {
        self.assetID = assetID
        self.title = title
        self.author = author
        self.addedAt = addedAt
        self.conversations = conversations
    }
}

/// 一条对话。
///
/// 骨架期 `messages` 恒为空——LLM 尚未接入。保留字段是为了让持久化结构稳定，
/// 将来接入时不需要迁移数据。
public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [Message]
    /// 首次提问后固定；nil 为尚未提问或旧格式。
    public var scope: KnowledgeScope?
    /// 旧对话没有范围记录，其旧历史保留展示但不送入新的 agent。
    public var scopeHistoryStartIndex: Int?

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [Message] = [],
        scope: KnowledgeScope? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.scope = scope
        self.scopeHistoryStartIndex = nil
    }

    /// 骨架期只有这两个角色，接入 LLM 后直接复用。
    public struct Message: Codable, Sendable, Equatable, Identifiable {
        public enum Role: String, Codable, Sendable {
            case user
            case assistant
        }

        public var id: String
        public var role: Role
        public var text: String
        public var createdAt: Date
        public var boundary: ReadingBoundary?

        public init(id: String = UUID().uuidString, role: Role, text: String, createdAt: Date = Date(), boundary: ReadingBoundary? = nil) {
            self.id = id
            self.role = role
            self.boundary = boundary
            self.text = text
            self.createdAt = createdAt
        }
    }
}

/// 落盘的整体结构。
public struct StoredState: Codable, Sendable, Equatable {
    /// 结构版本，将来做迁移用。
    public var version: Int
    public var books: [StoredBook]
    /// 用户最后停留的位置，重启后恢复。
    public var lastActive: LastActive?

    public struct LastActive: Codable, Sendable, Equatable {
        public var assetID: String
        public var conversationID: String?

        public init(assetID: String, conversationID: String?) {
            self.assetID = assetID
            self.conversationID = conversationID
        }
    }

    public init(version: Int = StoredState.currentVersion, books: [StoredBook] = [], lastActive: LastActive? = nil) {
        self.version = version
        self.books = books
        self.lastActive = lastActive
    }

    public static let currentVersion = 1
}

/// 书库与对话的持久化。
///
/// 设计要点：
/// - **原子写**：先写临时文件再 `replaceItemAt`，避免中途崩溃留下半截 JSON；
/// - **不吞错**：读取失败时区分"文件不存在"（正常，空状态）与"文件损坏"
///   （备份坏文件后从空状态开始，并在日志里说明）；
/// - 所有写操作后立刻落盘。数据量是几十条级别，不需要节流。
public final class ConversationStore {
    public private(set) var state: StoredState

    private let fileURL: URL
    private let fileManager: FileManager

    /// 上一次读取是否遇到损坏文件（供 UI 提示）。
    public private(set) var lastLoadWarning: String?

    public init(fileURL: URL = AppPaths.storeFile, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.state = ConversationStore.load(from: fileURL, fileManager: fileManager)
    }

    // MARK: - 读取

    private static func load(from url: URL, fileManager: FileManager) -> StoredState {
        guard fileManager.fileExists(atPath: url.path) else {
            return StoredState()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StoredState.self, from: data)
        } catch {
            // 损坏：改名备份，从空状态开始。不静默删除用户数据。
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: url, to: backup)
            NSLog("[BooksBridge] store.json 解析失败，已备份到 \(backup.lastPathComponent)：\(error.localizedDescription)")
            return StoredState()
        }
    }

    // MARK: - 写入

    /// 原子写入。临时文件与目标同目录，保证 `replaceItemAt` 是同卷操作。
    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)

            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let temp = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".store-\(UUID().uuidString).tmp")
            try data.write(to: temp, options: .atomic)

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: fileURL)
            }
        } catch {
            NSLog("[BooksBridge] 写入 store 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 查询

    public func book(assetID: String) -> StoredBook? {
        state.books.first { $0.assetID == assetID }
    }

    public func conversation(assetID: String, conversationID: String) -> Conversation? {
        book(assetID: assetID)?.conversations.first { $0.id == conversationID }
    }

    // MARK: - 变更

    /// 把一本书加入书库（已存在则同步标题作者，不覆盖对话）。
    ///
    /// 返回该书当前的记录。
    @discardableResult
    public func addBook(assetID: String, title: String, author: String) -> StoredBook {
        if let index = state.books.firstIndex(where: { $0.assetID == assetID }) {
            // 书名可能因为图书 App 元数据更新而变化，跟着更新。
            // 取出来改完再写回：直接在嵌套下标上同时读写会触发 Swift 独占性冲突。
            var book = state.books[index]
            book.title = title
            book.author = author
            state.books[index] = book
            persist()
            return book
        }
        let book = StoredBook(assetID: assetID, title: title, author: author)
        state.books.append(book)
        persist()
        return book
    }

    /// 在指定书下新建一条对话。标题按该书已有对话数自动编号。
    @discardableResult
    public func createConversation(assetID: String) -> Conversation? {
        guard let index = state.books.firstIndex(where: { $0.assetID == assetID }) else { return nil }
        var book = state.books[index]
        let conversation = Conversation(title: "对话 \(nextConversationNumber(in: book))")
        book.conversations.append(conversation)
        state.books[index] = book
        persist()
        return conversation
    }

    /// 计算下一个对话编号。
    ///
    /// 用"已有标题里出现过的最大编号 + 1"，而不是 `count + 1`——
    /// 否则删掉中间一条后会出现重名。
    private func nextConversationNumber(in book: StoredBook) -> Int {
        var maxNumber = 0
        for conversation in book.conversations {
            let digits = conversation.title.filter(\.isNumber)
            if let value = Int(digits), value > maxNumber {
                maxNumber = value
            }
        }
        return maxNumber + 1
    }

    /// 删除一条对话。
    @discardableResult
    public func deleteConversation(assetID: String, conversationID: String) -> Bool {
        guard let bookIndex = state.books.firstIndex(where: { $0.assetID == assetID }) else { return false }
        var book = state.books[bookIndex]
        let before = book.conversations.count
        book.conversations.removeAll { $0.id == conversationID }
        guard book.conversations.count != before else { return false }
        state.books[bookIndex] = book

        // 被删掉的正好是当前停留的对话时，挪到同书的第一条
        if let active = state.lastActive,
           active.assetID == assetID,
           active.conversationID == conversationID {
            state.lastActive = StoredState.LastActive(
                assetID: assetID,
                conversationID: book.conversations.first?.id
            )
        }
        persist()
        return true
    }

    /// 把一本书移出书库（连同其对话）。
    @discardableResult
    public func removeBook(assetID: String) -> Bool {
        let before = state.books.count
        state.books.removeAll { $0.assetID == assetID }
        guard state.books.count != before else { return false }
        if state.lastActive?.assetID == assetID {
            state.lastActive = state.books.first.map {
                StoredState.LastActive(assetID: $0.assetID, conversationID: $0.conversations.first?.id)
            }
        }
        persist()
        return true
    }

    /// 记录用户当前停留位置。
    public func setActive(assetID: String?, conversationID: String?) {
        if let assetID {
            state.lastActive = StoredState.LastActive(assetID: assetID, conversationID: conversationID)
        } else {
            state.lastActive = nil
        }
        persist()
    }

    /// 只允许首次绑定范围；即使前端发来其他范围也不能切换。
    @discardableResult
    public func lockScope(assetID: String, conversationID: String, requested: KnowledgeScope) -> KnowledgeScope? {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        if let scope = state.books[bi].conversations[ci].scope { return scope }
        state.books[bi].conversations[ci].scope = requested
        state.books[bi].conversations[ci].scopeHistoryStartIndex = state.books[bi].conversations[ci].messages.count
        persist()
        return requested
    }

    public func markLastQuestion(assetID: String, conversationID: String, boundary: ReadingBoundary?) {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = state.books[bi].conversations[ci].messages.lastIndex(where: { $0.role == .user }) else { return }
        state.books[bi].conversations[ci].messages[mi].boundary = boundary
        persist()
    }

    /// 追加一条消息（骨架期不会被调用，接入 LLM 后使用）。
    public func appendMessage(assetID: String, conversationID: String, message: Conversation.Message) {
        guard let bookIndex = state.books.firstIndex(where: { $0.assetID == assetID }) else { return }
        var book = state.books[bookIndex]
        guard let conversationIndex = book.conversations.firstIndex(where: { $0.id == conversationID }) else { return }

        var conversation = book.conversations[conversationIndex]
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        book.conversations[conversationIndex] = conversation
        state.books[bookIndex] = book
        persist()
    }
}
