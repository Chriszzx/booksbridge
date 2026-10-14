import Foundation

/// 把各层拼装成"用户此刻在读什么"的单一事实来源。
///
/// 职责边界：
/// - 只负责**采集与组装**，不做 LLM 调用、不做 UI；
/// - 所有耗时操作（SQLite 查询、AX 遍历）都在内部串行队列上执行；
/// - 通过 `onUpdate` 向外推送变化，调用方无需自己轮询。
public final class ReadingCoordinator: @unchecked Sendable {
    public struct Options: Sendable {
        /// 是否在采集时读取屏幕可见正文（需要辅助功能权限）。
        public var includeVisibleText: Bool
        /// 仅当阅读位置或书籍发生变化时才回调（AX 文本变化也计入）。
        public var debounce: TimeInterval

        public init(includeVisibleText: Bool = true, debounce: TimeInterval = 0.15) {
            self.includeVisibleText = includeVisibleText
            self.debounce = debounce
        }
    }

    private let store: BooksStore
    private let paths: BooksPaths
    private let permissions: Permissions
    private let axReader: AccessibilityReader
    private let options: Options

    private let queue = DispatchQueue(label: "booksbridge.coordinator")
    private var watcher: FileWatcher?
    private var isCollecting = false
    private var needsRecollect = false
    private var lastSignature: String?

    /// 每次采集到新状态时回调（在内部队列上触发，调用方自行切换线程）。
    public var onUpdate: (@Sendable (ReadingContext) -> Void)?
    /// 采集过程中的非致命问题（权限缺失、书未打开等）。
    public var onIssue: (@Sendable (String) -> Void)?

    public init(
        paths: BooksPaths = BooksPaths(),
        options: Options = Options()
    ) {
        self.paths = paths
        self.store = BooksStore(paths: paths)
        self.permissions = Permissions(paths: paths)
        self.axReader = AccessibilityReader()
        self.options = options
    }

    // MARK: - 生命周期

    /// 开始监听：先采集一次，然后监听数据文件变化。
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.collect()
            self.startWatching()
        }
    }

    public func stop() {
        queue.sync { [weak self] in
            self?.watcher?.stop()
            self?.watcher = nil
        }
    }

    private func startWatching() {
        let watcher = FileWatcher(files: paths.watchedFiles(), debounce: options.debounce) { [weak self] in
            self?.queue.async { [weak self] in self?.scheduleCollect() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 合并并发触发：采集进行中时只记一个"待重采"标记。
    private func scheduleCollect() {
        if isCollecting {
            needsRecollect = true
            return
        }
        collect()
    }

    // MARK: - 采集

    private func collect() {
        isCollecting = true
        defer {
            isCollecting = false
            if needsRecollect {
                needsRecollect = false
                queue.async { [weak self] in self?.collect() }
            }
        }

        guard let context = makeContext() else { return }

        // 用签名去重：只有真正变化才回调，避免 AX 噪声导致刷屏
        let signature = Self.signature(of: context)
        guard signature != lastSignature else { return }
        lastSignature = signature
        onUpdate?(context)
    }

    /// 采集一次完整快照。返回 nil 表示当前没有可用的阅读上下文。
    public func makeContext() -> ReadingContext? {
        guard permissions.fullDiskAccessStatus().isGranted else {
            onIssue?("缺少完全磁盘访问权限，无法读取图书数据")
            return nil
        }
        guard let assetID = store.currentAssetID() else {
            onIssue?("偏好设置里没有 kLastCurrentBookKey（图书 App 可能还没打开过任何书）")
            return nil
        }
        guard let book = try? store.book(assetID: assetID) else {
            onIssue?("书库里找不到 assetID=\(assetID)")
            return nil
        }
        let position = try? store.readingPosition(assetID: assetID)

        var visible: [String] = []
        var selection: String?
        if options.includeVisibleText {
            switch permissions.accessibilityStatus() {
            case .granted:
                if let snapshot = try? axReader.snapshot() {
                    visible = snapshot.visibleText
                    selection = snapshot.selection
                }
            case .denied:
                onIssue?("缺少辅助功能权限，无法读取屏幕可见正文")
            case .unknown(let why):
                onIssue?("辅助功能权限状态未知：\(why)")
            }
        }

        return ReadingContext(
            book: book,
            position: position,
            visibleText: visible,
            selection: selection
        )
    }

    /// 变化签名：决定"什么算变化"。
    ///
    /// 刻意**不**包含 AX 正文内容本身，否则 WebKit 重绘会造成无意义的回调；
    /// 只包含"书 + 位置 + 可见段落数 + 选中文本"，足以覆盖翻页与划选。
    private static func signature(of context: ReadingContext) -> String {
        let cfi = context.position?.cfi ?? context.position?.raw ?? "-"
        let sel = context.selection ?? "-"
        return "\(context.book.assetID)|\(cfi)|\(context.visibleText.count)|\(sel.count)"
    }

    // MARK: - 派生：可喂给 LLM 的章节正文

    /// 解析当前阅读位置所在的章节正文。
    ///
    /// 与 `visibleText` 的分工：
    /// - 本方法给出**整章**，适合回答"这一段前后发生了什么"；
    /// - `visibleText` 给出**当前屏**，适合回答"这句话什么意思"。
    public func currentChapterText(context: ReadingContext) -> (href: String, text: String)? {
        guard let path = context.book.path,
              case .epubCFI = context.position?.kind,
              let raw = context.position?.cfi,
              let cfi = CFI(raw: raw),
              let epub = try? EpubDocument(root: URL(fileURLWithPath: path)),
              let resolved = try? epub.resolve(cfi: cfi) else { return nil }
        return (resolved.href, resolved.text)
    }
}
