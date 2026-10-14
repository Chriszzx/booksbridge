import AppKit
import BooksBridgeCore
import WebKit
import Foundation

/// Swift 宿主与前端之间的桥。
///
/// 通路有两条：
/// - **Swift → Web**：`push(_:)` 调用页面上的 `window.booksbridge.onState(payload)`
/// - **Web → Swift**：页面通过 `window.webkit.messageHandlers.booksbridge.postMessage(...)`
///   发指令，这里解析后回调给上层
///
/// 只做消息搬运，不掺业务逻辑，方便单测与替换前端。
@MainActor
public final class WebBridge: NSObject {
    /// 前端发来的一条指令。
    public struct Invocation {
        public let type: String
        public let payload: [String: Any]
    }

    /// 常量字符串，跨隔离访问安全。
    public nonisolated static let handlerName = "booksbridge"

    public let webView: WKWebView
    /// 收到前端指令时回调（在主线程）。
    public var onInvocation: ((Invocation) -> Void)?

    private let webRootOverride: URL?

    public init(webRootOverride: URL? = nil) {
        self.webRootOverride = webRootOverride

        let config = WKWebViewConfiguration()
        // 前端不需要持久化，也不要跟其它实例共享状态
        config.websiteDataStore = .nonPersistent()
        // 允许在本地文件里用 JS（默认已允许），并禁用不必要的媒体自动播放
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.isElementFullscreenEnabled = false

        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        config.userContentController.add(self, name: Self.handlerName)
        webView.navigationDelegate = self

        // 前端是本地 UI，禁用右键菜单与拖拽，避免出现"网页感"
        webView.configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        webView.allowsMagnification = false
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
    }

    // MARK: - 加载

    /// 加载前端资源。
    ///
    /// 优先用 `BOOKSBRIDGE_WEB_ROOT` 环境变量指向源码目录——
    /// 这样调试期改 HTML/CSS/JS 只要刷新页面，不必重编译。
    @discardableResult
    public func load() -> Bool {
        if let override = webRootOverride ?? Self.webRootFromEnvironment() {
            let index = override.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                webView.loadFileURL(index, allowingReadAccessTo: override)
                return true
            }
        }
        if let bundled = Self.bundledIndexURL() {
            webView.loadFileURL(bundled, allowingReadAccessTo: bundled.deletingLastPathComponent())
            return true
        }
        return false
    }

    private static func webRootFromEnvironment() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["BOOKSBRIDGE_WEB_ROOT"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// SwiftPM 会把 `WebUI` 目录原样拷进资源 bundle。
    private static func bundledIndexURL() -> URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebUI")
    }

    /// 供自检：资源是否找得到。
    public static var resourceDiagnostics: String {
        let bundled = bundledIndexURL()
        let env = ProcessInfo.processInfo.environment["BOOKSBRIDGE_WEB_ROOT"] ?? "(未设置)"
        return "资源 bundle: \(Bundle.module.bundlePath)\nindex.html: \(bundled?.path ?? "未找到")\nBOOKSBRIDGE_WEB_ROOT: \(env)"
    }

    // MARK: - 推送

    /// 把一个可 JSON 序列化的字典推给前端。
    public func push(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[BooksBridge] push 的 payload 不是合法 JSON，已丢弃")
            return
        }
        let script = "window.booksbridge && window.booksbridge.onState(\(json));"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                NSLog("[BooksBridge] push 失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Web → Swift

extension WebBridge: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let payload = (body["payload"] as? [String: Any]) ?? [:]
        onInvocation?(Invocation(type: type, payload: payload))
    }
}

// MARK: - 导航

extension WebBridge: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // 本地 UI 不应跳外链；万一有，交给系统浏览器
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }
}
