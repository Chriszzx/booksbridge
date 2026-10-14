import XCTest
import WebKit

@MainActor
final class WebRenderingTests: XCTestCase {
    func testMarkdownRenderingAndUnsafeContent() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BooksBridgeApp/WebUI")
        let view = WKWebView()
        for file in ["vendor/marked.js", "vendor/purify.js", "markdown.js"] {
            _ = try await view.evaluateJavaScript(String(contentsOf: root.appendingPathComponent(file), encoding: .utf8))
        }
        let markdown = "# 标题\n\n**粗体**\n\n- 第一项\n- 第二项\n\n> 引用\n\n```swift\nlet a = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n[坏链接](javascript:alert(1))\n<img src=x onerror=alert(1)><script>alert(1)</script>"
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let encoded = String(decoding: data, as: UTF8.self)
        let result = try await view.evaluateJavaScript("""
        (() => {
          const node = document.createElement('div');
          renderMarkdown(node, \(encoded)[0]);
          return {heading:!!node.querySelector('h1'), bold:!!node.querySelector('strong'),
            list:node.querySelectorAll('li').length, table:!!node.querySelector('table'),
            code:!!node.querySelector('pre code'), unsafe:!!node.querySelector('script,img,[onclick],[onerror],a[href^="javascript:"]')};
        })()
        """) as! [String: Any]
        XCTAssertEqual(result["heading"] as? Bool, true)
        XCTAssertEqual(result["bold"] as? Bool, true)
        XCTAssertEqual(result["list"] as? Int, 2)
        XCTAssertEqual(result["table"] as? Bool, true)
        XCTAssertEqual(result["code"] as? Bool, true)
        XCTAssertEqual(result["unsafe"] as? Bool, false)
    }
}

@MainActor
private final class NavigationReady: NSObject, WKNavigationDelegate {
    let ready: XCTestExpectation
    init(_ ready: XCTestExpectation) { self.ready = ready }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready.fulfill() }
}

@MainActor
private final class UIInvocations: NSObject, WKScriptMessageHandler {
    var calls: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { calls.append(body) }
    }
}

extension WebRenderingTests {
    func testChatControlsConfirmationAndDetectionClearing() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BooksBridgeApp/WebUI")
        let config = WKWebViewConfiguration()
        let calls = UIInvocations()
        config.userContentController.add(calls, name: "booksbridge")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        let ready = expectation(description: "frontend ready")
        let navigation = NavigationReady(ready)
        view.navigationDelegate = navigation
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        await fulfillment(of: [ready], timeout: 10)
        let result = try await view.evaluateJavaScript("""
        (() => {
          booksbridge.onState({settings:{model:'test-model',baseURL:'https://example.test/v1',isConfigured:true,defaultScope:'upToProgress',temperature:0.3,maxContextCharacters:12000},
            knowledgeScopes:[{id:'upToProgress',label:'读到这为止'},{id:'currentChapter',label:'整章'},{id:'wholeBook',label:'整书'}],
            library:[{assetID:'A',title:'测试书',conversations:[{id:'C',title:'对话',messageCount:1}]}],
            active:{assetID:'A',conversationID:'C',messages:[{role:'assistant',text:'## Markdown标题'}]},
            detected:{assetID:'A',title:'当前书',progress:0.2},detectionState:'ok'});
          document.getElementById('prep-retry').click();
          const confirmation = document.getElementById('prepare-confirm').open;
          document.getElementById('prepare-no').click();
          booksbridge.onState({detected:null,detectionState:'booksNotRunning'});
          const clear = !document.getElementById('rc-title').textContent.includes('当前书');
          booksbridge.onState({active:{assetID:'A',conversationID:'C',scope:'upToProgress',messages:[]}});
          return {confirmation, clear, locked:document.getElementById('scope-picker').disabled,
            model:document.getElementById('composer-model').textContent,
            markdown:!!document.querySelector('.msg-body h2'),options:document.getElementById('scope-picker').options.length};
        })()
        """) as! [String: Any]
        XCTAssertEqual(result["confirmation"] as? Bool, true)
        XCTAssertEqual(result["clear"] as? Bool, true)
        XCTAssertEqual(result["locked"] as? Bool, true)
        XCTAssertEqual(result["model"] as? String, "test-model")
        XCTAssertEqual(result["markdown"] as? Bool, true)
        XCTAssertEqual(result["options"] as? Int, 3)
        XCTAssertFalse(calls.calls.contains { $0["type"] as? String == "reprocessBook" }, "取消确认不应上传全书")
        _ = try await view.evaluateJavaScript("document.getElementById('api-test').click(); undefined")
        try await Task.sleep(for: .milliseconds(100))
        let call = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "testAPI" })
        XCTAssertEqual((call["payload"] as? [String: Any])?["model"] as? String, "test-model")
        let live = try await view.evaluateJavaScript("""
        (() => {
          const input = document.getElementById('input');
          input.value = '开头到现在讲了什么'; input.dispatchEvent(new Event('input'));
          document.getElementById('send-btn').click();
          const immediate = document.querySelector('.msg.assistant:last-child .msg-body')?.textContent.includes('正在思考');
          booksbridge.onState({chatEvent:{kind:'status',text:'正在思考 · 已读取完整原文 20000 字'}});
          const status = document.querySelector('.msg.assistant:last-child').textContent.includes('20000');
          booksbridge.onState({chatEvent:{kind:'reasoning',text:'检查材料'}});
          const folded = !document.querySelector('.msg.assistant:last-child details').open;
          document.getElementById('cancel-btn').click();
          const stopped = document.querySelector('.msg.assistant:last-child .msg-body').textContent === '已停止';
          booksbridge.onState({settings:{model:'test-model',baseURL:'https://example.test/v1',isConfigured:true,defaultScope:'upToProgress',temperature:0.3,maxContextCharacters:12000,autoExpandReasoning:true}});
          input.value = '再试一次'; input.dispatchEvent(new Event('input'));
          document.getElementById('send-btn').click();
          booksbridge.onState({chatEvent:{kind:'reasoning',text:'展开的摘要'}});
          const expanded = document.querySelector('.msg.assistant:last-child details').open;
          booksbridge.onState({chatEvent:{kind:'finished',text:'回答完成'}});
          const finished = document.querySelector('.msg.assistant:last-child .msg-body').textContent.trim() === '回答完成';
          return {immediate,status,folded,stopped,expanded,finished};
        })()
        """) as! [String: Any]
        for key in ["immediate", "status", "folded", "stopped", "expanded", "finished"] {
            XCTAssertEqual(live[key] as? Bool, true, key)
        }
        config.userContentController.removeScriptMessageHandler(forName: "booksbridge")
    }
}
