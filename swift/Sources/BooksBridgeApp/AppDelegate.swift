import AppKit
import BooksBridgeCore
import BooksBridgeLLM
import Foundation
import Security

/// 应用主委托。
///
/// 把四层串起来并保证生命周期与线程正确：
///   状态栏图标 → 全屏页面窗口 → WebView 前端
///                    ↑
///           ReadingCoordinator（数据层，后台队列）
///
/// 线程约定：`ReadingCoordinator` 的回调发生在它自己的串行队列上，
/// 而 AppKit 与 WKWebView 都必须在主线程使用，因此所有跨层回调统一 hop 回主线程。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController!
    private var page: PageWindowController!
    private var bridge: WebBridge!
    private var coordinator: ReadingCoordinator!
    /// 用户自己的书库与对话（持久化在 AppPaths.storeFile）。
    private var store: ConversationStore!
    private let sidebarLayout = SidebarLayoutStore()
    /// 图书 App 的书库数据源，用于回查书名等元数据。
    private let booksStore = BooksStore()
    /// 应用设置（服务商、模型、上下文范围）与 API Key。
    private var settings: SettingsStore!
    /// 阅读问答编排：预处理与流式问答。
    private let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "")
    /// 当前问答的流式事件流，用于取消。
    private var apiTestTask: Task<Void, Never>?
    private var apiTestGeneration = 0
    private var answerStream: Task<Void, Never>?
    private var pendingReply: (assetID: String, conversationID: String, questionID: String, retryID: String?, text: String, reasoning: String, reasoningExpanded: Bool?)?
    private var positionTask: Task<Void, Never>?
    private let summaryJobs = SummaryJobs()
    private let structureJobs = StructureJobs()
    private var selectionCandidate: ConfirmedReference?
    private var pendingSourceImport: (id: String, book: BooksBridgeCore.Book, source: BookSourceIdentity, matches: [String])?
    private var pendingBookIdentification: (id: String, snapshot: AccessibilityReader.Snapshot, books: [BooksBridgeCore.Book])?

    /// 最近一次采集到的阅读上下文；未检测到时为 nil。
    private var latestContext: ReadingContext?
    private var latestSourceContext: ReadingContext?
    /// 前端是否已经就绪（就绪前的推送会被丢弃，避免 evaluateJavaScript 打空）。
    private var frontendReady = false
    // 每次启动先离线显示自有数据；受保护的读取仅由用户连接操作开启。
    private var connectionGeneration = 0
    private var connectionRequested = false
    private var returningFromPermissionSettings = false
    private var dataAccess: PermissionStatus = .unknown("尚未连接 Apple Books")
    private var cachedProbe: [String: Any] = ["probes": [], "hint": "点击连接 Apple Books 后检查数据访问。"]
    /// 采集不到阅读上下文时的原因，用于把"未授权"和"没在读书"区分开。
    private var detectionIssue: String?
    /// 最近一次前端渲染统计，供自检报告拼装。
    private var lastRenderStats: [String: Any]?

    /// 启动参数 `--show`：启动后立即显示页面（便于自动化验证）。
    private let showOnLaunch = CommandLine.arguments.contains("--show")
    /// 启动参数 `--quit-after N`：N 秒后自动退出（便于自动化验证）。
    private var autoQuitSeconds: Double? {
        guard let index = CommandLine.arguments.firstIndex(of: "--quit-after"),
              index + 1 < CommandLine.arguments.count,
              let value = Double(CommandLine.arguments[index + 1]) else { return nil }
        return value
    }

    /// 窗口模式：默认标准窗口；`BOOKSBRIDGE_WINDOW_MODE=fullscreen` 可切到原生全屏。
    private var windowMode: PageWindowController.Mode {
        if let raw = ProcessInfo.processInfo.environment["BOOKSBRIDGE_WINDOW_MODE"],
           let mode = PageWindowController.Mode.parse(raw) {
            return mode
        }
        if let index = CommandLine.arguments.firstIndex(of: "--window-mode"),
           index + 1 < CommandLine.arguments.count,
           let mode = PageWindowController.Mode.parse(CommandLine.arguments[index + 1]) {
            return mode
        }
        return .windowed
    }

    // MARK: - 生命周期

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[BooksBridge] 启动，窗口模式=\(windowMode.rawValue)")

        // 验证状态栏菜单结构（状态栏项无法用辅助功能 API 点击）
        if CommandLine.arguments.contains("--dump-status-menu") {
            statusItem = StatusItemController(
                onOpenPage: {}, onOpenSettings: {}, onReturnToReader: {}, onOpenDataDirectory: {}
            )
            print("=== 状态栏菜单结构（有书在读）===")
            print(statusItem.describeMenu(state: StatusItemController.MenuState(
                bookTitle: "Fire Girl 1 「虚惑星的魔法师」下卷 (型月文库)",
                bookProgress: 0.471,
                conversationTitle: "对话 1",
                isDetecting: true,
                fullDiskAccess: true,
                accessibility: false,
                llmConfigured: false
            )))
            print("\n=== 状态栏菜单结构（无书在读）===")
            print(statusItem.describeMenu(state: StatusItemController.MenuState()))
            NSApp.terminate(nil)
            return
        }

        // 诊断模式：只打印环境信息后退出，便于验证 .app 打包是否正确
        if CommandLine.arguments.contains("--diagnostics") {
            print(Self.diagnostics())
            NSApp.terminate(nil)
            return
        }

        // Dock 图标与菜单栏：激活策略已在 main.swift 里设为 .regular
        AppIconFactory.apply()
        ApplicationMenu.install(
            appName: "BooksBridge",
            onSettings: { [weak self] in self?.openSettings() },
            onShowPage: { [weak self] in self?.openPage() }
        )

        AppPaths.ensureSupportDirectory()
        store = ConversationStore()
        settings = SettingsStore()
        summaryJobs.onUpdate = { [weak self] _ in self?.pushState(message: "书籍摘要状态已更新") }
        structureJobs.onUpdate = { [weak self] _ in self?.pushState(message: "书籍章节状态已更新") }
        assistant.update(settings: settings.settings, apiKey: settings.apiKey)
        writeReport()


        page = PageWindowController(mode: windowMode)
        bridge = WebBridge()
        bridge.onInvocation = { [weak self] invocation in
            self?.handle(invocation)
        }
        page.installContentView(bridge.webView)
        if bridge.load() {
            NSLog("[BooksBridge] 前端资源已加载")
        } else {
            NSLog("[BooksBridge] 前端资源加载失败\n\(WebBridge.resourceDiagnostics)")
        }

        statusItem = StatusItemController(
            onOpenPage: { [weak self] in self?.openPage() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onReturnToReader: { [weak self] in self?.returnToReader() },
            onOpenDataDirectory: { [weak self] in
                let url = AppPaths.supportDirectory
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
        )
        statusItem.onRefresh = { [weak self] in self?.coordinator?.refresh() }
        statusItem.stateProvider = { [weak self] in
            guard let self else { return StatusItemController.MenuState() }
            let permissions = Permissions()
            let book = self.latestContext?.book
            let activeConversation = self.store.state.lastActive.flatMap { active in
                self.store.conversation(assetID: active.assetID, conversationID: active.conversationID ?? "")
            }
            return StatusItemController.MenuState(
                bookTitle: book.flatMap { self.store.book(assetID: $0.assetID)?.displayTitle ?? $0.title },
                bookProgress: book?.progress,
                conversationTitle: activeConversation?.displayTitle,
                isDetecting: self.latestContext != nil,
                fullDiskAccess: self.dataAccess.isGranted,
                accessibility: permissions.accessibilityStatus().isGranted,
                llmConfigured: self.settings?.isConfigured ?? false
            )
        }


        do { // 启动先显示界面，不主动申请权限。
            // 延后一拍：状态栏布局未完成时直接显示窗口会失败
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.page.show()
                self.pushState(message: "页面已打开")
                // 全屏动画需要时间，稍后再报告窗口状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    NSLog("[BooksBridge] 窗口状态:\n\(self.page.stateDescription)")
                    self.pushState(message: "页面已打开")
                }
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--return-after"),
           index + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                NSLog("[BooksBridge] --return-after 触发返回图书")
                self?.returnToReader()
            }
        }

        // 测试参数：模拟侧栏点击"进入某本书"，用于自动化验证进入流程
        if let index = CommandLine.arguments.firstIndex(of: "--open-book"),
           index + 1 < CommandLine.arguments.count {
            let assetID = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                NSLog("[BooksBridge] --open-book 模拟点击进入 \(assetID)")
                self?.openBook(assetID: assetID)
            }
        }

        // 测试参数：模拟新建对话
        if let index = CommandLine.arguments.firstIndex(of: "--new-conversation"),
           index + 1 < CommandLine.arguments.count {
            let assetID = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                NSLog("[BooksBridge] --new-conversation 模拟新建")
                self?.newConversation(assetID: assetID)
            }
        }

        // 测试参数：模拟回到书库（取消停留）
        if CommandLine.arguments.contains("--back-to-library") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.store.setActive(assetID: nil, conversationID: nil)
                self?.pushState(message: "回到书库")
            }
        }

        // 测试参数：模拟提问（用于验证问答链路，不依赖真实 API）
        if let index = CommandLine.arguments.firstIndex(of: "--test-ask"),
           index + 1 < CommandLine.arguments.count {
            let question = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                NSLog("[BooksBridge] --test-ask 模拟提问：\(question)")
                self?.ask(["question": question])
            }
        }

        // 测试参数：启动后直接打开设置页
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                NSLog("[BooksBridge] --open-settings 打开设置页")
                self?.openSettings()
            }
        }

        // 测试参数：模拟前端提交设置
        if CommandLine.arguments.contains("--test-save-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                NSLog("[BooksBridge] --test-save-settings 模拟保存")
                self.saveSettings([
                    "provider": "ollama",
                    "model": "qwen2.5:14b",
                    "baseURL": "http://localhost:11434/v1",
                    "contextScope": "visibleAndSelection",
                    "maxContextCharacters": 9000,
                    "temperature": 0.7,
                    "apiKey": "test-key-not-real",
                ])
                self.pushSettings()
            }
        }

        // 测试参数：强制窗口尺寸，用于验证最小尺寸下的布局
        if let index = CommandLine.arguments.firstIndex(of: "--window-size"),
           index + 1 < CommandLine.arguments.count {
            let spec = CommandLine.arguments[index + 1].lowercased().split(separator: "x")
            if spec.count == 2, let w = Double(spec[0]), let h = Double(spec[1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    self?.page.forceContentSize(NSSize(width: w, height: h))
                    NSLog("[BooksBridge] 强制窗口尺寸 \(Int(w))×\(Int(h))")
                }
            }
        }

        if let seconds = autoQuitSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSLog("[BooksBridge] --quit-after \(seconds) 秒，退出")
                NSApp.terminate(nil)
            }
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        guard frontendReady else { return }
        if !returningFromPermissionSettings { coordinator?.refresh(); return }
        returningFromPermissionSettings = false
        reconnectBooks(requestAccessibility: false)
    }

    private func reconnectBooks(requestAccessibility: Bool) {
        connectionRequested = true
        connectionGeneration += 1
        coordinator?.stop()
        coordinator = nil
        latestContext = nil
        latestSourceContext = nil
        detectionIssue = nil
        dataAccess = Permissions().fullDiskAccessStatus()
        cachedProbe = Self.permissionProbePayload()
        if requestAccessibility, !Permissions().accessibilityStatus().isGranted {
            returningFromPermissionSettings = true
            _ = Permissions().requestAccessibility()
        }
        if dataAccess.isGranted { startReadingCoordinator() }
        pushState(message: "已重新检测图书连接")
        pushSettings()
        writeReport()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        cancelPendingAnswer()
        bridge?.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: WebBridge.handlerName)
    }

    /// 菜单栏应用：点 Dock 图标（理论上没有）或重新打开时不重复建窗口。
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { page.show() }
        return true
    }

    // MARK: - 诊断

    /// 打印打包与运行环境信息。
    ///
    /// 打 `.app` 最容易翻车的两处是：资源 bundle 没被拷进 `Contents/Resources`，
    /// 以及 `LSUIElement` 没生效。这里一次性把它们暴露出来。
    public static func diagnostics() -> String {
        let bundle = Bundle.main
        let executable = CommandLine.arguments.first ?? "?"
        var lines: [String] = []
        lines.append("=== BooksBridge 诊断 ===")
        lines.append("可执行文件   : \(executable)")
        lines.append("bundle 路径  : \(bundle.bundlePath)")
        lines.append("bundle id    : \(bundle.bundleIdentifier ?? "(无)")")
        lines.append("LSUIElement  : \(bundle.object(forInfoDictionaryKey: "LSUIElement") ?? "(未设置)")")
        lines.append("激活策略     : \(Self.activationPolicyName())")
        lines.append("")
        lines.append("--- 前端资源 ---")
        lines.append(WebBridge.resourceDiagnostics)
        lines.append("")
        lines.append("--- 权限 ---")
        let permissions = Permissions()
        for (permission, status) in permissions.allStatuses() {
            lines.append("\(permission.title): \(status.label)")
        }
        lines.append("")
        lines.append("--- 图书数据 ---")
        let paths = BooksPaths()
        lines.append("书库数据库: \(paths.libraryDatabase()?.lastPathComponent ?? "未找到")")
        lines.append("位置数据库: \(paths.annotationDatabase()?.lastPathComponent ?? "未找到")")
        lines.append("当前书 ID : \(BooksStore().currentAssetID() ?? "未找到")")
        lines.append("")
        lines.append("--- 自有数据 ---")
        lines.append("支持目录: \(AppPaths.supportDirectory.path)")
        lines.append("store   : \(AppPaths.storeFile.path)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 页面显示

    /// 隐藏页面：收起窗口并让出前台，但应用继续常驻（状态栏图标不受影响）。
    ///
    /// 用 `NSApp.hide(nil)` 而不是 `terminate`：用户按 ⌘W 只是想收起来，
    /// 而不是退出；Dock 图标会随之前台状态自然消失，不占 Dock 空间。
    private func hidePage() {
        page.hide()
        NSApp.hide(nil)
    }

    /// 打开界面（菜单里的「打开界面」）。
    private func openPage() {
        coordinator?.refresh()
        page.show()
        pushState(message: "页面已打开")
        pushSettings()
    }

    /// 打开界面并直接跳到设置页。
    private func openSettings() {
        page.show()
        pushState(message: "已打开设置")
        pushSettings(open: true)
    }

    /// 返回图书 App。
    ///
    /// 实测结论（见 `Sources/returnprobe`）：`activate` 是纯前台切换，
    /// **图书 App 的当前书与阅读位置都不会改变**，因此这里不需要任何额外处理。
    private func returnToReader() {
        page.hide()

        let books = NSRunningApplication
            .runningApplications(withBundleIdentifier: AccessibilityReader.booksBundleID)
            .first
        guard let books else {
            NSLog("[BooksBridge] 图书 App 未运行，仅隐藏页面")
            return
        }
        let ok = books.activate(options: [.activateAllWindows])
        // 实测（Sources/returnprobe）：activate 是纯前台切换，
        // 图书 App 的当前书与阅读位置都不会改变，因此这里不做任何状态恢复。
        NSLog("[BooksBridge] 返回图书 App：activate=\(ok)")
    }

    // MARK: - 前端指令

    private func handle(_ invocation: WebBridge.Invocation) {
        switch invocation.type {
        case "renameBook", "renameConversation":
            guard let assetID = invocation.payload["assetID"] as? String,
                  let title = invocation.payload["title"] as? String else { return }
            let success: Bool
            if invocation.type == "renameBook" { success = store.renameBook(assetID: assetID, title: title) }
            else if let id = invocation.payload["conversationID"] as? String { success = store.renameConversation(assetID: assetID, conversationID: id, title: title) }
            else { return }
            managementResult(success, message: success ? "名称已保存" : store.lastWriteError ?? "无法重命名，名称最多 120 个字符。", requestID: invocation.payload["requestID"] as? String)

        case "identifyActiveBook": requestBookIdentification()
        case "confirmActiveBook": confirmBookIdentification(invocation.payload)
        case "resolveSourceImport": resolveSourceImport(invocation.payload)

        case "setSidebarWidth":
            guard let width = invocation.payload["width"] as? Double, width.isFinite else { return }
            sidebarLayout.setWidth(width)
            pushState(message: "侧栏宽度已保存")

        case "setSidebarCollapsed":
            guard let collapsed = invocation.payload["collapsed"] as? Bool else { return }
            sidebarLayout.setCollapsed(collapsed)
            pushState(message: "侧栏显示已保存")

        case "setBookCollapsed":
            guard let assetID = invocation.payload["assetID"] as? String,
                  store.state.books.contains(where: { $0.assetID == assetID }),
                  let collapsed = invocation.payload["collapsed"] as? Bool else { return }
            sidebarLayout.setBookCollapsed(assetID: assetID, collapsed: collapsed)
            pushState(message: "对话列表显示已保存")

        case "setTitlebarHitRegions":
            func rects(_ key: String) -> [NSRect] {
                (invocation.payload[key] as? [[String: Double]] ?? []).compactMap { rect in
                    guard let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
                          x.isFinite, y.isFinite, width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
                    return NSRect(x: x, y: y, width: width, height: height)
                }
            }
            page.setTitlebarHitRegions(draggable: rects("draggable"), interactive: rects("interactive"))

        case "ready":
            frontendReady = true
            NSLog("[BooksBridge] 收到前端 ready 指令，开通状态推送")
            pushState(message: "前端已就绪")
            // 立刻把设置也推一次：下拉选项要在用户打开设置面板之前就绪
            pushSettings()
            if Permissions().accessibilityStatus().isGranted, Permissions().fullDiskAccessStatus().isGranted {
                reconnectBooks(requestAccessibility: false)
                if let active = store.state.lastActive { prepareBook(assetID: active.assetID) }
            }

        // MARK: 侧栏交互

        case "openBook":
            guard let assetID = invocation.payload["assetID"] as? String else { return }
            openBook(assetID: assetID)

        case "newConversation":
            guard let assetID = invocation.payload["assetID"] as? String else { return }
            newConversation(assetID: assetID)

        case "selectConversation":
            guard let assetID = invocation.payload["assetID"] as? String else { return }
            let conversationID = invocation.payload["conversationID"] as? String
            cancelPendingAnswer()
            store.setActive(assetID: assetID, conversationID: conversationID)
            pushState(message: "已切换对话")
            prepareBook(assetID: assetID)

        case "moveBook":
            guard let assetID = invocation.payload["assetID"] as? String else { return }
            store.moveBook(assetID: assetID, beforeAssetID: invocation.payload["beforeAssetID"] as? String)
            pushState(message: "书籍顺序已保存")

        case "archiveConversation", "restoreConversation":
            guard let assetID = invocation.payload["assetID"] as? String,
                  let id = invocation.payload["conversationID"] as? String else { return }
            let archived = invocation.type == "archiveConversation"
            let wasActive = store.state.lastActive?.assetID == assetID && store.state.lastActive?.conversationID == id
            if !archived || wasActive { cancelPendingAnswer() }
            guard store.setArchived(assetID: assetID, conversationID: id, archived: archived) else { return }
            if !archived { store.setActive(assetID: assetID, conversationID: id) }
            pushState(message: archived ? "对话已归档" : "对话已恢复")
            if !archived || wasActive, let active = store.state.lastActive { prepareBook(assetID: active.assetID) }

        case "deleteConversation":
            guard let assetID = invocation.payload["assetID"] as? String,
                  let conversationID = invocation.payload["conversationID"] as? String,
                  invocation.payload["confirmed"] as? Bool == true,
                  store.conversation(assetID: assetID, conversationID: conversationID) != nil else { return }
            if store.state.lastActive?.assetID == assetID && store.state.lastActive?.conversationID == conversationID { cancelPendingAnswer(); selectionCandidate = nil }
            let success = store.deleteConversation(assetID: assetID, conversationID: conversationID)
            managementResult(success, message: success ? "对话及其消息、思考已删除，书籍共享摘要保留" : store.lastWriteError ?? "删除失败", requestID: invocation.payload["requestID"] as? String)

        case "removeBook":
            guard let assetID = invocation.payload["assetID"] as? String,
                  invocation.payload["confirmed"] as? Bool == true,
                  let book = store.book(assetID: assetID), book.assetID == assetID else { return }
            // Stop local parsing too, even if another chat initiated it before deletion.
            positionTask?.cancel(); pendingSourceImport = nil
            if store.state.lastActive?.assetID == assetID { cancelPendingAnswer(); selectionCandidate = nil }
            structureJobs.cancel(assetID, store: store)
            summaryJobs.cancel(assetID: assetID, store: store)
            assistant.forgetBook(assetID: assetID)
            do {
                try BookDataRemoval(directory: AppPaths.supportDirectory).removeBook(assetID: assetID, store: store)
                sidebarLayout.forgetBook(assetID: assetID)
                ActiveBookResolver.shared.forget(assetIDs: book.sourceAssetIDs)
                latestContext = latestSourceContext.map { $0.identified(by: store.canonicalAssetID($0.book.assetID)) }
                managementResult(true, message: "BooksBridge 书籍资料、缓存和全部下属对话已删除，Apple Books 原书已保留", requestID: invocation.payload["requestID"] as? String)
            } catch {
                let removed = store.book(assetID: assetID) == nil
                if removed {
                    sidebarLayout.forgetBook(assetID: assetID)
                    ActiveBookResolver.shared.forget(assetIDs: book.sourceAssetIDs)
                    latestContext = latestSourceContext.map { $0.identified(by: store.canonicalAssetID($0.book.assetID)) }
                }
                managementResult(false, message: error.localizedDescription, requestID: invocation.payload["requestID"] as? String, recordRemoved: removed)
            }

        case "backToLibrary":
            cancelPendingAnswer()
            store.setActive(assetID: nil, conversationID: nil)
            pushState(message: "回到书库")

        case "returnToReader":
            returnToReader()

        case "hidePage", "closeWindow":
            hidePage()

        case "quit":
            NSApp.terminate(nil)

        case "ask":
            ask(invocation.payload)

        case "setPendingReasoningExpanded":
            if let pending = pendingReply,
               invocation.payload["assetID"] as? String == pending.assetID,
               invocation.payload["conversationID"] as? String == pending.conversationID,
               let expanded = invocation.payload["expanded"] as? Bool {
                pendingReply?.reasoningExpanded = expanded
            }

        case "setReasoningExpanded":
            if let assetID = invocation.payload["assetID"] as? String,
               let cid = invocation.payload["conversationID"] as? String,
               let id = invocation.payload["messageID"] as? String,
               let expanded = invocation.payload["expanded"] as? Bool {
                // A queued UI preference belongs to the original message even after navigation.
                // The store rejects missing/deleted messages, so this cannot recreate deleted data.
                store.setReasoningExpanded(assetID: assetID, conversationID: cid, messageID: id, expanded: expanded)
            }

        case "copyMessage", "editMessage", "deleteMessage", "retryMessage":
            handleMessageAction(invocation.type, payload: invocation.payload)

        case "cancelAnswer":
            cancelPendingAnswer()
            pushState(message: "已中断")

        case "reprocessBook":
            if connectionRequested, dataAccess.isGranted,
               store.state.lastActive != nil,
               invocation.payload["confirmed"] as? Bool == true {
                generateSummary(invocation.payload)
            }

        case "checkReading":
            checkReading(invocation.payload)
        case "captureSelection":
            captureSelection()
        case "cancelPreparation":
            if let active = store.state.lastActive, active.conversationID != nil {
                summaryJobs.cancel(assetID: active.assetID, store: store)
            }
        case "clearKnowledge":
            guard invocation.payload["confirmed"] as? Bool == true else { return }
            if let active = store.state.lastActive, active.conversationID != nil {
                summaryJobs.cancel(assetID: active.assetID, store: store)
                let cleared = store.clearStudy(assetID: active.assetID)
                pushState(message: cleared ? "已清除本书共享摘要，章节统计保留" : "清除失败：\(store.lastWriteError ?? "未取得书籍统计")")
            }
        case "analyzeStructure", "applyStructure", "restoreStructure", "discardStructure", "cancelStructure", "confirmStructureScope":
            handleStructure(invocation.type, payload: invocation.payload)
        case "testAPI":
            testAPI(invocation.payload)
        case "showPermissions":
            openSettings()

        case "openSettings":
            openSettings()

        case "getSettings":
            pushSettings()

        case "saveSettings":
            saveSettings(invocation.payload)
            pushSettings()

        case "connectBooks":
            reconnectBooks(requestAccessibility: true)

        case "recheckPermissions":
            reconnectBooks(requestAccessibility: false)

        case "openSystemSettings":
            let which = invocation.payload["which"] as? String
            let permission: Permission = which == "accessibility" ? .accessibility : .fullDiskAccess
            connectionRequested = true
            returningFromPermissionSettings = true
            if permission == .accessibility { _ = Permissions().requestAccessibility() }
            Permissions().openSettings(for: permission)

        case "renderStats":
            // 前端回报渲染结果：验证 UI 是否真正建起来的可靠方式
            let p = invocation.payload
            lastRenderStats = p
            writeReport()
            let overlaps = (p["overlaps"] as? String) ?? "?"
            let overlapNote = overlaps == "无" ? "无重叠 ✅" : "⚠️ 重叠: \(overlaps)"
            NSLog("""
            [BooksBridge] 前端渲染: 视图=\(p["view"] ?? "?") 侧栏宽=\(p["sidebarWidth"] ?? 0) \
            书=\(p["domBooks"] ?? 0) 对话=\(p["domConvs"] ?? 0) 高亮=\(p["domActiveConv"] ?? 0) \
            布局=\(overlapNote)
            """.replacingOccurrences(of: "\n", with: " "))
            NSLog("[BooksBridge] 区块尺寸: \(p["sizes"] ?? "?")")
            NSLog("""
            [BooksBridge] 设置面板: 导航项=\(p["domNavItems"] ?? 0) 当前页=\(p["activePane"] ?? "-") \
            服务商选项=\(p["providerOptions"] ?? 0) 范围选项=\(p["scopeOptions"] ?? 0) \
            model=\(p["modelValue"] ?? "-") baseURL=\(p["baseURLValue"] ?? "-") scope=\(p["scopeValue"] ?? "-") \
            有Key=\(p["hasAPIKey"] ?? "?") 已配置=\(p["isConfigured"] ?? "?") 徽标隐藏=\(p["settingsBadgeHidden"] ?? "?") \
            权限=\(p["permFda"] ?? "?")/\(p["permAx"] ?? "?")
            """.replacingOccurrences(of: "\n", with: " "))

        default:
            NSLog("[BooksBridge] 未知指令: \(invocation.type)")
        }
    }

    // MARK: - 进入流程
    //
    // 需求：**检测到 ≠ 进入**。侧栏顶部的"现在在读"只是提示，
    // 只有用户点它或点书库里的条目，才会把这本书落盘并进入它的 workspace。
    // 因此 `latestContext` 里的书在用户点击之前不会出现在 `store` 中。

    /// 进入某本书的 workspace。若尚未在书库里则先加入，并确保至少有一条对话。
    ///
    /// 标题来源按可靠性排序（这里踩过坑：早期实现只查 `latestContext`，
    /// 结果点书库里"不是当前在读"的书时，标题会退化成 assetID）：
    ///   1. 实时检测到的书（最新）
    ///   2. 已在书库里的记录（用户改过的名字要保留）
    ///   3. 回查图书 App 的书库数据库
    ///   4. 都没有才退化为 assetID
    private func openBook(assetID: String) {
        if let existing = store.book(assetID: assetID) { enterBook(assetID: existing.assetID); return }
        cancelPendingAnswer()
        pendingSourceImport = nil
        positionTask = Task { @MainActor in
            do {
                guard let book = try await Task.detached(operation: { try BooksStore().book(assetID: assetID) }).value else { throw ReadingAssistant.AssistantError.notLoaded }
                guard let path = book.path else { throw ReadingAssistant.AssistantError.noLocalFile }
                let source = try await Task.detached { try BookSourceIdentity.read(at: URL(fileURLWithPath: path)) }.value
                try Task.checkCancellation()
                // Verify identities at import time without rewriting IDs or conversations.
                for stored in store.state.books {
                    let ids = stored.sourceAssetIDs
                    let identity = try? await Task.detached { () -> BookSourceIdentity? in
                        for id in ids {
                            if let original = try BooksStore().book(assetID: id), let path = original.path {
                                return try BookSourceIdentity.read(at: URL(fileURLWithPath: path))
                            }
                        }
                        return nil
                    }.value
                    try Task.checkCancellation()
                    if let identity { store.bindSource(assetID: stored.assetID, identity: identity) }
                }
                let matches = store.state.books.filter { $0.sourceIdentity.map { $0.isSameFile(as: source) || $0.fingerprint == source.fingerprint } == true }
                if !matches.isEmpty {
                    let id = UUID().uuidString
                    pendingSourceImport = (id, book, source, matches.map(\.assetID))
                    bridge.push(["sourceImport": ["requestID": id, "title": book.title, "matches": matches.map { ["assetID": $0.assetID, "title": $0.displayTitle, "author": $0.author, "path": $0.sourceIdentity?.canonicalPath ?? "", "conversationCount": String($0.conversations.count)] }]])
                } else {
                    store.addBook(assetID: assetID, title: book.title, author: book.displayAuthor ?? "")
                    store.bindSource(assetID: assetID, identity: source)
                    enterBook(assetID: assetID)
                }
            } catch is CancellationError {} catch { managementResult(false, message: "读取书籍文件失败：\(error.localizedDescription)") }
        }
    }

    private func resolveSourceImport(_ payload: [String: Any]) {
        guard let pending = pendingSourceImport, payload["requestID"] as? String == pending.id else { return }
        pendingSourceImport = nil
        if payload["cancelled"] as? Bool == true { return }
        if let target = payload["assetID"] as? String, pending.matches.contains(target) {
            guard store.linkSource(assetID: target, incomingID: pending.book.assetID, identity: pending.source) else {
                managementResult(false, message: store.lastWriteError ?? "源文件关联失败，请重新添加。"); return
            }
            latestContext = latestSourceContext.map { $0.identified(by: store.canonicalAssetID($0.book.assetID)) }
            enterBook(assetID: target)
        } else if payload["separate"] as? Bool == true {
            store.addBook(assetID: pending.book.assetID, title: pending.book.title, author: pending.book.displayAuthor ?? "")
            store.bindSource(assetID: pending.book.assetID, identity: pending.source)
            enterBook(assetID: pending.book.assetID)
        }
    }

    private func enterBook(assetID: String) {
        cancelPendingAnswer()
        var title: String?
        var author: String?

        if let context = latestContext, context.book.assetID == assetID {
            title = context.book.title
            author = context.book.displayAuthor
        }
        if title == nil, let stored = store.book(assetID: assetID) {
            title = stored.title
            author = stored.author
        }
        if connectionRequested, dataAccess.isGranted, title == nil, let fetched = try? booksStore.book(assetID: assetID) {
            title = fetched.title
            author = fetched.displayAuthor
        }

        let resolvedTitle = title ?? assetID
        let resolvedAuthor = author ?? ""
        store.addBook(assetID: assetID, title: resolvedTitle, author: resolvedAuthor)
        var book = store.book(assetID: assetID)

        // 1:N —— 新进入的书默认有一条对话，用户可继续新建
        if book?.conversations.contains(where: { $0.archivedAt == nil }) != true {
            store.createConversation(assetID: assetID)
            book = store.book(assetID: assetID)
        }

        store.setActive(assetID: assetID, conversationID: book?.conversations.first(where: { $0.archivedAt == nil })?.id)
        NSLog("[BooksBridge] 进入《\(resolvedTitle)》的 workspace，对话数=\(book?.conversations.count ?? 0)")
        pushState(message: "已进入《\(resolvedTitle)》")
        prepareBook(assetID: assetID)
    }

    private func managementResult(_ success: Bool, message: String, requestID: String? = nil, recordRemoved: Bool = false) {
        pushState(message: message)
        bridge.push(["managementResult": ["success": success, "message": message, "requestID": requestID ?? "", "recordRemoved": recordRemoved]])
        statusItem.refreshTooltip()
    }

    private func requestBookIdentification() {
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            do {
                let (snapshot, books) = try await Task.detached { (try AccessibilityReader().snapshot(), try BooksStore().allBooks()) }.value
                try Task.checkCancellation()
                guard snapshot.isReaderView else { managementResult(false, message: "请先在 Apple Books 中打开书籍正文。"); return }
                let id = UUID().uuidString
                pendingBookIdentification = (id, snapshot, books.filter { $0.path != nil })
                bridge.push(["bookIdentification": ["requestID": id, "windowTitle": snapshot.windowTitles.first ?? "阅读窗口",
                    "books": books.filter { $0.path != nil }.map { ["assetID": $0.assetID, "title": $0.title, "author": $0.displayAuthor ?? "", "path": $0.path ?? ""] }]])
            } catch is CancellationError {} catch { managementResult(false, message: "无法读取当前窗口：\(error.localizedDescription)") }
        }
    }

    private func confirmBookIdentification(_ payload: [String: Any]) {
        guard let pending = pendingBookIdentification, payload["requestID"] as? String == pending.id,
              let id = payload["assetID"] as? String, pending.books.contains(where: { $0.assetID == id }) else { return }
        pendingBookIdentification = nil
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            do {
                let snapshot = try await Task.detached { try AccessibilityReader().snapshot() }.value
                try Task.checkCancellation()
                guard ActiveBookResolver.shared.token(for: snapshot) == ActiveBookResolver.shared.token(for: pending.snapshot) else {
                    managementResult(false, message: "阅读页面已变化，请重新确认当前书籍。"); return
                }
                ActiveBookResolver.shared.confirm(snapshot: snapshot, assetID: id)
                coordinator?.refresh()
                managementResult(true, message: "已确认当前页面对应的书籍；页面变化后会重新核对。")
            } catch is CancellationError {} catch { managementResult(false, message: error.localizedDescription) }
        }
    }

    /// 保存前端提交的设置。
    private func saveSettings(_ payload: [String: Any]) {
        settings.update { draft in
            if let raw = payload["provider"] as? String,
               let provider = AppSettings.Provider(rawValue: raw) {
                // 换服务商时，若地址还是旧服务商的默认值，就跟着换成新的默认值
                let wasDefault = AppSettings.Provider.allCases.contains { $0.defaultBaseURL == draft.baseURL }
                draft.provider = provider
                if wasDefault, !provider.defaultBaseURL.isEmpty {
                    draft.baseURL = provider.defaultBaseURL
                }
            }
            if let value = payload["baseURL"] as? String { draft.baseURL = value }
            if let value = payload["model"] as? String { draft.model = value }
            if let value = payload["temperature"] as? Double { draft.temperature = min(max(value, 0), 2) }
            if let raw = payload["defaultScope"] as? String,
               let scope = KnowledgeScope(rawValue: raw) {
                draft.defaultScope = scope
            }
            if let value = payload["maxContextCharacters"] as? Int {
                draft.maxContextCharacters = min(max(value, 4000), 200_000)
            }
            if let value = payload["summaryContextTokens"] as? Int { draft.summaryContextTokens = min(max(value, 4096), 2_000_000) }
            if let value = payload["autoExpandReasoning"] as? Bool { draft.autoExpandReasoning = value }
            if let raw = payload["thinkingLevel"] as? String,
               let level = AppSettings.ThinkingLevel(rawValue: raw) {
                draft.thinkingLevel = level
            }
        }
        // API Key 单独处理：空字符串表示"不改动"，显式 clear 才清空
        if let key = payload["apiKey"] as? String, !key.isEmpty {
            settings.setAPIKey(key)
        } else if payload["clearAPIKey"] as? Bool == true {
            settings.setAPIKey("")
        }
        assistant.update(settings: settings.settings, apiKey: settings.apiKey)
        NSLog("[BooksBridge] 设置已保存：provider=\(settings.settings.provider.rawValue) model=\(settings.settings.model) 已配置=\(settings.isConfigured)")
        statusItem.refreshTooltip()
    }

    /// 助手在 AppDelegate 创建时就有效；取消操作不依赖是否已进入一本书。
    func cancelPendingAnswer() {
        answerStream?.cancel()
        answerStream = nil
        positionTask?.cancel()
        assistant.cancelAnswer()
        if let pending = pendingReply, pending.retryID == nil, (!pending.text.isEmpty || !pending.reasoning.isEmpty) {
            store.saveAnswer(assetID: pending.assetID, conversationID: pending.conversationID, questionID: pending.questionID, replacing: nil,
                answer: .init(role: .assistant, text: pending.text.isEmpty ? "已停止" : pending.text, boundary: pending.text.isEmpty ? nil : assistant.lastBoundary, sourceHash: assistant.lastSourceHash, reasoning: pending.reasoning.isEmpty ? nil : pending.reasoning, reasoningExpanded: pending.reasoningExpanded))
        }
        pendingReply = nil
    }

    // MARK: - 阅读问答

    /// A single refresh path for opening, /now, questions and summaries.
    private func refreshConversation(assetID: String, conversationID: String) async throws -> (BooksBridgeCore.Book, ReadingSnapshot, ReadingContext?) {
        guard let stored = store.book(assetID: assetID), store.conversation(assetID: assetID, conversationID: conversationID) != nil else { throw CancellationError() }
        let previous = store.conversation(assetID: assetID, conversationID: conversationID)?.readingSnapshot
        let sourceIDs = stored.sourceAssetIDs
        let fresh = try await Task.detached {
            let live = ReadingCoordinator().makeContext()
            var book = live.flatMap { sourceIDs.contains($0.book.assetID) ? $0.book : nil }
            if book == nil { for id in sourceIDs.reversed() { if let candidate = try BooksStore().book(assetID: id), candidate.path != nil { book = candidate; break } } }
            guard let book, let path = book.path else { throw ReadingAssistant.AssistantError.notLoaded }
            let source = try BookSourceIdentity.read(at: URL(fileURLWithPath: path))
            return (book.identified(by: assetID), live.map { sourceIDs.contains($0.book.assetID) ? $0.identified(by: assetID) : $0 }, source)
        }.value
        try Task.checkCancellation()
        guard store.conversation(assetID: assetID, conversationID: conversationID) != nil else { throw CancellationError() }
        store.bindSource(assetID: assetID, identity: fresh.2)
        var snapshot: ReadingSnapshot
        do { snapshot = try await assistant.refresh(book: fresh.0, live: fresh.1, previous: previous) }
        catch {
            // Page recognition can fail while the local book statistics remain valid.
            if !Task.isCancelled, assistant.currentBook?.assetID == assetID, let statistics = assistant.currentStatistics {
                _ = store.updateStatistics(assetID: assetID, statistics: statistics)
                pushState(message: "本地书籍统计已更新；当前页定位仍需确认")
            }
            throw error
        }
        if let statistics = assistant.currentStatistics {
            guard store.updateStatistics(assetID: assetID, statistics: statistics) else { throw SummaryJobs.JobError.writeFailed }
        }
        if let study = store.book(assetID: assetID)?.study {
            assistant.useStatistics(study.statistics)
            if let page = snapshot.page, let section = study.statistics.sections.first(where: { $0.start < page && page <= $0.end }) {
                snapshot = ReadingSnapshot(assetID: snapshot.assetID, sourceHash: snapshot.sourceHash, page: page, chapterTitle: section.title,
                    progress: snapshot.progress, capturedAt: snapshot.capturedAt, reused: snapshot.reused)
            }
        }
        try Task.checkCancellation()
        store.updateReading(assetID: assetID, conversationID: conversationID, snapshot: snapshot)
        pushState(message: snapshot.label)
        return (fresh.0, snapshot, fresh.1)
    }

    private func prepareBook(assetID: String) {
        guard let id = store.state.lastActive?.conversationID,
              let conversation = store.conversation(assetID: assetID, conversationID: id), conversation.archivedAt == nil else { return }
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            do {
                let (_, snapshot, _) = try await refreshConversation(assetID: assetID, conversationID: id)
                if store.conversation(assetID: assetID, conversationID: id)?.messages.isEmpty == true {
                    store.appendMessage(assetID: assetID, conversationID: id, message: .init(role: .assistant, text: snapshot.label, isPositionCard: true))
                    if store.state.lastActive?.assetID == assetID, store.state.lastActive?.conversationID == id {
                        bridge.push(["positionCard": snapshot.label])
                    }
                }
            } catch is CancellationError {} catch {
                if store.state.lastActive?.assetID == assetID, store.state.lastActive?.conversationID == id {
                    bridge.push(["readingCheck": "本地书籍读取失败：\(error)"])
                }
            }
        }
    }

    private func validateStructurePermission(assetID: String, conversationID: String, scope: KnowledgeScope) throws {
        if store.structurePermissionRequired(assetID: assetID, conversationID: conversationID, scope: scope) {
            throw NSError(domain: "BooksBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "章节结构已改变。请在摘要面板确认本对话新的整章范围，再发送或生成摘要。"])
        }
    }

    private func handleStructure(_ action: String, payload: [String: Any]) {
        guard let assetID = payload["assetID"] as? String, let stored = store.book(assetID: assetID) else { return }
        if action == "cancelStructure" { structureJobs.cancel(assetID, store: store); return }
        if action == "discardStructure" {
            guard var study = stored.study, study.proposedStructure?.id.uuidString == payload["proposalID"] as? String else { return }
            study.proposedStructure = nil; study.structureStatus = "已放弃章节建议，原有结构保留"
            let saved = store.saveStudy(assetID: assetID, study: study)
            pushState(message: saved ? "章节建议已放弃" : "保存失败，章节建议仍保留"); return
        }
        guard payload["confirmed"] as? Bool == true else { return }
        if action == "confirmStructureScope" {
            guard let id = payload["conversationID"] as? String, let version = payload["version"] as? String else { return }
            let ok = store.confirmStructure(assetID: assetID, conversationID: id, version: version)
            pushState(message: ok ? "已确认本对话新的整章范围" : "结构已变化，请重新确认"); return
        }
        guard connectionRequested, dataAccess.isGranted, let path = stored.sourceIdentity?.canonicalPath else {
            pushState(message: "请先连接并读取本地书籍，再整理章节"); return
        }
        let book = BooksBridgeCore.Book(assetID: assetID, title: stored.title, author: stored.author, progress: 0, contentType: .epub, path: path, lastOpened: nil)
        if action == "analyzeStructure" {
            guard assistant.isConfigured else { pushState(message: "请先配置模型接口"); return }
            structureJobs.start(book: book, settings: settings.settings, apiKey: settings.apiKey, store: store); return
        }
        guard action == "applyStructure" || action == "restoreStructure" else { return }
        // Re-read the source without asking Apple Books to navigate or change anything.
        Task { @MainActor in
            do {
                let loader = ReadingAssistant(settings: settings.settings, apiKey: "")
                _ = try await loader.refresh(book: book, live: nil, previous: nil, persistMap: false)
                guard store.book(assetID: assetID)?.libraryID == stored.libraryID, let local = loader.currentStatistics,
                      store.updateStatistics(assetID: assetID, statistics: local), var study = store.book(assetID: assetID)?.study,
                      study.statistics.structureVersion == payload["version"] as? String else { throw ChapterStructure.Failure.invalid }
                if action == "applyStructure" {
                    guard let proposal = study.proposedStructure, proposal.id.uuidString == payload["proposalID"] as? String,
                          study.applyStructure(proposal) else { throw ChapterStructure.Failure.invalid }
                } else { study.restoreLocalStructure() }
                cancelPendingAnswer(); positionTask?.cancel()
                summaryJobs.cancel(assetID: assetID, store: store); structureJobs.cancel(assetID, store: store)
                guard store.saveStudy(assetID: assetID, study: study) else { throw SummaryJobs.JobError.writeFailed }
                if assistant.currentBook?.assetID == assetID { assistant.useStatistics(study.statistics) }
                for conversation in store.book(assetID: assetID)?.conversations ?? [] {
                    guard let old = conversation.readingSnapshot, old.sourceHash == study.statistics.sourceHash, let page = old.page,
                          let section = study.statistics.sections.first(where: { $0.start < page && page <= $0.end }) else { continue }
                    store.updateReading(assetID: assetID, conversationID: conversation.id,
                        snapshot: ReadingSnapshot(assetID: assetID, sourceHash: old.sourceHash, page: page, chapterTitle: section.title,
                            progress: old.progress, capturedAt: old.capturedAt, reused: old.reused))
                }
                pushState(message: "章节结构已更新；整章模式需在各对话确认新的读取范围")
            } catch { pushState(message: "章节结构未应用：\(error.localizedDescription)") }
        }
    }

    private func generateSummary(_ payload: [String: Any]) {
        guard let active = store.state.lastActive, let id = active.conversationID,
              store.conversation(assetID: active.assetID, conversationID: id)?.archivedAt == nil else { return }
        let requested = (payload["scope"] as? String).flatMap(KnowledgeScope.init(rawValue:)) ?? settings.settings.defaultScope
        guard let scope = store.lockScope(assetID: active.assetID, conversationID: id, requested: requested) else { return }
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            do {
                let (book, snapshot, _) = try await refreshConversation(assetID: active.assetID, conversationID: id)
                try validateStructurePermission(assetID: active.assetID, conversationID: id, scope: scope)
                _ = try assistant.reading(snapshot: snapshot, scope: scope)
                summaryJobs.start(book: book, snapshot: snapshot, chapters: assistant.currentChapters,
                    scope: scope, settings: settings.settings, apiKey: settings.apiKey, store: store)
            } catch is CancellationError {} catch {
                if var study = store.book(assetID: active.assetID)?.study {
                    study.status = "摘要失败：\(error)"; _ = store.saveStudy(assetID: active.assetID, study: study)
                }
                pushState(message: "摘要未发送")
            }
        }
    }

    private func captureSelection() {
        guard let active = store.state.lastActive, let id = active.conversationID,
              store.conversation(assetID: active.assetID, conversationID: id)?.archivedAt == nil else { return }
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            do {
                let (_, snapshot, live) = try await refreshConversation(assetID: active.assetID, conversationID: id)
                guard let live, live.book.assetID == active.assetID,
                      let text = live.selection, !text.isEmpty, text.count <= 10000 else {
                    bridge.push(["selectionCandidate": ["error": "没有检测到本书的选中文字；请先在 Books 中划选。"]]); return
                }
                guard store.state.lastActive?.assetID == active.assetID, store.state.lastActive?.conversationID == id else { return }
                let token = UUID().uuidString
                selectionCandidate = ConfirmedReference(token: token, assetID: active.assetID, conversationID: id, sourceHash: snapshot.sourceHash, text: text)
                bridge.push(["selectionCandidate": ["token": token, "text": text, "exact": live.selectionIsExact]])
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, store.state.lastActive?.assetID == active.assetID,
                      store.state.lastActive?.conversationID == id else { return }
                bridge.push(["selectionCandidate": ["error": String(describing: error)]])
            }
        }
    }

    /// 发起提问。
    private func testAPI(_ payload: [String: Any]) {
        apiTestTask?.cancel()
        apiTestGeneration += 1
        let generation = apiTestGeneration
        let requestID = payload["requestID"] as? String ?? ""
        let base = payload["baseURL"] as? String ?? settings.settings.baseURL
        let model = payload["model"] as? String ?? settings.settings.model
        let key = (payload["apiKey"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? settings.apiKey
        apiTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let start = Date()
            do {
                let result = try await ChatClient(baseURL: base, apiKey: key, timeout: 15).complete(
                    model: model, messages: [.user("Reply OK.")], maxTokens: 8)
                try Task.checkCancellation()
                guard generation == self.apiTestGeneration else { return }
                guard !result.text.isEmpty else { throw ChatClient.ClientError.decoding("模型没有返回内容") }
                self.bridge.push(["apiTest": ["requestID": requestID, "text": String(format: "可用 · %@ · %.0f ms · %@", model, Date().timeIntervalSince(start) * 1000, Date().formatted(date: .omitted, time: .standard))]])
            } catch {
                guard !Task.isCancelled, generation == self.apiTestGeneration else { return }
                self.bridge.push(["apiTest": ["requestID": requestID, "text": "检测失败：\(error)"]])
            }
        }
    }

    private func checkReading(_ payload: [String: Any]) {
        guard let active = store.state.lastActive, let id = active.conversationID,
              store.conversation(assetID: active.assetID, conversationID: id)?.archivedAt == nil else { return }
        positionTask?.cancel()
        positionTask = Task { @MainActor in
            do {
                let (_, snapshot, _) = try await refreshConversation(assetID: active.assetID, conversationID: id)
                let scope = store.conversation(assetID: active.assetID, conversationID: id)?.scope
                    ?? (payload["scope"] as? String).flatMap(KnowledgeScope.init(rawValue:)) ?? settings.settings.defaultScope
                try validateStructurePermission(assetID: active.assetID, conversationID: id, scope: scope)
                let reading = try assistant.reading(snapshot: snapshot, scope: scope)
                guard store.state.lastActive?.assetID == active.assetID, store.state.lastActive?.conversationID == id else { return }
                bridge.push(["readingCheck": "\(snapshot.label) · 可读取 \(reading.chapters.reduce(0) { $0 + $1.text.count }) 字 · 本地检查，未调用 API"])
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, store.state.lastActive?.assetID == active.assetID,
                      store.state.lastActive?.conversationID == id else { return }
                bridge.push(["readingCheck": "检查失败：\(error)"])
            }
        }
    }

    private func handleMessageAction(_ action: String, payload: [String: Any]) {
        guard let active = store.state.lastActive, let cid = active.conversationID,
              payload["assetID"] as? String == active.assetID, payload["conversationID"] as? String == cid,
              let id = payload["messageID"] as? String,
              let conversation = store.conversation(assetID: active.assetID, conversationID: cid),
              let message = conversation.messages.first(where: { $0.id == id }) else { return }
        if action == "copyMessage" {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string); return
        }
        guard conversation.archivedAt == nil, answerStream == nil else { return }
        if action == "retryMessage" {
            guard let question = conversation.retryQuestion(for: id) else { return }
            ask(["question": question.text], retryID: id, questionID: question.id)
        } else {
            let text = payload["text"] as? String
            if action == "editMessage" {
                guard let text, text.count <= max(500, settings.settings.maxContextCharacters / 4) else {
                    bridge.push(["messageActionError": "修改内容超过请求预算，请缩短后保存"]); return
                }
            }
            if store.changeMessage(assetID: active.assetID, conversationID: cid, messageID: id, text: action == "editMessage" ? text : nil) {
                pushState(message: action == "editMessage" ? "修改已保存，可点击回答下方的重试重新生成" : "消息已删除")
            }
        }
    }

    private func ask(_ payload: [String: Any], retryID: String? = nil, questionID: String? = nil) {
        guard let question = (payload["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty,
              let active = store.state.lastActive, let conversationID = active.conversationID,
              store.conversation(assetID: active.assetID, conversationID: conversationID)?.archivedAt == nil else { return }
        guard connectionRequested, dataAccess.isGranted else {
            bridge.push(["chatEvent": ["kind": "error", "text": "请先连接 Apple Books，以读取本书最新进度"]])
            return
        }
        guard question.count <= max(500, settings.settings.maxContextCharacters / 4) else {
            bridge.push(["chatEvent": ["kind": "error", "text": "问题超过请求预算，请缩短后发送"]]); return
        }
        let command = ReadingCommand(question)
        let isNow = command.refreshOnlyOrFirst
        let request = command.question
        if retryID != nil && request.isEmpty {
            bridge.push(["chatEvent": ["kind": "error", "text": "这条消息只有本地命令，请先修改为问题再重试"]]); return
        }
        let requested = (payload["scope"] as? String).flatMap(KnowledgeScope.init(rawValue:)) ?? settings.settings.defaultScope
        let scope = request.isEmpty ? requested : store.lockScope(assetID: active.assetID, conversationID: conversationID, requested: requested) ?? requested
        let conversation = store.conversation(assetID: active.assetID, conversationID: conversationID)!
        let end = questionID.flatMap { id in conversation.messages.firstIndex { $0.id == id } } ?? conversation.messages.count
        let previous = Array(conversation.messages.prefix(end).dropFirst(conversation.scopeHistoryStartIndex ?? 0)).filter { $0.isPositionCard != true }
        let history: [ChatMessage] = previous.map { $0.role == .user ? .user($0.text) : .assistant($0.text) }
        let userMessage = Conversation.Message(id: questionID ?? UUID().uuidString, role: .user, text: question, isPositionCard: request.isEmpty)
        if retryID == nil { store.appendMessage(assetID: active.assetID, conversationID: conversationID, message: userMessage) }
        cancelPendingAnswer()
        pendingReply = (active.assetID, conversationID, userMessage.id, retryID, "", "", nil)
        answerStream = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { answerStream = nil; pendingReply = nil } }
            do {
                let assetID = active.assetID
                let (book, snapshot, live) = try await refreshConversation(assetID: assetID, conversationID: conversationID)
                guard !Task.isCancelled, store.state.lastActive?.assetID == assetID, store.state.lastActive?.conversationID == conversationID else { return }
                if isNow && retryID == nil {
                    store.appendMessage(assetID: assetID, conversationID: conversationID, message: .init(role: .assistant, text: snapshot.label, isPositionCard: true))
                    if request.isEmpty {
                        bridge.push(["chatEvent": ["kind": "finished", "text": snapshot.label, "roleLabel": "阅读位置（本地）"]])
                        pushState(message: "位置已刷新，未调用模型"); return
                    }
                    bridge.push(["positionCard": snapshot.label])
                }
                try validateStructurePermission(assetID: assetID, conversationID: conversationID, scope: scope)
                let allowed = try assistant.reading(snapshot: snapshot, scope: scope)
                if retryID != nil, !ConfirmedReference.canReplay(question: question, reading: allowed) { throw SelectionError.invalid }
                var prompt = request
                if let token = payload["selectionToken"] as? String {
                    guard let selection = selectionCandidate,
                          selection.validated(token: token, confirmed: payload["selectionConfirmed"] as? Bool == true,
                            snapshot: snapshot, conversationID: conversationID, reading: allowed) != nil else {
                        throw SelectionError.invalid
                    }
                    prompt += "\n\n用户确认引用的文字：\n" + selection.text
                    store.updateConversation(assetID: assetID, conversationID: conversationID) {
                        if let index = $0.messages.lastIndex(where: { $0.role == .user }) { $0.messages[index].text = question + "\n\n引用：\n" + selection.text }
                    }
                    selectionCandidate = nil
                }
                let visible = live?.book.assetID == assetID ? live?.visibleText ?? [] : []
                let stream = assistant.ask(book: book, currentCFI: live?.book.assetID == assetID ? live?.position?.cfi : nil,
                    question: prompt, scope: scope, visibleText: visible, history: history,
                    historyBoundaries: previous.map(\.boundary), historySourceHashes: previous.map(\.sourceHash),
                    snapshot: snapshot, summary: store.book(assetID: assetID)?.study?.summary(snapshot: snapshot, scope: scope), study: store.book(assetID: assetID)?.study)
                for await event in stream {
                    guard !Task.isCancelled, store.state.lastActive?.assetID == assetID,
                          store.state.lastActive?.conversationID == conversationID else { break }
                    handleAssistantEvent(event, questionID: userMessage.id, retryID: retryID)
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, store.state.lastActive?.assetID == active.assetID,
                      store.state.lastActive?.conversationID == conversationID else { return }
                handleAssistantEvent(.failed(String(describing: error)), questionID: userMessage.id, retryID: retryID)
            }
        }
    }

    private enum SelectionError: Error, CustomStringConvertible {
        case invalid
        var description: String { "引用尚未确认、已失效或超出当前读取范围；请重新划选并确认。" }
    }

    /// 把助手事件转成前端可消费的推送。
    private func handleAssistantEvent(_ event: ReadingAssistant.Event, questionID: String, retryID: String?) {
        switch event {
        case .contextPrepared(let text):
            bridge.push(["chatEvent": ["kind": "status", "text": text]])
        case .reasoningDelta(let delta):
            pendingReply?.reasoning += delta
            bridge.push(["chatEvent": ["kind": "reasoning", "text": delta]])

        case .answerDelta(let delta):
            pendingReply?.text += delta
            bridge.push(["chatEvent": ["kind": "delta", "text": delta]])

        case .finished(let answer, let scopeDescription, let usage):
            let reasoning = pendingReply?.reasoning
            let reasoningExpanded = pendingReply?.reasoningExpanded
            pendingReply = nil
            // 落盘助手回答
            if let active = store.state.lastActive,
               let conversationID = active.conversationID {
                store.saveAnswer(assetID: active.assetID, conversationID: conversationID, questionID: questionID, replacing: retryID,
                    answer: .init(role: .assistant, text: answer, boundary: assistant.lastBoundary, sourceHash: assistant.lastSourceHash, reasoning: reasoning?.isEmpty == false ? reasoning : nil, reasoningExpanded: reasoningExpanded))
            }
            var payload: [String: Any] = [
                "kind": "finished",
                "text": answer,
                "scope": scopeDescription,
            ]
            if let usage {
                payload["usage"] = [
                    "prompt": usage.promptTokens,
                    "completion": usage.completionTokens,
                    "cached": usage.cachedTokens,
                ]
            }
            bridge.push(["chatEvent": payload])
            pushState(message: "回答完成")

        case .failed(let message):
            if let pending = pendingReply, pending.retryID == nil, (!pending.text.isEmpty || !pending.reasoning.isEmpty) {
                store.saveAnswer(assetID: pending.assetID, conversationID: pending.conversationID, questionID: pending.questionID, replacing: nil,
                    answer: .init(role: .assistant, text: pending.text.isEmpty ? "生成失败：" + message : pending.text, boundary: pending.text.isEmpty ? nil : assistant.lastBoundary,
                        sourceHash: assistant.lastSourceHash, reasoning: pending.reasoning.isEmpty ? nil : pending.reasoning, reasoningExpanded: pending.reasoningExpanded))
            }
            pendingReply = nil
            bridge.push(["chatEvent": ["kind": "error", "text": message]])
            pushState(message: "问答失败")
        }
    }

    /// 在指定书下新建对话并切过去。
    private func newConversation(assetID: String) {
        cancelPendingAnswer()
        guard let conversation = store.createConversation(assetID: assetID) else {
            NSLog("[BooksBridge] 新建对话失败：书 \(assetID) 不在书库中")
            return
        }
        store.setActive(assetID: assetID, conversationID: conversation.id)
        pushState(message: "已新建 \(conversation.title)")
        prepareBook(assetID: assetID)
    }

    /// 把"检测不到"归类，让前端能给出准确的提示而不是笼统的"未在阅读"。
    private static func classifyDetectionIssue(
        issue: String?,
        permissions: Permissions,
        booksRunning: Bool
    ) -> String {

        if !booksRunning { return "booksNotRunning" }
        if let issue, issue.contains("kLastCurrentBookKey") { return "noBookOpen" }
        if let issue, issue.contains("无法唯一匹配") { return "ambiguousBook" }
        if issue != nil { return "transientError" }
        return "waiting"
    }

    /// 把本次启动的自检快照写到 `booksbridge-permission-report.txt`。
    ///
    /// 存在的理由：TCC 授权按"进程主体"判定，从终端直接跑会继承终端的权限，
    /// 用 `open`/Finder 启动才是独立主体，两者结果可能完全不同。
    /// 日志用 `log show` 不一定抓得到，落到文件最省事，用户也能直接发出来。
    ///
    /// 写入方式是**整份重写**：权限段与 UI 段各自到达时间不同，
    /// 早期版本用"读回来再追加"，会在权限段尚未写入时把文件覆盖成只剩 UI 段。
    private func writeReport() {
        let permissions = Permissions()
        let fda = dataAccess
        let ax = permissions.accessibilityStatus()

        var lines: [String] = []
        lines.append("=== BooksBridge 自检报告 ===")
        lines.append("时间: \(Date())")
        lines.append("bundle: \(Bundle.main.bundlePath)")
        lines.append("签名: \(Self.signatureSummary())")
        lines.append("")
        lines.append("--- 权限 ---")
        lines.append("完全磁盘访问权限: \(fda.label)")
        lines.append("辅助功能权限:    \(ax.label)")
        lines.append("")
        lines.append("--- 实际读取探测（这才是最终依据）---")
        for probe in cachedProbe["probes"] as? [[String: Any]] ?? [] {
            lines.append("\(probe["result"] ?? "未知")  \(probe["path"] ?? "")")
        }

        if let stats = lastRenderStats {
            lines.append("")
            lines.append("--- UI 渲染 ---")
            lines.append("视图: \(stats["view"] ?? "?")   侧栏宽: \(stats["sidebarWidth"] ?? "?")")
            lines.append("布局重叠: \(stats["overlaps"] ?? "?")")
            lines.append("区块尺寸: \(stats["sizes"] ?? "?")")
            lines.append("书=\(stats["domBooks"] ?? 0) 对话=\(stats["domConvs"] ?? 0) 高亮=\(stats["domActiveConv"] ?? 0)")
            lines.append("设置页: 导航=\(stats["domNavItems"] ?? 0) 当前=\(stats["activePane"] ?? "-") 服务商选项=\(stats["providerOptions"] ?? 0) 范围选项=\(stats["scopeOptions"] ?? 0)")
            lines.append("权限探测行数: \(stats["probeRows"] ?? 0)  全部可读: \(stats["probeAllOk"] ?? "?")")
        }

        let report = lines.joined(separator: "\n")
        if lastRenderStats == nil {
            // 只在首次（权限段）打印一次日志，避免刷新时刷屏
            NSLog("[BooksBridge] \(report.replacingOccurrences(of: "\n", with: " | "))")
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("booksbridge-permission-report.txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 权限探测详情，供设置页展示"到底哪一步被拒绝"。
    ///
    /// 只看 `AXIsProcessTrusted` 与目录是否存在不够——`open` 启动的进程是独立
    /// TCC 主体，必须真正尝试 `open(2)` 才知道有没有被拦。
    private static func permissionProbePayload() -> [String: Any] {
        let paths = BooksPaths()
        var probes: [[String: Any]] = []
        for (label, path) in [
            ("图书数据目录", paths.container.path),
            ("书库数据库", paths.libraryDatabase()?.path ?? ""),
            ("阅读位置数据库", paths.annotationDatabase()?.path ?? ""),
        ] {
            guard !path.isEmpty else {
                probes.append(["label": label, "path": "(未找到)", "result": "未找到", "ok": false])
                continue
            }
            let result = Permissions.probeRead(path)
            probes.append([
                "label": label,
                "path": path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
                ),
                "result": result,
                "ok": result.contains("可读"),
            ])
        }
        return [
            "probes": probes,
            "signature": signatureSummary(),
            "bundlePath": Bundle.main.bundlePath,
        ]
    }

    /// 激活策略的可读名称。
    ///
    /// 这个值决定了应用是否出现在 Dock 与系统设置的权限列表里，
    /// 排查权限问题时经常要看。
    private static func activationPolicyName() -> String {
        switch NSApp.activationPolicy() {
        case .regular: "regular（有 Dock 图标，可被授权）"
        case .accessory: "accessory（无 Dock 图标，难被授权）"
        case .prohibited: "prohibited（后台，无 UI）"
        @unknown default: "未知(\(NSApp.activationPolicy().rawValue))"
        }
    }

    /// 当前签名的简要说明，用于解释"为什么重建后要重新授权"。
    private static func signatureSummary() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "未知" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return "未知" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let dict = info as? [String: Any] else { return "未知" }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? "无"
        let isAdhoc = (dict[kSecCodeInfoFlags as String] as? UInt32).map { $0 & 0x2 != 0 } ?? false
        return "\(isAdhoc ? "ad-hoc 临时签名" : "已签名") · identifier=\(identifier)"
    }

    // MARK: - 数据层

    /// 启动阅读监测。`ReadingCoordinator` 内部用 DispatchSource 监听
    /// 图书 App 的 `.sqlite-wal`，翻页即触发，实测延迟 0 秒。
    private func startReadingCoordinator() {
        let generation = connectionGeneration
        coordinator = ReadingCoordinator()
        coordinator.onIssue = { [weak self] message in
            NSLog("[BooksBridge] 采集提示: \(message)")
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.latestContext = nil
                self.latestSourceContext = nil
                self.detectionIssue = message
                self.statusItem.refreshTooltip()
                self.pushState(message: "采集受阻")
            }
        }
        coordinator.onUpdate = { [weak self] context in
            // 回调在 coordinator 的队列上，切回主线程再碰 AppKit / WebView
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.latestSourceContext = context
                self.latestContext = context.identified(by: self.store.canonicalAssetID(context.book.assetID))
                self.detectionIssue = nil
                self.refreshStatusLine()
                self.pushState(message: "阅读位置已更新")
            }
        }
        coordinator.start()
    }

    // MARK: - 设置

    /// 把设置推给前端。`open: true` 时前端会切到设置页。
    private func pushSettings(open: Bool = false) {
        guard frontendReady else { return }
        var body: [String: Any] = [
            "settings": [
                "provider": settings.settings.provider.rawValue,
                "baseURL": settings.settings.baseURL,
                "model": settings.settings.model,
                "temperature": settings.settings.temperature,
                "defaultScope": settings.settings.defaultScope.rawValue,
                "maxContextCharacters": settings.settings.maxContextCharacters,
                "thinkingLevel": settings.settings.thinkingLevel.rawValue,
                "autoExpandReasoning": settings.settings.autoExpandReasoning,
                "summaryContextTokens": settings.settings.summaryContextTokens,
                // 只暴露"是否已填"，不回传明文
                "hasAPIKey": settings.hasAPIKey,
                "isConfigured": settings.isConfigured,
            ],
            "providers": AppSettings.Provider.allCases.map { provider in
                [
                    "id": provider.rawValue,
                    "label": provider.label,
                    "defaultBaseURL": provider.defaultBaseURL,
                    "requiresAPIKey": provider.requiresAPIKey,
                    "models": provider.suggestedModels,
                ] as [String: Any]
            },
            "thinkingLevels": AppSettings.ThinkingLevel.allCases.map { level in
                ["id": level.rawValue, "label": level.label, "explanation": level.explanation]
            },
            "knowledgeScopes": KnowledgeScope.allCases.map { scope in
                ["id": scope.rawValue, "label": scope.label, "explanation": scope.explanation]
            },
            "permissionProbe": cachedProbe,
        ]
        if open { body["openSettings"] = true }
        bridge.push(body)
    }

    // MARK: - 状态推送

    private func refreshStatusLine() {
        statusItem?.refreshTooltip()
    }

    /// 把当前状态推给前端。
    ///
    /// payload 形状与前端 `app.js` 约定一致，分三段：
    /// - `detected`：实时检测到的书。**只用于提示，不代表用户已进入**
    /// - `library` ：用户主动加入书库的书及其对话（来自 store.json）
    /// - `active`  ：用户当前停留的位置
    private func pushState(message: String) {
        guard frontendReady else { return }

        let permissions = Permissions()
        let fda = dataAccess
        let ax = permissions.accessibilityStatus()

        var facts: [String: String] = [
            "窗口模式": windowMode.rawValue,
            "图书数据访问": fda.label,
            "辅助功能": ax.label,
            "书库本数": String(store.state.books.count),
        ]

        let jobs = store.state.books.compactMap { book -> [String: String]? in
            guard let study = book.study else { return nil }
            return ["title": book.displayTitle, "status": summaryJobs.failureStatus(assetID: book.assetID) ?? study.status]
        }
        var body: [String: Any] = ["message": message, "facts": facts, "preparationJobs": jobs, "sidebarLayout": sidebarLayout.payload]
        body["assistant"] = ["preparation": "本地章节地图 · 摘要按需生成", "ready": false]
        body["readingPosition"] = "尚未取得有效阅读位置"
        body["scopeSummary"] = ""
        body["summaryMetadata"] = "尚未生成摘要"
        body["bookStatistics"] = NSNull()
        body["chapterStructure"] = NSNull()
        if let active = store.state.lastActive, let id = active.conversationID,
           let conversation = store.conversation(assetID: active.assetID, conversationID: id) {
            body["readingPosition"] = conversation.readingSnapshot?.label ?? "尚未取得有效阅读位置"
            if let study = store.book(assetID: active.assetID)?.study {
                let scope = conversation.scope ?? settings.settings.defaultScope
                let proposal = study.proposedStructure
                let page = conversation.readingSnapshot?.sourceHash == study.statistics.sourceHash ? conversation.readingSnapshot?.page : nil
                body["chapterStructure"] = ["assetID": active.assetID, "conversationID": id,
                    "version": study.statistics.structureVersion, "proposalID": proposal?.id.uuidString ?? "",
                    "status": structureJobs.failure(active.assetID) ?? study.structureStatus ?? "尚未使用辅助章节整理",
                    "issues": ChapterStructure.issues(study.localStatistics ?? study.statistics).joined(separator: "；"),
                    "running": structureJobs.isRunning(active.assetID), "applied": study.appliedStructure != nil,
                    "structureChanged": study.localStatistics != nil, "scopeConfirmed": conversation.confirmedStructureVersion == study.statistics.structureVersion,
                    "needsConfirmation": store.structurePermissionRequired(assetID: active.assetID, conversationID: id, scope: scope),
                    "oldCount": study.statistics.sections.count, "newCount": proposal?.statistics.sections.count ?? 0,
                    "uncertain": proposal?.uncertainCount ?? 0,
                    "rows": proposal?.nodes.enumerated().map { index, node -> String in
                        let title = scope == .wholeBook || page.map { node.start < $0 } == true ? node.title : "范围外标题"
                        let level = node.parentID == nil ? "" : "↳ "
                        return "\(index + 1). \(level)\(title) · \(ChapterStructure.label(node.kind)) · 文档 \(node.start.chapter + 1):\(node.start.end) · \(node.startsSection ? "独立区段" : "合入前章")\(node.confidence < 0.75 || node.kind == "unknown" ? " · 待核对" : "")"
                    } ?? []] as [String: Any]
                let needsScopeConfirmation = store.structurePermissionRequired(assetID: active.assetID, conversationID: id, scope: scope)
                let safe = needsScopeConfirmation ? nil : conversation.readingSnapshot.flatMap { study.summary(snapshot: $0, scope: scope) }
                body["scopeSummary"] = safe?.text ?? ""
                body["summaryMetadata"] = (safe?.coverageLabel ?? "当前范围暂无可用摘要") + (study.whole != nil && scope != .wholeBook ? " · 全书摘要已生成，当前权限不读取" : "")
                body["assistant"] = ["preparation": summaryJobs.failureStatus(assetID: active.assetID) ?? study.status, "ready": safe != nil, "hasSharedSummary": study.completedCount > 0 || study.whole != nil]
                let allowed = conversation.readingSnapshot.map { study.allowedSections(snapshot: $0, scope: needsScopeConfirmation ? .upToProgress : scope).map(\.id) } ?? []
                body["bookStatistics"] = ["characters": study.statistics.characterCount, "estimatedTokens": study.statistics.estimatedTokens,
                    "documents": study.statistics.documentCount, "headings": study.statistics.headingCount, "chapterCount": study.statistics.chapterCount,
                    "completed": study.completedCount, "wholeComplete": study.whole != nil,
                    "chapters": study.statistics.sections.enumerated().map { index, section -> [String: Any] in
                        let partial = scope == .upToProgress && conversation.readingSnapshot.map { snapshot in
                            snapshot.sourceHash == study.statistics.sourceHash && snapshot.page.map { section.start < $0 && $0 < section.end } == true
                        } == true
                        return ["number": index + 1, "title": allowed.contains(section.id) || partial ? section.title : "区段 \(index + 1)（范围外）",
                         "kind": section.kind, "partial": partial,
                         "characters": section.characterCount, "estimatedTokens": section.estimatedTokens,
                         "complete": study.digest(for: section) != nil, "allowed": allowed.contains(section.id)]
                    }]
            }
        }

        body["detected"] = NSNull()
        // --- detected：实时检测，不落盘 ---
        if let context = latestContext {
            let book = context.book
            facts["检测到的书"] = book.title
            facts["进度"] = String(format: "%.1f%%", book.progress * 100)
            facts["位置"] = context.position?.cfi ?? context.position?.raw ?? "(无)"
            facts["屏幕可见段落"] = String(context.visibleText.count)

            var detected: [String: Any] = [
                "assetID": book.assetID,
                "title": store.book(assetID: book.assetID)?.displayTitle ?? book.title,
                "author": book.displayAuthor ?? "",
                "progress": book.progress,
                "kind": book.contentType.label,
                // 已经在书库里的话前端可以直接标记"已加入"
                "inLibrary": store.book(assetID: book.assetID) != nil,
            ]
            if let cfi = context.position?.cfi { detected["cfi"] = cfi }
            if let selection = context.selection {
                detected["selection"] = String(selection.prefix(200))
            }
            body["detected"] = detected
        } else {
            facts["检测到的书"] = "(无)"
        }

        // 区分三种"检测不到"：缺权限 / 图书未运行 / 图书没打开书
        if latestContext == nil {
            body["detectionState"] = !connectionRequested ? "disconnected" : !dataAccess.isGranted ? "dataUnavailable" : Self.classifyDetectionIssue(
                issue: detectionIssue,
                permissions: permissions,
                booksRunning: !NSRunningApplication
                    .runningApplications(withBundleIdentifier: AccessibilityReader.booksBundleID)
                    .isEmpty
            )
        } else {
            body["detectionState"] = "ok"
        }

        // --- library：持久化的书与对话 ---
        body["library"] = store.state.books.map { book -> [String: Any] in
            [
                "assetID": book.assetID,
                "title": book.displayTitle,
                "originalTitle": book.title,
                "customTitle": book.customTitle ?? "",
                "author": book.author,
                "conversations": book.conversations.map { conversation -> [String: Any] in
                    [
                        "id": conversation.id,
                        "title": conversation.displayTitle,
                        "customTitle": conversation.customTitle ?? "",
                        "messageCount": conversation.messages.count,
                        "archived": conversation.archivedAt != nil,
                        "summaryStatus": summaryJobs.failureStatus(assetID: book.assetID) ?? book.study?.status ?? "",
                        "updatedAt": ISO8601DateFormatter().string(from: conversation.updatedAt),
                    ]
                },
            ]
        }

        // --- active：用户当前停留位置，并带上该会话的消息 ---
        //
        // 消息随 active 一起推，是为了让前端在切换会话时能整段重绘历史。
        // 前端会比对会话标识，只有真的换了会话才重建 DOM，
        // 因此不会与流式渲染互相打架。
        body["active"] = NSNull()
        if let active = store.state.lastActive {
            var payload: [String: Any] = ["assetID": active.assetID]
            if let conversationID = active.conversationID {
                payload["conversationID"] = conversationID
                if let conversation = store.conversation(
                    assetID: active.assetID, conversationID: conversationID
                ) {
                    payload["scope"] = conversation.scope?.rawValue ?? NSNull() as Any
                    payload["archived"] = conversation.archivedAt != nil
                    payload["messages"] = conversation.messages.map { message in
                        [
                            "id": message.id,
                            "canRetry": conversation.retryQuestion(for: message.id) != nil,
                            "role": message.role.rawValue,
                            "text": message.text,
                            "reasoning": message.reasoning ?? NSNull() as Any,
                            "reasoningExpanded": message.reasoningExpanded ?? NSNull() as Any,
                            "createdAt": ISO8601DateFormatter().string(from: message.createdAt),
                            "isPositionCard": message.isPositionCard == true,
                        ] as [String: Any]
                    }
                }
            }
            body["active"] = payload
        }

        body["permissionLabels"] = ["fullDiskAccess": fda.label, "accessibility": ax.label]
        body["detected"] = body["detected"] ?? NSNull()
        body["permissions"] = [
            "fullDiskAccess": fda.isGranted,
            "accessibility": ax.isGranted,
        ]

        bridge.push(body)

        NSLog("[BooksBridge] 推送: \(message) | 检测=\(facts["检测到的书"] ?? "-") | 书库=\(store.state.books.count) 本 | 停留=\(store.state.lastActive?.assetID ?? "-")")
    }
}
