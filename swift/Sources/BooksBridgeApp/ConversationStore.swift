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
    public var customTitle: String?
    public var sourceIdentity: BookSourceIdentity?
    public var sourceAliases: [String]?
    public var libraryID: UUID?
    public var study: BookStudy?
    public var verifiedPosition: ReadingSnapshot?

    public var id: String { assetID }
    public var displayTitle: String { customTitle ?? title }
    public var sourceAssetIDs: [String] { [assetID] + (sourceAliases ?? []) }

    public init(assetID: String, title: String, author: String, addedAt: Date = Date(), conversations: [Conversation] = []) {
        self.assetID = assetID
        self.title = title
        self.author = author
        self.addedAt = addedAt
        self.conversations = conversations
        self.libraryID = UUID()
    }
}

/// 一条对话。
///
/// 消息、阅读位置、权限和摘要一起保存；归档只改变可见性。
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
    public var confirmedStructureVersion: String?
    public var readingSnapshot: ReadingSnapshot?
    public var summary: ReadingSummary?
    public var summaryStatus: String?
    public var archivedAt: Date?
    public var titleProgress: Double?
    public var customTitle: String?
    public var displayTitle: String { customTitle ?? title }

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

    public static func readingTitle(progress: Double?, createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let position = progress.flatMap { $0.isFinite ? "\(Int((min(1, max(0, $0)) * 100).rounded()))%" : nil } ?? "进度未知"
        return "\(position) · \(formatter.string(from: createdAt))"
    }

    /// Resolve legacy replies by order; new replies retain their question identity after deletion.
    public func retryQuestion(for replyID: String) -> Message? {
        guard let index = messages.firstIndex(where: { $0.id == replyID }),
              messages[index].role == .assistant, messages[index].isPositionCard != true else { return nil }
        if let id = messages[index].inReplyTo {
            return messages[..<index].first { $0.id == id && $0.role == .user && $0.isPositionCard != true }
        }
        return messages[..<index].last { $0.role == .user && $0.isPositionCard != true }
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
        public var sourceHash: String?
        public var isPositionCard: Bool?
        public var inReplyTo: String?
        public var reasoning: String?
        public var reasoningExpanded: Bool?

        public init(id: String = UUID().uuidString, role: Role, text: String, createdAt: Date = Date(), boundary: ReadingBoundary? = nil, sourceHash: String? = nil, isPositionCard: Bool = false, reasoning: String? = nil, reasoningExpanded: Bool? = nil) {
            self.id = id
            self.reasoning = reasoning
            self.reasoningExpanded = reasoningExpanded
            self.role = role
            self.boundary = boundary
            self.sourceHash = sourceHash
            self.isPositionCard = isPositionCard
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
    public private(set) var lastWriteError: String?

    public init(fileURL: URL = AppPaths.storeFile, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.state = ConversationStore.load(from: fileURL, fileManager: fileManager)
        var migratedTitles = false
        for bi in state.books.indices {
            if state.books[bi].libraryID == nil { state.books[bi].libraryID = UUID(); migratedTitles = true }
            if state.books[bi].study?.status.hasPrefix("正在") == true {
                state.books[bi].study?.status = "摘要任务已中断；已完成章节保留，可继续生成"
                migratedTitles = true
            }
            if state.books[bi].study?.structureStatus?.hasPrefix("正在") == true {
                state.books[bi].study?.structureStatus = "章节分析已中断，请手动重新分析"; migratedTitles = true
            }
            for ci in state.books[bi].conversations.indices {
                var conversation = state.books[bi].conversations[ci]
                if conversation.customTitle == nil, conversation.title.range(of: "^对话 [0-9]+$", options: .regularExpression) != nil {
                    conversation.titleProgress = conversation.readingSnapshot?.page == nil ? nil : conversation.readingSnapshot?.progress
                    conversation.title = Conversation.readingTitle(progress: conversation.titleProgress, createdAt: conversation.createdAt)
                    state.books[bi].conversations[ci] = conversation
                    migratedTitles = true
                }
                if state.books[bi].conversations[ci].summaryStatus?.hasPrefix("正在") == true {
                    state.books[bi].conversations[ci].summaryStatus = "摘要任务已中断，请手动重新生成"
                }
            }
        }
        if migratedTitles { persist() }
    }

    // MARK: - 读取

    /// Shared summaries survive chat deletion/archive. A deleted book can never be recreated by a late job.
    @discardableResult
    public func saveStudy(assetID: String, study: BookStudy) -> Bool {
        guard let index = state.books.firstIndex(where: { $0.assetID == assetID }) else { return false }
        let previous = state
        state.books[index].study = study
        return persistOrRollback(previous)
    }

    @discardableResult
    public func updateStatistics(assetID: String, statistics: BookStatistics) -> Bool {
        guard let book = book(assetID: assetID) else { return false }
        var study = book.study ?? BookStudy(statistics: statistics)
        study.refreshLocal(statistics)
        // Legacy full-book summaries are safe to reuse only for the exact same source.
        if book.study == nil, let legacy = book.conversations.compactMap(\.summary)
            .filter({ $0.scope == .wholeBook && $0.sourceHash == statistics.sourceHash })
            .max(by: { $0.generatedAt < $1.generatedAt }) {
            study.whole = legacy
            study.status = "旧版全书摘要已迁移 · 章节摘要待生成"
        }
        if book.study == study { return true }
        return saveStudy(assetID: book.assetID, study: study)
    }

    @discardableResult
    public func clearStudy(assetID: String) -> Bool {
        guard let index = state.books.firstIndex(where: { $0.assetID == assetID }), let statistics = state.books[index].study?.statistics else { return false }
        let previous = state
        var cleared = state.books[index].study ?? BookStudy(statistics: statistics)
        cleared.chapters = []; cleared.whole = nil; cleared.wholeModel = nil; cleared.status = "尚未生成章节摘要"
        state.books[index].study = cleared
        for i in state.books[index].conversations.indices {
            state.books[index].conversations[i].summary = nil
            state.books[index].conversations[i].summaryStatus = nil
        }
        return persistOrRollback(previous)
    }

    public func confirmStructure(assetID: String, conversationID: String, version: String) -> Bool {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              state.books[bi].study?.statistics.structureVersion == version,
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        let previous = state
        state.books[bi].conversations[ci].confirmedStructureVersion = version
        return persistOrRollback(previous)
    }
    public func structurePermissionRequired(assetID: String, conversationID: String, scope: KnowledgeScope) -> Bool {
        guard scope == .currentChapter, let study = book(assetID: assetID)?.study, study.localStatistics != nil else { return false }
        return conversation(assetID: assetID, conversationID: conversationID)?.confirmedStructureVersion != study.statistics.structureVersion
    }

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
    @discardableResult
    private func persist() -> Bool {
        do {
            lastWriteError = nil
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
            return true
        } catch {
            lastWriteError = error.localizedDescription
            NSLog("[BooksBridge] 写入 store 失败: \(error.localizedDescription)")
            return false
        }
    }

    private func persistOrRollback(_ previous: StoredState) -> Bool {
        if persist() { return true }
        state = previous
        return false
    }

    // MARK: - 查询

    public func book(assetID: String) -> StoredBook? {
        state.books.first { $0.sourceAssetIDs.contains(assetID) }
    }

    public func canonicalAssetID(_ assetID: String) -> String { book(assetID: assetID)?.assetID ?? assetID }

    @discardableResult
    public func renameBook(assetID: String, title: String) -> Bool {
        guard let index = state.books.firstIndex(where: { $0.assetID == assetID }), title.count <= 120 else { return false }
        let previous = state
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        state.books[index].customTitle = value.isEmpty ? nil : value
        return persistOrRollback(previous)
    }

    @discardableResult
    public func renameConversation(assetID: String, conversationID: String, title: String) -> Bool {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }), title.count <= 120 else { return false }
        let previous = state
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        state.books[bi].conversations[ci].customTitle = value.isEmpty ? nil : value
        return persistOrRollback(previous)
    }

    @discardableResult
    public func bindSource(assetID: String, identity: BookSourceIdentity) -> Bool {
        guard let index = state.books.firstIndex(where: { $0.assetID == assetID }) else { return false }
        if state.books[index].sourceIdentity == identity { return true }
        let previous = state
        state.books[index].sourceIdentity = identity
        return persistOrRollback(previous)
    }

    @discardableResult
    public func linkSource(assetID: String, incomingID: String, identity: BookSourceIdentity) -> Bool {
        guard book(assetID: incomingID) == nil,
              let index = state.books.firstIndex(where: { $0.assetID == assetID }),
              let existing = state.books[index].sourceIdentity,
              existing.fingerprint == identity.fingerprint || existing.isSameFile(as: identity) else { return false }
        let previous = state
        state.books[index].sourceAliases = (state.books[index].sourceAliases ?? []) + [incomingID]
        state.books[index].sourceIdentity = identity
        return persistOrRollback(previous)
    }

    public func conversation(assetID: String, conversationID: String) -> Conversation? {
        book(assetID: assetID)?.conversations.first { $0.id == conversationID }
    }

    // MARK: - 变更

    /// Move the existing record, preserving all conversations and their reading state.
    @discardableResult
    public func moveBook(assetID: String, beforeAssetID: String?) -> Bool {
        guard assetID != beforeAssetID,
              let from = state.books.firstIndex(where: { $0.assetID == assetID }),
              beforeAssetID == nil || state.books.contains(where: { $0.assetID == beforeAssetID }) else { return false }
        let value = state.books.remove(at: from)
        let target = beforeAssetID.flatMap { id in state.books.firstIndex { $0.assetID == id } } ?? state.books.endIndex
        state.books.insert(value, at: target)
        persist()
        return true
    }

    @discardableResult
    public func setArchived(assetID: String, conversationID: String, archived: Bool) -> Bool {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        if archived { state.books[bi].conversations[ci].archivedAt = state.books[bi].conversations[ci].archivedAt ?? Date() }
        else { state.books[bi].conversations[ci].archivedAt = nil }
        if archived, state.lastActive?.assetID == assetID, state.lastActive?.conversationID == conversationID {
            state.lastActive = .init(assetID: assetID, conversationID: state.books[bi].conversations.first { $0.archivedAt == nil }?.id)
        }
        persist()
        return true
    }

    /// 把一本书加入书库（已存在则同步标题作者，不覆盖对话）。
    ///
    /// 返回该书当前的记录。
    @discardableResult
    public func addBook(assetID: String, title: String, author: String) -> StoredBook {
        if let index = state.books.firstIndex(where: { $0.sourceAssetIDs.contains(assetID) }) {
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

    /// New chats acquire their first verified progress while keeping their creation timestamp.
    @discardableResult
    public func createConversation(assetID: String, createdAt: Date = Date()) -> Conversation? {
        guard let index = state.books.firstIndex(where: { $0.assetID == assetID }) else { return nil }
        var book = state.books[index]
        let conversation = Conversation(title: Conversation.readingTitle(progress: nil, createdAt: createdAt), createdAt: createdAt)
        book.conversations.append(conversation)
        state.books[index] = book
        persist()
        return conversation
    }

    /// 删除一条对话。
    @discardableResult
    public func deleteConversation(assetID: String, conversationID: String) -> Bool {
        guard let bookIndex = state.books.firstIndex(where: { $0.assetID == assetID }) else { return false }
        let previous = state
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
                conversationID: book.conversations.first(where: { $0.archivedAt == nil })?.id
            )
        }
        return persistOrRollback(previous)
    }

    /// 把一本书移出书库（连同其对话）。
    @discardableResult
    public func removeBook(assetID: String) -> Bool {
        let previous = state
        let before = state.books.count
        state.books.removeAll { $0.assetID == assetID }
        guard state.books.count != before else { return false }
        if state.lastActive?.assetID == assetID {
            state.lastActive = state.books.first.map {
                StoredState.LastActive(assetID: $0.assetID, conversationID: $0.conversations.first(where: { $0.archivedAt == nil })?.id)
            }
        }
        return persistOrRollback(previous)
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

    @discardableResult
    public func saveVerifiedPosition(assetID: String, snapshot: ReadingSnapshot) -> Bool {
        guard snapshot.assetID == assetID, snapshot.page != nil, !snapshot.reused,
              let index = state.books.firstIndex(where: { $0.assetID == assetID }) else { return false }
        if let old = state.books[index].verifiedPosition, old.capturedAt > snapshot.capturedAt { return false }
        if state.books[index].verifiedPosition == snapshot { return true }
        let previous = state
        state.books[index].verifiedPosition = snapshot
        return persistOrRollback(previous)
    }

    public func updateReading(assetID: String, conversationID: String, snapshot: ReadingSnapshot) {
        guard snapshot.assetID == assetID else { return }
        if !snapshot.reused { _ = saveVerifiedPosition(assetID: assetID, snapshot: snapshot) }
        updateConversation(assetID: assetID, conversationID: conversationID) {
            $0.readingSnapshot = snapshot
            if $0.titleProgress == nil, snapshot.page != nil {
                $0.titleProgress = snapshot.progress
                $0.title = Conversation.readingTitle(progress: snapshot.progress, createdAt: $0.createdAt)
            }
        }
    }

    public func updateConversation(assetID: String, conversationID: String, _ change: (inout Conversation) -> Void) {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var value = state.books[bi].conversations[ci]
        change(&value)
        state.books[bi].conversations[ci] = value
        persist()
    }

    /// Keep visible later messages, but never reuse answers derived from edited/deleted context.
    @discardableResult
    public func changeMessage(assetID: String, conversationID: String, messageID: String, text: String? = nil) -> Bool {
        guard let c = conversation(assetID: assetID, conversationID: conversationID), c.archivedAt == nil,
              let index = c.messages.firstIndex(where: { $0.id == messageID }),
              text == nil || (c.messages[index].role == .user && c.messages[index].isPositionCard != true && !text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return false }
        updateConversation(assetID: assetID, conversationID: conversationID) { value in
            // Bind legacy replies before removing a question, avoiding accidental retries of another turn.
            for i in value.messages.indices where value.messages[i].role == .assistant && value.messages[i].inReplyTo == nil {
                value.messages[i].inReplyTo = c.retryQuestion(for: value.messages[i].id)?.id
            }
            for i in index..<value.messages.count { value.messages[i].boundary = nil; value.messages[i].sourceHash = nil }
            if let text { value.messages[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else {
                value.messages.remove(at: index)
                if let start = value.scopeHistoryStartIndex, index < start { value.scopeHistoryStartIndex = start - 1 }
            }
            value.updatedAt = Date()
        }
        return true
    }

    public func saveAnswer(assetID: String, conversationID: String, questionID: String, replacing replyID: String?, answer: Conversation.Message) {
        updateConversation(assetID: assetID, conversationID: conversationID) { value in
            guard let qi = value.messages.firstIndex(where: { $0.id == questionID }) else { return }
            var reply = answer
            reply.inReplyTo = questionID
            if let replyID {
                guard let ri = value.messages.firstIndex(where: { $0.id == replyID }), value.retryQuestion(for: replyID)?.id == questionID else { return }
                reply.id = replyID
                value.messages[ri] = reply
                for i in (ri + 1)..<value.messages.count { value.messages[i].boundary = nil; value.messages[i].sourceHash = nil }
            } else { value.messages.append(reply) }
            value.messages[qi].boundary = answer.boundary
            value.messages[qi].sourceHash = answer.sourceHash
            value.updatedAt = Date()
        }
    }

    @discardableResult
    public func setReasoningExpanded(assetID: String, conversationID: String, messageID: String, expanded: Bool) -> Bool {
        guard let conversation = conversation(assetID: assetID, conversationID: conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }),
              conversation.messages[index].reasoning?.isEmpty == false else { return false }
        updateConversation(assetID: assetID, conversationID: conversationID) { $0.messages[index].reasoningExpanded = expanded }
        return true
    }

    public func markLastQuestion(assetID: String, conversationID: String, boundary: ReadingBoundary?, sourceHash: String? = nil) {
        guard let bi = state.books.firstIndex(where: { $0.assetID == assetID }),
              let ci = state.books[bi].conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = state.books[bi].conversations[ci].messages.lastIndex(where: { $0.role == .user }) else { return }
        state.books[bi].conversations[ci].messages[mi].boundary = boundary
        state.books[bi].conversations[ci].messages[mi].sourceHash = sourceHash
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
