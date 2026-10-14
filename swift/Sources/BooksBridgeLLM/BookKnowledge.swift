import BooksBridgeCore
import Foundation

/// 一次预处理产出的书籍知识。落盘为 `<assetID>.md`，同时保存元信息用于失效判断。
public struct BookKnowledge: Codable, Sendable, Equatable {
    /// 预处理产出的结构化说明（Markdown）。这是后续提问时随请求带上的"书籍知识"。
    public var readme: String
    /// 书籍正文的内容指纹，用于判断缓存是否还有效。
    public var contentHash: String
    public var generatedAt: Date
    public var model: String
    /// 正文总字数与章节数，便于在 UI 上展示"这本书有多大"。
    public var characterCount: Int
    public var chapterCount: Int
    /// 预处理时的分块数与 token 用量，用于成本可见。
    public var chunkCount: Int
    public var promptTokens: Int
    public var completionTokens: Int

    public init(
        readme: String,
        contentHash: String,
        generatedAt: Date = Date(),
        model: String,
        characterCount: Int,
        chapterCount: Int,
        chunkCount: Int,
        promptTokens: Int,
        completionTokens: Int
    ) {
        self.readme = readme
        self.contentHash = contentHash
        self.generatedAt = generatedAt
        self.model = model
        self.characterCount = characterCount
        self.chapterCount = chapterCount
        self.chunkCount = chunkCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// 提问时可以给 LLM 的书籍知识范围。
///
/// 三种范围的差别本质上是**剧透边界**：
/// - 读者可能只想问"我读到这里为止的内容"，怕被剧透后面
/// - 也可能想直接问整本书，不在意剧透
public enum KnowledgeScope: String, Codable, Sendable, CaseIterable {
    /// 读到哪算哪：只给已完成章节与当前可见正文，不估算当前章内偏移。
    case upToProgress
    /// 整个当前章，包含读者还没读到的部分。仍不含后面的章节。
    case currentChapter
    /// 整本书，包括后续情节。
    case wholeBook

    public var label: String {
        switch self {
        case .upToProgress: "读到这为止"
        case .currentChapter: "整章（含未读）"
        case .wholeBook: "整本书"
        }
    }

    public var explanation: String {
        switch self {
        case .upToProgress: "读取已完成章节与当前可见正文，不读取当前章的其他部分"
        case .currentChapter: "包含当前章未读部分，但不涉及后面的章节"
        case .wholeBook: "使用全书内容，可能剧透后续情节"
        }
    }
}

/// 预处理与缓存的编排。
///
/// 存放在 `~/Library/Application Support/BooksBridge/knowledge/<assetID>.json`。
/// 缓存失效依据是正文内容指纹：书籍文件变了才重做，否则直接复用。
public actor BookKnowledgeStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory
            ?? AppPaths.supportDirectory.appendingPathComponent("knowledge", isDirectory: true)
        self.fileManager = fileManager
    }

    public func cached(assetID: String) -> BookKnowledge? {
        let url = fileURL(for: assetID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BookKnowledge.self, from: data)
    }

    public func save(_ knowledge: BookKnowledge, assetID: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(knowledge)
            try data.write(to: fileURL(for: assetID), options: .atomic)
        } catch {
            NSLog("[BooksBridge] 保存书籍知识失败: \(error.localizedDescription)")
        }
    }

    public func remove(assetID: String) {
        try? fileManager.removeItem(at: fileURL(for: assetID))
    }

    /// 列出已预处理过的书，供 UI 显示。
    public func knownAssetIDs() -> [String] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
    }

    private func fileURL(for assetID: String) -> URL {
        // assetID 是十六进制串，但仍然做一次白名单过滤，避免拼出越界路径
        let safe = assetID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("\(safe.isEmpty ? "unknown" : safe).json")
    }
}
