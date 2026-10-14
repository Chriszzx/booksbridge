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
    /// 图书 App 的书库数据源，用于回查书名等元数据。
    private let booksStore = BooksStore()
    /// 应用设置（服务商、模型、上下文范围）与 API Key。
    private var settings: SettingsStore!
    /// 阅读问答编排：预处理与流式问答。
    private let assistant = ReadingAssistant(settings: AppSettings(), apiKey: "")
    /// 当前问答的流式事件流，用于取消。
    private var answerStream: Task<Void, Never>?

    /// 最近一次采集到的阅读上下文；未检测到时为 nil。
    private var latestContext: ReadingContext?
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
        assistant.update(settings: settings.settings, apiKey: settings.apiKey)
        writeReport()


        page = PageWindowController(mode: windowMode) { [weak self] in
            self?.returnToReader()
        }
        bridge = WebBridge()
        bridge.onInvocation = { [weak self] invocation in
            self?.handle(invocation)
        }
        page.window?.contentView = bridge.webView
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
        statusItem.stateProvider = { [weak self] in
            guard let self else { return StatusItemController.MenuState() }
            let permissions = Permissions()
            let book = self.latestContext?.book
            let activeConversation = self.store.state.lastActive.flatMap { active in
                self.store.conversation(assetID: active.assetID, conversationID: active.conversationID ?? "")
            }
            return StatusItemController.MenuState(
                bookTitle: book?.title,
                bookProgress: book?.progress,
                conversationTitle: activeConversation?.title,
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
        guard frontendReady, returningFromPermissionSettings else { return }
        returningFromPermissionSettings = false
        reconnectBooks(requestAccessibility: false)
    }

    private func reconnectBooks(requestAccessibility: Bool) {
        connectionRequested = true
        connectionGeneration += 1
        coordinator?.stop()
        coordinator = nil
        latestContext = nil
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
        case "ready":
            frontendReady = true
            NSLog("[BooksBridge] 收到前端 ready 指令，开通状态推送")
            pushState(message: "前端已就绪")
            // 立刻把设置也推一次：下拉选项要在用户打开设置面板之前就绪
            pushSettings()

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

        case "deleteConversation":
            guard let assetID = invocation.payload["assetID"] as? String,
                  let conversationID = invocation.payload["conversationID"] as? String else { return }
            store.deleteConversation(assetID: assetID, conversationID: conversationID)
            pushState(message: "已删除对话")

        case "removeBook":
            guard let assetID = invocation.payload["assetID"] as? String else { return }
            store.removeBook(assetID: assetID)
            pushState(message: "已移出书库")

        case "backToLibrary":
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

        case "cancelAnswer":
            cancelPendingAnswer()
            pushState(message: "已中断")

        case "reprocessBook":
            if connectionRequested, dataAccess.isGranted,
               let active = store.state.lastActive, let id = active.conversationID,
               invocation.payload["scope"] as? String == KnowledgeScope.wholeBook.rawValue,
               store.lockScope(assetID: active.assetID, conversationID: id, requested: .wholeBook) == .wholeBook {
                pushState(message: "本对话范围固定为整本书")
                prepareBook(assetID: active.assetID, force: true)
            }

        case "showPermissions":
            openSettings()

        case "openSettings":
            openSettings()

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
        if book?.conversations.isEmpty ?? false {
            store.createConversation(assetID: assetID)
            book = store.book(assetID: assetID)
        }

        store.setActive(assetID: assetID, conversationID: book?.conversations.first?.id)
        NSLog("[BooksBridge] 进入《\(resolvedTitle)》的 workspace，对话数=\(book?.conversations.count ?? 0)")
        pushState(message: "已进入《\(resolvedTitle)》")
        prepareBook(assetID: assetID, force: false)
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
                draft.maxContextCharacters = min(max(value, 1000), 200_000)
            }
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
        assistant.cancelAnswer()
    }

    // MARK: - 阅读问答

    /// 预处理当前书：把整本书压缩成「书籍说明」，供后续提问使用。
    ///
    /// 耗时且要花 token，因此放在进入 workspace 之后、后台进行；
    /// 未完成时提问会退化为"只用原文片段"，不会阻塞用户。
    private func prepareBook(assetID: String, force: Bool) {
        // 优先用实时上下文里的书目：路径与进度以图书 App 的数据为准
        let resolved: BooksBridgeCore.Book?
        if let context = latestContext, context.book.assetID == assetID {
            resolved = context.book
        } else {
            resolved = (try? booksStore.book(assetID: assetID)) ?? nil
        }
        guard let book = resolved else {
            NSLog("[BooksBridge] 预处理跳过：找不到书目 \(assetID)")
            return
        }
        let cfi = (try? booksStore.readingPosition(assetID: assetID))?.cfi

        answerStream?.cancel()
        answerStream = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.assistant.open(book: book, currentCFI: cfi, forceReprocess: force)
            for await event in stream {
                guard !Task.isCancelled,
                      self.store.state.lastActive?.assetID == assetID else { break }
                self.handleAssistantEvent(event)
            }
        }
    }

    /// 发起提问。
    private func ask(_ payload: [String: Any]) {
        guard let question = (payload["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty,
              let active = store.state.lastActive, let conversationID = active.conversationID else { return }
        guard connectionRequested, dataAccess.isGranted else {
            bridge.push(["chatEvent": ["kind": "error", "text": "请先连接 Apple Books，以读取本书最新进度"]])
            return
        }
        let requested = (payload["scope"] as? String).flatMap(KnowledgeScope.init(rawValue:)) ?? settings.settings.defaultScope
        guard let scope = store.lockScope(assetID: active.assetID, conversationID: conversationID, requested: requested) else { return }
        // 历史在追加本轮问题之前取，避免重复发送；旧格式的未标注范围历史不参与。
        let conversation = store.conversation(assetID: active.assetID, conversationID: conversationID)!
        let history: [ChatMessage] = conversation.messages.dropFirst(conversation.scopeHistoryStartIndex ?? 0).map {
            $0.role == .user ? .user($0.text) : .assistant($0.text)
        }
        store.appendMessage(assetID: active.assetID, conversationID: conversationID,
                            message: Conversation.Message(role: .user, text: question))
        pushState(message: "正在读取本书最新进度")
        cancelPendingAnswer()
        answerStream = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 每次提问走数据库工具读取，不能借用其他书的 latestContext。
                let assetID = active.assetID
                let fresh = try await Task.detached {
                    let source = BooksStore()
                    guard let book = try source.book(assetID: assetID) else { throw ReadingAssistant.AssistantError.notLoaded }
                    let position = try source.readingPosition(assetID: assetID)
                    return (book, position?.cfi)
                }.value
                try Task.checkCancellation()
                let visible: [String]
                if self.booksStore.currentAssetID() == assetID,
                   Permissions().accessibilityStatus().isGranted,
                   let snapshot = try? AccessibilityReader().snapshot() {
                    visible = [String(snapshot.visibleText.joined(separator: "\n").prefix(1200))]
                } else { visible = [] }
                let stream = self.assistant.ask(book: fresh.0, currentCFI: fresh.1,
                    question: question, scope: scope, visibleText: visible, history: history)
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    guard self.store.state.lastActive?.assetID == assetID,
                          self.store.state.lastActive?.conversationID == conversationID else { break }
                    self.handleAssistantEvent(event)
                }
            } catch is CancellationError { return }
            catch {
                guard self.store.state.lastActive?.assetID == active.assetID,
                      self.store.state.lastActive?.conversationID == conversationID else { return }
                self.handleAssistantEvent(.failed("最新阅读进度读取失败：\(error)"))
            }
        }
    }

    /// 把助手事件转成前端可消费的推送。
    private func handleAssistantEvent(_ event: ReadingAssistant.Event) {
        switch event {
        case .preparationChanged(let state):
            bridge.push([
                "assistant": ["preparation": state.label, "ready": isPreparationReady(state)],
            ])
            statusItem.refreshTooltip()

        case .reasoningDelta(let delta):
            bridge.push(["chatEvent": ["kind": "reasoning", "text": delta]])

        case .answerDelta(let delta):
            bridge.push(["chatEvent": ["kind": "delta", "text": delta]])

        case .finished(let answer, let scopeDescription, let usage):
            // 落盘助手回答
            if let active = store.state.lastActive,
               let conversationID = active.conversationID {
                store.appendMessage(
                    assetID: active.assetID,
                    conversationID: conversationID,
                    message: Conversation.Message(role: .assistant, text: answer)
                )
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
            bridge.push(["chatEvent": ["kind": "error", "text": message]])
            pushState(message: "问答失败")
        }
    }

    private func isPreparationReady(_ state: ReadingAssistant.PreparationState) -> Bool {
        if case .ready = state { return true }
        return false
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
    }

    /// 把"检测不到"归类，让前端能给出准确的提示而不是笼统的"未在阅读"。
    private static func classifyDetectionIssue(
        issue: String?,
        permissions: Permissions,
        booksRunning: Bool
    ) -> String {

        if !booksRunning { return "booksNotRunning" }
        if let issue, issue.contains("kLastCurrentBookKey") { return "noBookOpen" }
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
                self.detectionIssue = message
                self.pushState(message: "采集受阻")
            }
        }
        coordinator.onUpdate = { [weak self] context in
            // 回调在 coordinator 的队列上，切回主线程再碰 AppKit / WebView
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.latestContext = context
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

        var body: [String: Any] = ["message": message, "facts": facts]

        // --- detected：实时检测，不落盘 ---
        if let context = latestContext {
            let book = context.book
            facts["检测到的书"] = book.title
            facts["进度"] = String(format: "%.1f%%", book.progress * 100)
            facts["位置"] = context.position?.cfi ?? context.position?.raw ?? "(无)"
            facts["屏幕可见段落"] = String(context.visibleText.count)

            var detected: [String: Any] = [
                "assetID": book.assetID,
                "title": book.title,
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
                "title": book.title,
                "author": book.author,
                "conversations": book.conversations.map { conversation -> [String: Any] in
                    [
                        "id": conversation.id,
                        "title": conversation.title,
                        "messageCount": conversation.messages.count,
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
                    payload["messages"] = conversation.messages.map { message in
                        [
                            "role": message.role.rawValue,
                            "text": message.text,
                            "createdAt": ISO8601DateFormatter().string(from: message.createdAt),
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
