import XCTest
import WebKit
@testable import BooksBridgeApp

@MainActor
final class WebRenderingTests: XCTestCase {
    func testPositionTimelineHasNoAssistantBubbleAndNowNeverStartsChat() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          const history = [{id:'p1',role:'assistant',text:'第一章 · 5.0% · 已刷新 · 12:00:00',isPositionCard:true},
            {id:'cmd',role:'user',text:'/now',isPositionCard:true},
            {id:'p2',role:'assistant',text:'第一章 · 5.0% · 已刷新 · 12:01:00',isPositionCard:true},
            {id:'q1',role:'user',text:'问题'},{id:'a1',role:'assistant',text:'回答'}];
          booksbridge.onState({active:{assetID:'A',conversationID:'timeline',messages:history}});
          const legacy = document.querySelectorAll('.position-marker').length === 1 && document.querySelectorAll('.msg').length === 2
            && !document.querySelector('.position-marker').textContent.includes('12:01') && !document.querySelector('.position-marker button');
          $('input').value='/now'; $('input').dispatchEvent(new Event('input')); $('send-btn').click();
          const local = document.querySelectorAll('.msg').length === 2 && !document.querySelector('.messages').textContent.includes('正在思考');
          booksbridge.onState({positionRefreshFinished:true});
          booksbridge.onState({active:{assetID:'A',conversationID:'timeline',messages:[...history,{id:'p3',role:'assistant',text:'第二章 · 20.0%',isPositionCard:true}]}});
          const restored = document.querySelector('.messages').lastElementChild.className === 'position-marker'
            && document.querySelector('.messages').lastElementChild.textContent === '第二章 · 20.0%';
          return {legacy,local,restored};
        })()
        """) as! [String: Bool]
        for (key,value) in result { XCTAssertTrue(value,key) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(calls.calls.filter { $0["type"] as? String == "refreshPosition" }.count, 1)
        XCTAssertFalse(calls.calls.contains { ["ask", "testAPI", "reprocessBook"].contains($0["type"] as? String ?? "") })
    }

    func testStructurePreviewConfirmationAndNavigationNeverAutomaticallySends() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let checks = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          const structure = {assetID:'A',conversationID:'first',version:'v1',proposalID:'p1',status:'章节建议待确认',
            issues:'缺少目录',running:false,applied:false,structureChanged:false,scopeConfirmed:false,oldCount:1,newCount:3,uncertain:1,
            rows:['1. 第一卷 · 卷引言','2. 范围外标题 · 章节']};
          booksbridge.onState({active:{assetID:'A',conversationID:'first',scope:'currentChapter',messages:[]},chapterStructure:structure});
          document.querySelector('[data-action=summary]').click(); $('structure-panel').open = true;
          const preview = $('structure-preview').textContent.includes('1 个区段 → 建议 3') && $('structure-scope').hidden;
          $('structure-analyze').click();
          const disclosure = $('structure-confirm').open && $('structure-confirm-text').textContent.includes('未读内容');
          $('structure-no').click(); $('structure-apply').click();
          const invalidation = $('structure-confirm-text').textContent.includes('其余章节及全书摘要');
          booksbridge.onState({active:{assetID:'A',conversationID:'second',scope:'currentChapter',messages:[]},chapterStructure:{...structure,conversationID:'second',structureChanged:true}});
          const reset = !$('structure-confirm').open && !$('structure-scope').hidden;
          document.querySelector('[data-action=summary]').click(); $('structure-scope').click(); $('structure-yes').click();
          return {preview,disclosure,invalidation,reset};
        })()
        """) as! [String: Bool]
        for (key,value) in checks { XCTAssertTrue(value,key) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(calls.calls.contains { ["analyzeStructure", "applyStructure", "ask", "testAPI", "reprocessBook"].contains($0["type"] as? String ?? "") })
        let confirmed = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "confirmStructureScope" }?["payload"] as? [String: Any])
        XCTAssertEqual(confirmed["conversationID"] as? String, "second")
        XCTAssertEqual(confirmed["version"] as? String, "v1")
        XCTAssertEqual(confirmed["confirmed"] as? Bool, true)
    }

    func testSharedSummaryStatisticsSurviveConversationSwitchAndClearRequiresConfirmation() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let checks = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          const shared = {assistant:{preparation:'正在生成',ready:false,running:true,hasSharedSummary:true},
            scopeSummary:'第一章安全摘要',summaryMetadata:'全书摘要尚未生成',
            bookStatistics:{characters:12000,estimatedTokens:36000,documents:5,headings:6,completed:1,wholeComplete:false,
              chapters:[{number:1,title:'第一章',characters:4000,estimatedTokens:12000,complete:true,allowed:true},
                {number:2,title:'第 2 章（范围外）',characters:4000,estimatedTokens:12000,complete:false,allowed:false}]}};
          booksbridge.onState({...shared,active:{assetID:'A',conversationID:'first',scope:'upToProgress',messages:[]}});
          const before = $('summary-status').textContent;
          booksbridge.onState({...shared,active:{assetID:'A',conversationID:'second',scope:'upToProgress',messages:[]}});
          document.querySelector('[data-action=summary]').click();
          const same = $('summary-status').textContent === before && $('prep-text').textContent.includes('1 / 2');
          const statistics = $('book-statistics').textContent.includes('12,000') && $('chapter-statistics-list').children.length === 2;
          const isolated = $('summary-document').getClientRects().length > 0 && !document.querySelector('.messages #scope-summary') && !$('scope-summary-text').textContent.includes('未读秘密');
          $('summary-back').click();
          booksbridge.onState({assistant:{preparation:'章节摘要 3/3 · 全书摘要已完成',ready:false,hasSharedSummary:true},scopeSummary:''});
          document.querySelector('[data-action=summary]').click(); $('summary-more').click(); [...document.querySelectorAll('#sidebar-menu button')].find(b => b.textContent === '清除摘要').click();
          const confirmation = $('prepare-confirm').open && $('prepare-destination').textContent.includes('所有对话');
          $('prepare-no').click();
          return {same,statistics,isolated,confirmation,hidden:$('scope-summary').hidden};
        })()
        """) as! [String: Bool]
        for value in checks.values { XCTAssertTrue(value) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(calls.calls.contains { ["clearKnowledge", "reprocessBook", "ask", "testAPI"].contains($0["type"] as? String ?? "") })
        _ = try await view.evaluateJavaScript("document.getElementById('summary-more').click(); [...document.querySelectorAll('#sidebar-menu button')].find(b => b.textContent === '清除摘要').click(); document.getElementById('prepare-yes').click(); undefined;")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual((calls.calls.last { $0["type"] as? String == "clearKnowledge" }?["payload"] as? [String: Any])?["confirmed"] as? Bool, true)
    }

    func testRenameAndDeletionDialogsTargetIDsAndRequireConfirmation() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        _ = try await view.evaluateJavaScript("""
        window.managementBooks = [{assetID:'A',title:'同名书',originalTitle:'原书名',conversations:[{id:'C',title:'当前对话'},{id:'ARCH',title:'归档对话',archived:true}]},{assetID:'B',title:'同名书',conversations:[]}];
        booksbridge.onState({library:managementBooks});
        window.originalMessageNode = document.querySelector('.msg'); document.getElementById('input').value = '保留草稿';
        window.bookMenu = label => { document.querySelector('[data-asset-id="A"] .book-row .row-action:last-child').click(); [...document.querySelectorAll('#sidebar-menu button')].find(el => el.textContent === label).click(); };
        bookMenu('重命名'); document.getElementById('management-name').value = '自定义书名'; document.getElementById('management-form').requestSubmit(); undefined;
        """)
        func complete(_ type: String, assetID: String = "A", conversationID: String? = nil) async throws {
            try await Task.sleep(for:.milliseconds(50))
            let payload = try XCTUnwrap(calls.calls.last { $0["type"] as? String == type }?["payload"] as? [String:Any])
            XCTAssertEqual(payload["assetID"] as? String,assetID)
            if let conversationID { XCTAssertEqual(payload["conversationID"] as? String,conversationID) }
            let id = try XCTUnwrap(payload["requestID"] as? String)
            let data = try JSONSerialization.data(withJSONObject:["managementResult":["requestID":id,"success":true,"message":"已完成"]])
            _ = try await view.evaluateJavaScript("booksbridge.onState(\(String(decoding:data,as:UTF8.self))); undefined;")
        }
        try await Task.sleep(for:.milliseconds(30))
        let renameRequest = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "renameBook" }?["payload"] as? [String:Any])
        let failureData = try JSONSerialization.data(withJSONObject:["managementResult":["requestID":renameRequest["requestID"] as? String ?? "","success":false,"message":"模拟保存失败"]])
        _ = try await view.evaluateJavaScript("booksbridge.onState(\(String(decoding:failureData,as:UTF8.self))); undefined;")
        let retryable = try await view.evaluateJavaScript("document.getElementById('management-dialog').open && !document.getElementById('management-error').hidden && !document.getElementById('management-confirm').disabled") as? Bool
        XCTAssertEqual(retryable,true)
        _ = try await view.evaluateJavaScript("document.getElementById('management-form').requestSubmit(); undefined;")
        try await complete("renameBook")
        _ = try await view.evaluateJavaScript("""
        managementBooks[0].title = '自定义书名'; booksbridge.onState({library:managementBooks});
        document.querySelector('.conversation-row .row-action').click(); [...document.querySelectorAll('#sidebar-menu button')].find(el => el.textContent === '重命名').click();
        document.getElementById('management-name').value = '我的笔记'; document.getElementById('management-form').requestSubmit(); undefined;
        """)
        try await complete("renameConversation",conversationID:"C")
        let preserved = try await view.evaluateJavaScript("document.querySelector('.msg') === originalMessageNode && document.getElementById('input').value === '保留草稿'") as? Bool
        XCTAssertEqual(preserved,true)
        _ = try await view.evaluateJavaScript("""
        document.getElementById('settings-btn').click(); document.getElementById('archives-btn').click();
        document.querySelector('[data-archive-action="rename"]').click(); document.getElementById('management-name').value = '归档笔记'; document.getElementById('management-form').requestSubmit(); undefined;
        """)
        try await complete("renameConversation",conversationID:"ARCH")
        _ = try await view.evaluateJavaScript("document.querySelector('[data-archive-action=delete]').click(); document.getElementById('management-cancel').click(); undefined;")
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(calls.calls.contains { $0["type"] as? String == "deleteConversation" })
        _ = try await view.evaluateJavaScript("document.querySelector('[data-archive-action=delete]').click(); document.getElementById('management-form').requestSubmit(); undefined;")
        try await complete("deleteConversation",conversationID:"ARCH")
        let deletion = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "deleteConversation" }?["payload"] as? [String:Any])
        XCTAssertEqual(deletion["confirmed"] as? Bool,true)
        let warning = try await view.evaluateJavaScript("""
        (() => { bookMenu('删除书籍'); const text = document.getElementById('management-description').textContent;
          const safeFocus = document.activeElement === document.getElementById('management-cancel');
          document.getElementById('management-cancel').click(); return safeFocus && text.includes('包括已归档') && text.includes('Apple Books 中的原书文件保留'); })()
        """) as? Bool
        XCTAssertEqual(warning,true)
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(calls.calls.contains { $0["type"] as? String == "removeBook" })
        _ = try await view.evaluateJavaScript("bookMenu('删除书籍'); document.getElementById('management-form').requestSubmit(); undefined;")
        try await complete("removeBook")
        let bookDeletion = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "removeBook" }?["payload"] as? [String:Any])
        XCTAssertEqual(bookDeletion["confirmed"] as? Bool,true)
        XCTAssertFalse(calls.calls.contains { ["ask","retryMessage","testAPI","reprocessBook"].contains($0["type"] as? String ?? "") })
    }

    func testFileAssociationAndAmbiguousWindowConfirmationStayLocal() async throws {
        let (view,calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        _ = try await view.evaluateJavaScript("""
        booksbridge.onState({sourceImport:{requestID:'duplicate',title:'另一名称',matches:[{assetID:'A',title:'原记录'}]}});
        document.getElementById('book-source-confirm').click();
        booksbridge.onState({sourceImport:{requestID:'separate',title:'另一名称',matches:[{assetID:'A',title:'原记录'}]}});
        document.getElementById('book-source-separate').click();
        booksbridge.onState({detected:null,detectionState:'ambiguousBook'});
        document.getElementById('identify-book-btn').click();
        booksbridge.onState({bookIdentification:{requestID:'identify',windowTitle:'同名书',books:[{assetID:'A',title:'同名书',path:'/books/a.epub'},{assetID:'B',title:'同名书',path:'/books/b.epub'}]}});
        document.getElementById('book-source-select').value = 'B'; document.getElementById('book-source-select').dispatchEvent(new Event('change'));
        window.correctSourcePath = document.getElementById('book-source-path').textContent === '/books/b.epub';
        document.getElementById('book-source-confirm').click(); undefined;
        """)
        try await Task.sleep(for:.milliseconds(60))
        let resolved = calls.calls.filter { $0["type"] as? String == "resolveSourceImport" }.compactMap { $0["payload"] as? [String:Any] }
        XCTAssertEqual(resolved.first?["assetID"] as? String,"A")
        XCTAssertEqual(resolved.last?["separate"] as? Bool,true)
        let identified = try XCTUnwrap(calls.calls.first { $0["type"] as? String == "confirmActiveBook" }?["payload"] as? [String:Any])
        XCTAssertEqual(identified["assetID"] as? String,"B")
        let correctPath = try await view.evaluateJavaScript("correctSourcePath") as? Bool
        XCTAssertEqual(correctPath,true)
        XCTAssertFalse(calls.calls.contains { ["ask","retryMessage","testAPI","reprocessBook"].contains($0["type"] as? String ?? "") })
    }

    func testSidebarResizeCommitCancelAndViewportClamping() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const handle = document.getElementById('sidebar-resizer');
          const width = () => document.getElementById('sidebar').getBoundingClientRect().width;
          const pointer = (type,x) => (type === 'pointerdown' ? handle : window).dispatchEvent(new PointerEvent(type,{pointerId:7,clientX:x,button:0,buttons:type === 'pointerup' ? 0 : 1,bubbles:true}));
          booksbridge.onState({sidebarLayout:{width:300}});
          const message = document.querySelector('.msg');
          document.getElementById('input').value = '调整宽度时的草稿';
          pointer('pointerdown',300); pointer('pointermove',370);
          booksbridge.onState({sidebarLayout:{width:300},readingPosition:'第一章 · 21%'});
          const live = width() === 370;
          pointer('pointerup',370);
          pointer('pointerdown',370); pointer('pointermove',430);
          window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',cancelable:true}));
          const cancelled = width() === 370 && !document.getElementById('app').classList.contains('sidebar-resizing');
          pointer('pointerdown',370); pointer('pointermove',450); pointer('pointercancel',450);
          const pointerCancelled = width() === 370;
          pointer('pointerdown',370); pointer('pointermove',10000); pointer('pointerup',10000);
          return {live,cancelled,pointerCancelled,maximum:width() === 480,
            chat:document.querySelector('.msg') === message,
            draft:document.getElementById('input').value === '调整宽度时的草稿'};
        })()
        """) as! [String: Any]
        for (key, value) in result { XCTAssertEqual(value as? Bool, true, key) }
        view.frame.size = CGSize(width:720,height:460)
        try await Task.sleep(for: .milliseconds(60))
        let narrow = try await view.evaluateJavaScript("""
        (() => {
          const main = document.getElementById('main').getBoundingClientRect();
          const composer = document.querySelector('.composer').getBoundingClientRect();
          return document.getElementById('sidebar').getBoundingClientRect().width === 280 && main.width >= 440 && composer.right <= innerWidth;
        })()
        """) as? Bool
        XCTAssertEqual(narrow, true)
        view.frame.size = CGSize(width:1000,height:700)
        try await Task.sleep(for: .milliseconds(60))
        let restored = try await view.evaluateJavaScript("document.getElementById('sidebar').getBoundingClientRect().width") as? Double
        XCTAssertEqual(restored, 480)
        let widths = calls.calls.filter { $0["type"] as? String == "setSidebarWidth" }.compactMap { ($0["payload"] as? [String: Any])?["width"] as? Double }
        XCTAssertEqual(widths, [370,480])
        let controls = try await view.evaluateJavaScript("""
        (() => {
          const handle = document.getElementById('sidebar-resizer');
          document.getElementById('sidebar-toggle').click();
          const hidden = handle.getClientRects().length === 0;
          document.getElementById('sidebar-toggle').click();
          const preserved = document.getElementById('sidebar').getBoundingClientRect().width === 480;
          handle.dispatchEvent(new KeyboardEvent('keydown',{key:'Home',cancelable:true}));
          const minimum = handle.getAttribute('aria-valuenow') === '210';
          handle.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',cancelable:true}));
          const keyboard = handle.getAttribute('aria-valuenow') === '220';
          handle.dispatchEvent(new MouseEvent('dblclick'));
          return hidden && preserved && minimum && keyboard && handle.getAttribute('aria-valuenow') === '248';
        })()
        """) as? Bool
        XCTAssertEqual(controls, true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(calls.calls.contains { ["ask", "retryMessage", "testAPI", "reprocessBook", "returnToReader"].contains($0["type"] as? String ?? "") })
    }

    func testTitlebarDragRegionsFollowControlsAndModalState() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        try await Task.sleep(for: .milliseconds(80))
        func latestRegions() throws -> [String: Any] {
            try XCTUnwrap(calls.calls.last { $0["type"] as? String == "setTitlebarHitRegions" }?["payload"] as? [String: Any])
        }
        let initial = try latestRegions()
        XCTAssertEqual((initial["draggable"] as? [[String: Double]])?.count, 2)
        let controls = try XCTUnwrap(initial["interactive"] as? [[String: Double]])
        XCTAssertEqual(controls.count, 3)
        for rect in controls {
            XCTAssertGreaterThanOrEqual(rect["y"] ?? -1, 0)
            XCTAssertLessThanOrEqual((rect["y"] ?? 0) + (rect["height"] ?? 0), 40)
        }
        _ = try await view.evaluateJavaScript("document.querySelector('[data-action=summary]').click(); undefined;")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual((try latestRegions()["draggable"] as? [[String: Double]])?.count, 2)
        _ = try await view.evaluateJavaScript("document.getElementById('summary-back').click(); document.getElementById('settings-btn').click(); undefined;")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual((try latestRegions()["draggable"] as? [[String: Double]])?.count, 2)
        XCTAssertEqual((try latestRegions()["interactive"] as? [[String: Double]])?.count, 2)
        XCTAssertFalse(calls.calls.contains { ["ask", "retryMessage", "testAPI", "reprocessBook"].contains($0["type"] as? String ?? "") })
    }

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
    var onCall: (([String: Any]) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { calls.append(body); onCall?(body) }
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
          const markdown = !!document.querySelector('.msg-body h2');
          booksbridge.onState({active:{assetID:'A',conversationID:'C',scope:'upToProgress',messages:[]}});
          return {confirmation, clear, locked:document.getElementById('scope-picker').disabled,
            emptyHidden:getComputedStyle(document.getElementById('thread-empty')).display === 'none',
            model:document.getElementById('composer-model').textContent,
            markdown,options:document.getElementById('scope-picker').options.length};
        })()
        """) as! [String: Any]
        XCTAssertEqual(result["confirmation"] as? Bool, false)
        XCTAssertEqual(result["clear"] as? Bool, true)
        XCTAssertEqual(result["locked"] as? Bool, true)
        XCTAssertEqual(result["emptyHidden"] as? Bool, true)
        XCTAssertEqual(result["model"] as? String, "选择模型")
        XCTAssertEqual(result["markdown"] as? Bool, true)
        XCTAssertEqual(result["options"] as? Int, 3)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(calls.calls.contains { $0["type"] as? String == "reprocessBook" }, "Explicit generation starts without a second dialog; bridge is mocked")
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
        let core = try await view.evaluateJavaScript("""
        (() => {
          booksbridge.onState({readingPosition:'真实章节 · 20% · 沿用上次位置',scopeSummary:'**范围内摘要**',selectionCandidate:{token:'selection-token',text:'已读原文',exact:false}});
          const input = document.getElementById('input');
          input.value = '解释这句话'; input.dispatchEvent(new Event('input'));
          const blocked = document.getElementById('send-btn').disabled;
          const paragraph = document.getElementById('selection-kind').textContent.includes('整段');
          const checkbox = document.getElementById('selection-confirmed'); checkbox.checked = true; checkbox.dispatchEvent(new Event('change'));
          document.getElementById('send-btn').click();
          booksbridge.onState({chatEvent:{kind:'finished',text:'引用解读完成'},scopeSummary:''});
          const cleared = document.getElementById('selection-preview').hidden;
          const hiddenSummary = document.getElementById('scope-summary').hidden;
          booksbridge.onState({settings:{isConfigured:false}});
          input.value = '/now'; input.dispatchEvent(new Event('input'));
          const commandEnabled = !document.getElementById('send-btn').disabled && !input.disabled;
          document.getElementById('send-btn').click();
          booksbridge.onState({positionRefreshFinished:true,active:{assetID:'A',conversationID:'C',messages:[{id:'pos',role:'assistant',isPositionCard:true,text:'真实章节 · 20% · 沿用上次位置'}]}});
          return {blocked,paragraph,cleared,hiddenSummary,commandEnabled,position:document.querySelector('.position-marker').textContent};
        })()
        """) as! [String: Any]
        for key in ["blocked", "paragraph", "cleared", "hiddenSummary", "commandEnabled"] { XCTAssertEqual(core[key] as? Bool, true, key) }
        XCTAssertTrue((core["position"] as? String)?.contains("沿用上次位置") == true)
        try await Task.sleep(for: .milliseconds(100))
        let quoteRequest = calls.calls.compactMap { $0["payload"] as? [String: Any] }.first { $0["selectionToken"] as? String == "selection-token" }
        XCTAssertEqual(quoteRequest?["selectionConfirmed"] as? Bool, true)
        config.userContentController.removeScriptMessageHandler(forName: "booksbridge")
    }
}

extension WebRenderingTests {
    func testSidebarAndBookFoldingPreservesChatAndRestoresLayout() async throws {
        let suite = "BooksBridge.FoldingUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = SidebarLayoutStore(defaults: defaults)
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        calls.onCall = { call in
            let payload = call["payload"] as? [String: Any] ?? [:]
            if call["type"] as? String == "setSidebarCollapsed", let collapsed = payload["collapsed"] as? Bool {
                layout.setCollapsed(collapsed)
            }
            if call["type"] as? String == "setBookCollapsed", let id = payload["assetID"] as? String, let collapsed = payload["collapsed"] as? Bool {
                layout.setBookCollapsed(assetID: id, collapsed: collapsed)
            }
        }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const group = id => [...document.querySelectorAll('.book-group')].find(el => el.dataset.assetId === id);
          const message = document.querySelector('.msg');
          document.getElementById('input').value = '尚未发送的草稿';
          group('A').querySelector('.book-disclosure').click();
          const folded = group('A').querySelector('.conv-list').hidden && group('A').querySelector('.book-disclosure').getAttribute('aria-expanded') === 'false';
          const independent = !group('B').querySelector('.conv-list').hidden;
          booksbridge.onState({library:fixtureBooks,readingPosition:'第一章 · 21%'});
          const survivesRefresh = group('A').querySelector('.conv-list').hidden;
          document.getElementById('sidebar-toggle').click();
          return {folded,independent,survivesRefresh,
            chat:message === document.querySelector('.msg') && document.querySelector('.msg').textContent.includes('已有回答'),
            draft:document.getElementById('input').value === '尚未发送的草稿',
            collapsed:document.getElementById('sidebar').inert && document.getElementById('sidebar-toggle').getAttribute('aria-expanded') === 'false'};
        })()
        """) as! [String: Any]
        for (key, value) in result { XCTAssertEqual(value as? Bool, true, key) }
        for size in [CGSize(width:720,height:460), CGSize(width:1440,height:900)] {
            view.frame.size = size
            try await Task.sleep(for: .milliseconds(50))
            let fits = try await view.evaluateJavaScript("""
            (() => {
              const toggle = document.getElementById('sidebar-toggle').getBoundingClientRect();
              const main = document.getElementById('main').getBoundingClientRect();
              const composer = document.querySelector('.composer').getBoundingClientRect();
              return main.left === 0 && toggle.left >= 80 && toggle.right < innerWidth && composer.left >= 0 && composer.right <= innerWidth;
            })()
            """) as? Bool
            XCTAssertEqual(fits, true)
        }
        XCTAssertTrue(layout.isCollapsed)
        XCTAssertEqual(layout.collapsedBooks, ["A"])
        let (restored, restoredCalls) = try await workspaceFixture()
        defer { restored.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let data = try JSONSerialization.data(withJSONObject: ["sidebarLayout": SidebarLayoutStore(defaults: defaults).payload])
        _ = try await restored.evaluateJavaScript("booksbridge.onState(\(String(decoding:data,as:UTF8.self))); undefined;")
        let restoredState = try await restored.evaluateJavaScript("""
        (() => {
          const folded = document.querySelector('.conv-list').hidden;
          const collapsed = document.getElementById('app').classList.contains('sidebar-collapsed');
          document.getElementById('sidebar-toggle').click();
          const reopened = !document.getElementById('sidebar').inert && document.querySelector('.conv-list').hidden;
          document.querySelector('.book-disclosure').click();
          const expanded = !document.querySelector('.conv-list').hidden;
          document.querySelector('.book-disclosure').click();
          document.querySelector('.book-row .row-action').click();
          return folded && collapsed && reopened && expanded && !document.querySelector('.conv-list').hidden;
        })()
        """) as? Bool
        XCTAssertEqual(restoredState, true)
        try await Task.sleep(for: .milliseconds(50))
        for log in [calls.calls, restoredCalls.calls] {
            XCTAssertFalse(log.contains { ["ask", "retryMessage", "testAPI", "reprocessBook", "archiveConversation"].contains($0["type"] as? String ?? "") })
        }
    }

    func testProviderPresetsFillEditableDraftsClearKeysAndNeverSend() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let checks = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          booksbridge.onState({modelCatalog:{services:[],defaultChat:'',defaultSummary:''}});
          $('settings-btn').click(); document.querySelector('[data-section=model]').click(); $('service-add').click();
          const expected = [
            ['openai','OpenAI','https://api.openai.com/v1',true],
            ['anthropic','Anthropic','https://api.anthropic.com/v1',true],
            ['deepseek','DeepSeek','https://api.deepseek.com/v1',true],
            ['openrouter','OpenRouter','https://openrouter.ai/api/v1',true],
            ['local','本地','http://localhost:11434/v1',false]];
          const filled = expected.every(([id,name,url,key]) => {
            $('service-key').value='test-only-draft'; $('service-preset').value=id; $('service-preset').dispatchEvent(new Event('change'));
            return $('service-name').value===name && $('service-url').value===url && $('service-requires-key').checked===key && $('service-key').value==='';
          });
          $('service-url').value='http://localhost:4321/v1'; $('service-url').dispatchEvent(new Event('input'));
          booksbridge.onState({modelCatalog:{services:[],defaultChat:'',defaultSummary:''}});
          const retained = $('service-url').value==='http://localhost:4321/v1';
          $('service-detail').querySelector('form').requestSubmit();
          return {filled,retained,custom:[...$('service-preset').options].some(o=>o.value==='custom')};
        })()
        """) as! [String:Bool]
        for (key,value) in checks { XCTAssertTrue(value,key) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(calls.calls.contains { ["ask","testModel","listModels","reprocessBook"].contains($0["type"] as? String ?? "") })
        let saved = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "saveService" }?["payload"] as? [String:Any])
        XCTAssertEqual(saved["name"] as? String,"本地")
        XCTAssertEqual(saved["baseURL"] as? String,"http://localhost:4321/v1")
        XCTAssertEqual(saved["requiresKey"] as? Bool,false); XCTAssertNil(saved["key"]); XCTAssertNil(saved["id"])
    }

    func testModelManagementDoesNotSendUntilExplicitActionAndDraftSurvivesPush() async throws {
        let (view,calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          window.catalogFixture = {services:[{id:'P',name:'Provider',baseURL:'https://example.test/v1',enabled:true,requiresKey:true,hasKey:true,revision:'p1',
            models:[{id:'CHAT',name:'Chat model',remoteID:'chat-id',contextTokens:32768,outputTokens:2048,revision:'m1'}]},
            {id:'LOCAL',name:'Local',baseURL:'http://localhost:1234/v1',enabled:true,requiresKey:false,hasKey:false,revision:'p2',
            models:[{id:'SUMMARY',name:'Summary model',remoteID:'summary-id',contextTokens:65536,outputTokens:2048,revision:'m2'}]}],defaultChat:'CHAT',defaultSummary:'SUMMARY'};
          booksbridge.onState({modelCatalog:catalogFixture,modelSelection:{chat:'CHAT',summary:'SUMMARY',chatReady:true,summaryReady:true}});
          $('settings-btn').click(); document.querySelector('[data-section=model]').click();
          const keyHidden = $('service-key').value === '' && $('service-key').placeholder.includes('已保存');
          $('service-name').value = 'Unsaved name'; $('service-name').dispatchEvent(new Event('input'));
          booksbridge.onState({modelCatalog:catalogFixture});
          const draft = $('service-name').value === 'Unsaved name';
          [...document.querySelectorAll('#service-detail button')].find(b => b.textContent === '放弃修改').click();
          document.querySelector('[data-section=defaults]').click();
          const defaults = $('default-chat-model').value === 'CHAT' && $('default-summary-model').value === 'SUMMARY';
          $('default-summary-model').value = 'CHAT'; $('default-summary-model').dispatchEvent(new Event('change'));
          document.querySelector('[data-section=model]').click();
          [...document.querySelectorAll('#service-detail button')].find(b => b.textContent === '测试连接').click();
          return {keyHidden,draft,defaults};
        })()
        """) as! [String:Bool]
        for (key,value) in result { XCTAssertTrue(value,key) }
        try await Task.sleep(for:.milliseconds(40))
        XCTAssertFalse(calls.calls.contains { ["ask","listModels","reprocessBook","testAPI","analyzeStructure"].contains($0["type"] as? String ?? "") })
        let tests = calls.calls.filter { $0["type"] as? String == "testModel" }
        XCTAssertEqual(tests.count,1)
        let payload = try XCTUnwrap(tests.first?["payload"] as? [String:Any]); XCTAssertEqual(payload["id"] as? String,"CHAT"); XCTAssertNil(payload["apiKey"])
        let defaults = try XCTUnwrap(calls.calls.last { $0["type"] as? String == "setDefaultModel" }?["payload"] as? [String:Any])
        XCTAssertEqual(defaults["purpose"] as? String,"summary"); XCTAssertEqual(defaults["id"] as? String,"CHAT")
    }

    func testModelPickersAreIndependentSearchableAndHistoryKeepsAttribution() async throws {
        let (view,calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          const catalog = {services:[{id:'P',name:'Provider',enabled:true,requiresKey:false,models:[{id:'CHAT',name:'Chat model',remoteID:'chat',contextTokens:32768},{id:'SUMMARY',name:'Summary model',remoteID:'summary',contextTokens:32768}]}],defaultChat:'CHAT',defaultSummary:'SUMMARY'};
          const active = {assetID:'A',conversationID:'C',scope:'upToProgress',messages:[{id:'answer',role:'assistant',text:'回答',modelName:'Original provider / Original model'}]};
          booksbridge.onState({modelCatalog:catalog,modelSelection:{chat:'CHAT',summary:'SUMMARY',chatReady:true,summaryReady:true},active});
          $('composer-model').click(); $('model-search').value = 'Summary'; $('model-search').dispatchEvent(new Event('input'));
          const search = document.querySelectorAll('.model-picker-option').length === 1;
          document.querySelector('.model-picker-option').click(); $('model-picker-close').click();
          booksbridge.onState({modelSelection:{chat:'SUMMARY',summary:'SUMMARY',chatReady:true,summaryReady:true},active});
          const history = document.querySelector('.msg.assistant .msg-role').textContent === 'Original provider / Original model';
          document.querySelector('[data-action=summary]').click(); $('summary-model').click();
          [...document.querySelectorAll('.model-picker-option')].find(b => b.textContent === 'Chat model').click(); $('model-picker-close').click(); $('summary-back').click();
          $('input').value='question'; $('input').dispatchEvent(new Event('input')); $('send-btn').click();
          const locked = $('composer-model').disabled; $('cancel-btn').click();
          booksbridge.onState({modelSelection:{chat:'DELETED',summary:'SUMMARY',chatReady:false,summaryReady:true}});
          $('input').value='question'; $('input').dispatchEvent(new Event('input'));
          const unavailable = $('send-btn').disabled && $('composer-model').textContent.includes('不可用') && !$('summary-model').disabled;
          return {search,history,locked,unavailable};
        })()
        """) as! [String:Bool]
        for (key,value) in result { XCTAssertTrue(value,key) }
        try await Task.sleep(for:.milliseconds(40))
        let selected = calls.calls.filter { $0["type"] as? String == "selectModel" }.compactMap { $0["payload"] as? [String:Any] }
        XCTAssertEqual(selected.count,2)
        XCTAssertEqual(selected[0]["purpose"] as? String,"chat"); XCTAssertEqual(selected[0]["id"] as? String,"SUMMARY")
        XCTAssertEqual(selected[1]["purpose"] as? String,"summary"); XCTAssertEqual(selected[1]["id"] as? String,"CHAT")
        XCTAssertEqual(selected[0]["assetID"] as? String,"A"); XCTAssertEqual(selected[0]["conversationID"] as? String,"C")
    }

    private func modelLibraryFixture() async throws -> (WKWebView, UIInvocations) {
        let (view, calls) = try await workspaceFixture()
        _ = try await view.evaluateJavaScript("""
        window.modelCalls = [];
        ModelManager.init({invoke:(action,payload)=>modelCalls.push({action,...payload}),feedback:()=>{},context:()=>({})});
        window.libraryFixture = {services:[{id:'P',name:'Provider',baseURL:'https://example.test/v1',enabled:true,requiresKey:false,revision:'r1',
          models:[{id:'old',name:'Existing model',remoteID:'existing',contextTokens:32768,revision:'m1'}]},
          {id:'Q',name:'Second',baseURL:'https://second.example.test/v1',enabled:true,requiresKey:false,revision:'r2',models:[]}],defaultChat:'',defaultSummary:''};
        booksbridge.onState({modelCatalog:libraryFixture});
        document.getElementById('settings-btn').click(); document.querySelector('[data-section=model]').click();
        window.replyModels = (models, success=true) => booksbridge.onState({modelResult:{requestID:modelCalls.at(-1).requestID,success,models,message:success?'成功':'模拟网络错误'}});
        document.getElementById('service-models-add').click(); undefined;
        """)
        return (view,calls)
    }

    func testModelLibrarySurvivesBackgroundPushCloseSearchAndProviderSwitch() async throws {
        let (view,calls) = try await modelLibraryFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        let checks = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id), row = id => [...document.querySelectorAll('[data-remote-id]')].find(el=>el.dataset.remoteId===id);
          const noAutomaticFetch = modelCalls.length===0;
          $('model-library-refresh').click(); replyModels(['existing','vendor/alpha','vendor/beta',...Array.from({length:60},(_,i)=>'model-'+i)]);
          row('vendor/alpha').click(); $('model-library-rows').scrollTop=180;
          const first = row('vendor/alpha'), scroll = $('model-library-rows').scrollTop;
          function reorder(value) { return Array.isArray(value) ? value.map(reorder) : value && typeof value==='object' ? Object.fromEntries(Object.keys(value).reverse().map(k=>[k,reorder(value[k])])) : value; }
          for(let i=0;i<12;i++) booksbridge.onState({modelCatalog:reorder(libraryFixture),readingPosition:'位置 '+i});
          const stable = $('model-library').open && row('vendor/alpha')===first && first.checked && $('model-library-rows').scrollTop===scroll;
          $('model-library-search').value='beta'; $('model-library-search').dispatchEvent(new Event('input')); row('vendor/beta').click();
          $('model-library-close').click(); document.querySelectorAll('.service-item')[1].click(); $('service-models-add').click();
          const isolated = $('model-library-search').value==='' && $('model-library-selected').textContent==='已选择 0 个';
          $('model-library-close').click(); document.querySelectorAll('.service-item')[0].click(); $('service-models-add').click();
          const restored = $('model-library-search').value==='beta' && row('vendor/beta').checked && $('model-library-selected').textContent==='已选择 2 个';
          libraryFixture.defaultSummary='old'; booksbridge.onState({modelCatalog:libraryFixture});
          const realChange = $('model-library').open && row('vendor/beta').checked && $('model-library-search').value==='beta';
          $('model-library-close').click(); document.querySelector('[data-section=general]').click(); document.querySelector('[data-section=model]').click(); $('service-models-add').click();
          return {noAutomaticFetch,stable,isolated,restored,realChange,oneFetch:modelCalls.length===1,afterNavigation:row('vendor/beta').checked};
        })()
        """) as! [String:Bool]
        for (key,value) in checks { XCTAssertTrue(value,key) }
        XCTAssertFalse(calls.calls.contains { ["listModels","testModel","ask"].contains($0["type"] as? String ?? "") })
    }

    func testModelLibraryFilteredBulkSelectionAndFailureRetry() async throws {
        let (view,_) = try await modelLibraryFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        let checks = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id), row = id => [...document.querySelectorAll('[data-remote-id]')].find(el=>el.dataset.remoteId===id);
          $('model-library-refresh').click(); replyModels(['existing','family/a','family/b','other']);
          const addedDisabled = row('existing').checked && row('existing').disabled;
          row('other').click(); $('model-library-search').value='family'; $('model-library-search').dispatchEvent(new Event('input'));
          $('model-library-all').click();
          const allFiltered = $('model-library-selected').textContent==='已选择 3 个';
          $('model-library-all').click(); const deselectFiltered = $('model-library-selected').textContent==='已选择 1 个';
          $('model-library-all').click(); $('model-library-refresh').click(); replyModels([],false);
          const failurePreserved = row('family/a').checked && $('model-library-selected').textContent==='已选择 3 个' && $('model-library-status').textContent.includes('已保留');
          $('model-library-add').click(); const request = modelCalls.at(-1);
          const batch = request.action==='addModels' && request.serviceID==='P' && request.revision==='r1' && request.remoteIDs.length===3 && !request.remoteIDs.includes('existing');
          $('model-library-add').click(); const doubleClickBlocked = modelCalls.at(-1)===request;
          replyModels([],false);
          const addFailurePreserved = $('model-library').open && row('family/a').checked && !$('model-library-add').disabled;
          $('model-library-add').click(); replyModels([]);
          const successClosed = !$('model-library').open;
          libraryFixture.services[0].models.push(...['family/a','family/b','other'].map(id=>({id,name:id,remoteID:id,contextTokens:32768})));
          booksbridge.onState({modelCatalog:libraryFixture}); $('service-models-add').click();
          const saved = row('family/a').checked && row('family/a').disabled && $('model-library-selected').textContent==='已选择 0 个';
          $('model-library-new').click(); const hiddenAdded = !row('family/a');
          return {addedDisabled,allFiltered,deselectFiltered,failurePreserved,batch,doubleClickBlocked,addFailurePreserved,successClosed,saved,hiddenAdded};
        })()
        """) as! [String:Bool]
        for (key,value) in checks { XCTAssertTrue(value,key) }
    }

    func testModelLibraryLateResponsesRevisionChangesAndMissingSelections() async throws {
        let (view,_) = try await modelLibraryFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        let checks = try await view.evaluateJavaScript("""
        (() => {
          const $=id=>document.getElementById(id), row=id=>[...document.querySelectorAll('[data-remote-id]')].find(el=>el.dataset.remoteId===id);
          $('model-library-refresh').click(); $('model-library-close').click();
          document.querySelectorAll('.service-item')[1].click(); $('service-models-add').click(); replyModels(['a','b']);
          const noCrossProvider = !row('a');
          $('model-library-close').click(); document.querySelectorAll('.service-item')[0].click(); $('service-models-add').click();
          const lateCached = !!row('a'); row('a').click(); row('b').click();
          $('model-library-refresh').click(); replyModels(['a','c']);
          const missingKept = row('b').checked && $('model-library-selected').textContent.includes('1 个已不可用') && $('model-library-add').textContent==='添加所选（1）';
          $('model-library-refresh').click(); libraryFixture.services[0].revision='new'; booksbridge.onState({modelCatalog:libraryFixture}); replyModels(['wrong']);
          const staleRejected = !row('wrong') && row('a').checked && $('model-library-add').disabled;
          $('model-library-refresh').click(); replyModels(['a','b']);
          const recovered = row('b').checked && !$('model-library-add').disabled;
          libraryFixture.services.shift(); booksbridge.onState({modelCatalog:libraryFixture});
          return {noCrossProvider,lateCached,missingKept,staleRejected,recovered,deletedCloses:!$('model-library').open};
        })()
        """) as! [String:Bool]
        for (key,value) in checks { XCTAssertTrue(value,key) }
    }

    func testModelLibraryFitsMinimumWindowWithFooterVisible() async throws {
        let (view,_) = try await modelLibraryFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName:"booksbridge") }
        view.frame = CGRect(x:0,y:0,width:720,height:460)
        try await Task.sleep(for:.milliseconds(60))
        let checks = try await view.evaluateJavaScript("""
        (()=>{
          const $=id=>document.getElementById(id);
          $('model-library-refresh').click(); replyModels(Array.from({length:100},(_,i)=>'provider/very-long-model-name-'+i));
          const dialog=$('model-library').getBoundingClientRect(), footer=document.querySelector('.library-footer').getBoundingClientRect(), rows=$('model-library-rows');
          return {fits:dialog.left>=0 && dialog.right<=innerWidth && dialog.top>=0 && dialog.bottom<=innerHeight,
            footerVisible:footer.bottom<=dialog.bottom && footer.top>dialog.top,
            rowsScroll:rows.clientHeight>60 && rows.scrollHeight>rows.clientHeight,
            noHorizontalOverflow:$('model-library').scrollWidth<=$('model-library').clientWidth};
        })()
        """) as! [String:Bool]
        for (key,value) in checks { XCTAssertTrue(value,key) }
    }

    private func workspaceFixture() async throws -> (WKWebView, UIInvocations) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BooksBridgeApp/WebUI")
        let config = WKWebViewConfiguration(); let calls = UIInvocations()
        config.userContentController.add(calls, name: "booksbridge")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        let ready = expectation(description: "workspace loaded"); let navigation = NavigationReady(ready)
        view.navigationDelegate = navigation
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        await fulfillment(of: [ready], timeout: 10)
        _ = try await view.evaluateJavaScript("""
        window.fixtureBooks = [{assetID:'A',title:'书A',conversations:[{id:'C',title:'对话1',messageCount:1}]},{assetID:'B',title:'书B',conversations:[]}];
        booksbridge.onState({settings:{model:'test',baseURL:'https://example.test/v1',isConfigured:true,defaultScope:'upToProgress'},
          knowledgeScopes:[{id:'upToProgress',label:'读到这为止'},{id:'currentChapter',label:'整章'},{id:'wholeBook',label:'整书'}],
          library:fixtureBooks,active:{assetID:'A',conversationID:'C',scope:'upToProgress',messages:[{role:'assistant',text:'已有回答'}]},
          readingPosition:'第一章 · 20% · 沿用上次位置',assistant:{preparation:'未生成摘要',ready:false}}); undefined;
        """)
        return (view, calls)
    }

    func testSlashCommandsAndPlusMenuShareLocalActions() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id), input = $('input');
          const type = value => { input.value = value; input.dispatchEvent(new Event('input')); };
          const key = value => input.dispatchEvent(new KeyboardEvent('keydown',{key:value,bubbles:true,cancelable:true}));
          $('actions-btn').click();
          const menu = !$('actions-menu').hidden;
          document.querySelector('[data-action="select"]').click();
          type('/'); const count = $('command-list').children.length;
          key('ArrowDown'); key('Enter');
          const selected = input.value === '/select ';
          key('Enter');
          type('/bogus'); key('Enter');
          const unknown = !$('command-feedback').hidden && input.value === '/bogus';
          type('/'); key('Escape'); const escaped = $('command-list').hidden;
          type('/summary'); $('send-btn').click();
          const summary = !$('summary-document').hidden && !$('reading-panel').open;
          $('prep-retry').click(); const confirmed = !$('prepare-confirm').open;
          $('summary-back').click();
          type('/scope'); $('send-btn').click();
          const scope = $('reading-panel').open && !$('range-panel').hidden;
          $('reading-panel').close();
          type('/new'); $('send-btn').click();
          booksbridge.onState({settings:{isConfigured:false}});
          type('/summary'); const noKey = !$('send-btn').disabled; $('send-btn').click(); $('summary-back').click();
          type('/now'); $('send-btn').click();
          booksbridge.onState({positionRefreshFinished:true});
          booksbridge.onState({settings:{isConfigured:true}});
          type('/now 解释当前段落'); $('send-btn').click();
          const thinking = document.querySelector('.msg:last-child').textContent.includes('正在思考');
          return {menu,count,selected,unknown,escaped,summary,confirmed,scope,noKey,thinking,
            clean:!document.querySelector('.composer #prep-bar') && !document.querySelector('.composer #capture-selection')};
        })()
        """) as! [String: Any]
        for key in ["menu", "selected", "unknown", "escaped", "summary", "confirmed", "scope", "noKey", "thinking", "clean"] { XCTAssertEqual(result[key] as? Bool, true, key) }
        XCTAssertEqual(result["count"] as? Int, 5)
        try await Task.sleep(for: .milliseconds(100))
        let types = calls.calls.compactMap { $0["type"] as? String }
        XCTAssertEqual(types.filter { $0 == "captureSelection" }.count, 2)
        XCTAssertTrue(types.contains("checkReading")); XCTAssertTrue(types.contains("newConversation"))
        XCTAssertFalse(types.contains("returnToReader")); XCTAssertTrue(types.contains("reprocessBook")); XCTAssertTrue(types.contains("refreshPosition"))
        let questions = calls.calls.filter { $0["type"] as? String == "ask" }.compactMap { ($0["payload"] as? [String: Any])?["question"] as? String }
        XCTAssertEqual(questions, ["/now 解释当前段落"])
    }

    func testBookMovementArchiveAndRestoreControls() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          document.querySelector('[aria-label="《书A》的操作"]').click();
          [...$('sidebar-menu').children].find(el => el.textContent === '下移').click();
          booksbridge.onState({library:[fixtureBooks[1],fixtureBooks[0]]});
          const moved = document.querySelector('.book-group').dataset.assetId === 'B';
          const groups = [...document.querySelectorAll('.book-group')];
          const transfer = new DataTransfer();
          groups[1].querySelector('.book-row').dispatchEvent(new DragEvent('dragstart',{dataTransfer:transfer,bubbles:true}));
          groups[0].dispatchEvent(new DragEvent('dragover',{dataTransfer:transfer,clientY:groups[0].getBoundingClientRect().top,bubbles:true,cancelable:true}));
          groups[0].dispatchEvent(new DragEvent('drop',{dataTransfer:transfer,bubbles:true,cancelable:true}));
          groups[1].querySelector('.book-row').dispatchEvent(new DragEvent('dragend',{dataTransfer:transfer,bubbles:true}));
          document.querySelector('[aria-label="对话1的操作"]').click(); $('sidebar-menu').querySelector('button').click();
          const library = [{...fixtureBooks[0],conversations:[{id:'C',title:'对话1',messageCount:1,archived:true}]}];
          booksbridge.onState({library,active:{assetID:'A'}});
          const hidden = document.querySelectorAll('.conv-row').length === 0;
          $('settings-btn').click(); $('archives-btn').click();
          const listed = !$('view-settings').hidden && !document.querySelector('[data-pane=archives]').hidden && $('archives-list').textContent.includes('对话1');
          document.querySelector('.archive-title').click();
          booksbridge.onState({active:{assetID:'A',conversationID:'C',archived:true,scope:'upToProgress',messages:[{role:'assistant',text:'已保留的原对话'}]}});
          const readOnly = $('input').disabled && !$('archive-banner').hidden && $('messages').textContent.includes('已保留的原对话');
          $('restore-active').click();
          booksbridge.onState({library:fixtureBooks,active:{assetID:'A',conversationID:'C',archived:false,scope:'upToProgress',messages:[]}});
          return {moved,hidden,listed,readOnly,restored:!$('input').disabled && $('archive-banner').hidden,locked:$('scope-picker').disabled};
        })()
        """) as! [String: Any]
        for key in ["moved", "hidden", "listed", "readOnly", "restored", "locked"] { XCTAssertEqual(result[key] as? Bool, true, key) }
        try await Task.sleep(for: .milliseconds(100))
        let moves = calls.calls.filter { $0["type"] as? String == "moveBook" }.compactMap { $0["payload"] as? [String: Any] }
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first?["assetID"] as? String, "A")
        XCTAssertTrue(moves.first?["beforeAssetID"] is NSNull)
        XCTAssertEqual(moves.last?["beforeAssetID"] as? String, "B")
        for type in ["archiveConversation", "restoreConversation"] {
            let payload = try XCTUnwrap(calls.calls.first { $0["type"] as? String == type }?["payload"] as? [String: Any])
            XCTAssertEqual(payload["conversationID"] as? String, "C"); XCTAssertEqual(payload["assetID"] as? String, "A")
        }
        XCTAssertFalse(calls.calls.contains { $0["type"] as? String == "deleteConversation" })
    }

    func testCompactLayoutAndSummaryProgressRemainVisible() async throws {
        let (view, _) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        for size in [CGSize(width:720,height:460), CGSize(width:1440,height:900)] {
            view.frame.size = size
            _ = try await view.evaluateJavaScript("""
            booksbridge.onState({assistant:{preparation:'正在生成摘要',ready:false,running:true},bookStatistics:{characters:10000,completed:2,chapters:Array.from({length:5},(_,i)=>({number:i+1,title:'章节',complete:i<2}))},summaryMetadata:'读到这为止 · 今天',selectionCandidate:{token:'T',text:'这是需要确认的引用内容。'.repeat(50),exact:false}}); undefined;
            """)
            try await Task.sleep(for: .milliseconds(40))
            let result = try await view.evaluateJavaScript("""
            (() => {
              const $ = id => document.getElementById(id);
              const r = document.querySelector('.composer').getBoundingClientRect();
              const within = r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight;
              $('selection-confirmed').checked = true; $('selection-confirmed').dispatchEvent(new Event('change'));
              const compact = !$('selection-details').open;
              document.querySelector('[data-action="summary"]').click();
              const progress = $('prep-text').textContent.includes('2 / 5') && $('summary-status').textContent.includes('2/5') && $('prep-retry').hidden && !$('prep-cancel').hidden;
              booksbridge.onState({assistant:{preparation:'摘要已完成',ready:true},scopeSummary:'**摘要结果**',summaryMetadata:'读到这为止 · 今天'});
              const result = !!$('scope-summary-text').querySelector('strong') && !$('scope-summary').hidden && $('prep-retry').hidden && $('prep-cancel').hidden;
              $('summary-back').click();
              return {within,compact,progress,result};
            })()
            """) as! [String: Any]
            for key in ["within", "compact", "progress", "result"] { XCTAssertEqual(result[key] as? Bool, true, "\(size): \(key)") }
        }
    }
}

@MainActor
extension WebRenderingTests {
    func testMessageActionsPersistedRefreshAndRetryCancellation() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const $ = id => document.getElementById(id);
          const messages = [{id:'q',role:'user',text:'原问题'},{id:'a',role:'assistant',text:'**原回答**',canRetry:true,modelName:'Original model'}];
          const active = {assetID:'A',conversationID:'C',scope:'upToProgress',messages};
          booksbridge.onState({active});
          const action = name => document.querySelector(`[data-message-action="${name}"]`);
          booksbridge.onState({settings:{model:'updated-model',isConfigured:true}});
          const model = document.querySelector('.msg.assistant .msg-role').textContent === 'Original model';
          const controls = document.querySelectorAll('.message-action').length === 5;
          const size = action('copy').getBoundingClientRect().width === 28 && action('copy').querySelector('svg').getBoundingClientRect().width === 16;
          action('copy').click(); action('edit').click();
          let editor = document.querySelector('.msg-editor textarea'); editor.value = '修改后的问题';
          document.querySelector('[data-save-message]').click();
          booksbridge.onState({active:{...active,messages:[{...messages[0],text:'修改后的问题'},messages[1]]}});
          const edited = !document.querySelector('.msg-editor') && $('messages').textContent.includes('修改后的问题');
          action('retry').click();
          const thinking = $('messages').textContent.includes('正在思考') && document.querySelectorAll('.msg').length === 2 && action('delete').disabled;
          const escape = () => window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',cancelable:true}));
          escape(); const single = !$('cancel-btn').hidden; escape();
          const restored = $('messages').textContent.includes('原回答') && !!document.querySelector('.msg-body strong') && $('cancel-btn').hidden;
          action('retry').click(); booksbridge.onState({chatEvent:{kind:'error',text:'模拟网络失败'}});
          const failureRestored = $('messages').textContent.includes('原回答') && !action('retry').disabled;
          action('retry').click(); booksbridge.onState({chatEvent:{kind:'finished',text:'新回答'}});
          booksbridge.onState({active:{...active,messages:[{...messages[0],text:'修改后的问题'},{...messages[1],text:'新回答'}]}});
          const replaced = document.querySelectorAll('.msg').length === 2 && $('messages').textContent.includes('新回答');
          document.querySelector('.msg.assistant [data-message-action="delete"]').click();
          booksbridge.onState({active:{...active,messages:[messages[0]]}});
          const deleted = document.querySelectorAll('.msg').length === 1;
          booksbridge.onState({active:{...active,archived:true}});
          return {model,controls,size,edited,thinking,single,restored,failureRestored,replaced,deleted,readOnly:action('edit').disabled && !action('copy').disabled};
        })()
        """) as! [String: Any]
        for (key, value) in result { XCTAssertEqual(value as? Bool, true, key) }
        try await Task.sleep(for: .milliseconds(100))
        for type in ["copyMessage", "editMessage", "deleteMessage", "retryMessage"] {
            let payload = try XCTUnwrap(calls.calls.first { $0["type"] as? String == type }?["payload"] as? [String: Any])
            XCTAssertEqual(payload["assetID"] as? String, "A"); XCTAssertEqual(payload["conversationID"] as? String, "C")
        }
        XCTAssertEqual(calls.calls.filter { $0["type"] as? String == "cancelAnswer" }.count, 1)
        XCTAssertFalse(calls.calls.contains { $0["type"] as? String == "returnToReader" })
        XCTAssertEqual((calls.calls.first { $0["type"] as? String == "editMessage" }?["payload"] as? [String: Any])?["text"] as? String, "修改后的问题")
    }

    func testSendKeyboardAndStopSequenceIsolation() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        let result = try await view.evaluateJavaScript("""
        (() => {
          const input = document.getElementById('input'); input.value = '新问题'; input.dispatchEvent(new Event('input'));
          const key = (target, name, options={}) => target.dispatchEvent(new KeyboardEvent('keydown',{key:name,bubbles:true,cancelable:true,...options}));
          const newline = key(input,'Enter',{shiftKey:true});
          key(input,'Enter',{isComposing:true});
          const composing = document.getElementById('cancel-btn').hidden;
          key(input,'Enter');
          const started = !document.getElementById('cancel-btn').hidden;
          key(window,'Escape'); key(window,'a'); key(window,'Escape');
          const interrupted = !document.getElementById('cancel-btn').hidden;
          key(window,'Escape',{repeat:true}); key(window,'Escape');
          const repeated = !document.getElementById('cancel-btn').hidden;
          document.getElementById('reading-panel').showModal(); key(window,'Escape'); document.getElementById('reading-panel').close(); key(window,'Escape');
          const modal = !document.getElementById('cancel-btn').hidden;
          document.getElementById('cancel-btn').click();
          return {newline,composing,started,interrupted,repeated,modal,stopped:document.getElementById('cancel-btn').hidden,
            size:document.getElementById('send-btn').getBoundingClientRect().width === 34};
        })()
        """) as! [String: Any]
        for (key,value) in result { XCTAssertEqual(value as? Bool, true, key) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.calls.filter { $0["type"] as? String == "ask" }.count, 1)
        XCTAssertEqual(calls.calls.filter { $0["type"] as? String == "cancelAnswer" }.count, 1)
    }
}

@MainActor
extension WebRenderingTests {
    func testSettingsNavigationSavesWithoutDoneAndTopbarShowsReadingState() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        for size in [CGSize(width:720,height:460), CGSize(width:1440,height:900)] {
            view.frame.size = size
            let result = try await view.evaluateJavaScript("""
            (() => {
              const $ = id => document.getElementById(id);
              $('settings-btn').click();
              document.querySelector('[data-section="general"]').click();
              $('set-maxtokens').value = '16000'; $('set-maxtokens').dispatchEvent(new Event('input'));
              document.querySelector('.conv-row').click();
              const switched = !$('view-chat').hidden && $('view-settings').hidden;
              $('settings-btn').click(); $('archives-btn').click();
              const archives = !$('view-settings').hidden && !document.querySelector('[data-pane="archives"]').hidden && !$('archives-btn').closest('.side-foot');
              $('settings-btn').click();
              const toggle = !$('view-chat').hidden && !document.querySelector('#settings-close');
              const header = document.querySelector('#view-chat > .topbar');
              const crumb = document.querySelector('#view-chat .crumb').getBoundingClientRect();
              const back = $('return-btn').getBoundingClientRect();
              const layout = !!header && !$('reading-position') && !header.contains($('summary-status')) && crumb.right <= back.left;
              document.querySelector('[data-action=summary]').click(); const summary = !$('summary-document').hidden && !$('reading-panel').open; $('summary-back').click();
              return {switched,archives,toggle,layout,summary};
            })()
            """) as! [String: Any]
            for (key,value) in result { XCTAssertEqual(value as? Bool, true, "\(size): \(key)") }
        }
        try await Task.sleep(for: .milliseconds(100))
        let saves = calls.calls.filter { $0["type"] as? String == "saveSettings" }
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual((saves.first?["payload"] as? [String: Any])?["maxContextCharacters"] as? Int, 16000)
    }

    func testSavedReasoningReloadsAndCanBeManuallyToggled() async throws {
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        _ = try await view.evaluateJavaScript("""
        window.reasoningFixture = {assetID:'A',conversationID:'C',scope:'upToProgress',messages:[
          {id:'q',role:'user',text:'问题'}, {id:'a',role:'assistant',text:'正文',reasoning:'保存的思考内容',reasoningExpanded:false,canRetry:true}]};
        booksbridge.onState({settings:{model:'test',isConfigured:true,autoExpandReasoning:true}, active:reasoningFixture}); undefined;
        """)
        try await Task.sleep(for: .milliseconds(50))
        let initial = try await view.evaluateJavaScript("!!document.querySelector('.msg-reasoning') && !document.querySelector('.msg-reasoning').open && document.querySelector('.reasoning-body').textContent === '保存的思考内容'")
        XCTAssertEqual(initial as? Bool, true)
        _ = try await view.evaluateJavaScript("document.querySelector('.msg-reasoning summary').click(); undefined")
        try await Task.sleep(for: .milliseconds(50))
        let opened = try await view.evaluateJavaScript("document.querySelector('.msg-reasoning').open")
        XCTAssertEqual(opened as? Bool, true)
        _ = try await view.evaluateJavaScript("""
        booksbridge.onState({active:{assetID:'B',conversationID:'D',messages:[]}});
        booksbridge.onState({active:{...reasoningFixture,messages:[reasoningFixture.messages[0],{...reasoningFixture.messages[1],reasoningExpanded:true}]}});
        document.querySelector('.msg-reasoning summary').click(); undefined;
        """)
        try await Task.sleep(for: .milliseconds(50))
        let closed = try await view.evaluateJavaScript("document.querySelector('.msg-reasoning').open")
        XCTAssertEqual(closed as? Bool, false)
        let toggles = calls.calls.filter { $0["type"] as? String == "setReasoningExpanded" }.compactMap { $0["payload"] as? [String: Any] }
        XCTAssertEqual(toggles.compactMap { $0["expanded"] as? Bool }, [true,false])
        XCTAssertTrue(toggles.allSatisfy { $0["messageID"] as? String == "a" && $0["conversationID"] as? String == "C" })
        _ = try await view.evaluateJavaScript("""
        booksbridge.onState({settings:{model:'test',isConfigured:true,autoExpandReasoning:false},active:{assetID:'A',conversationID:'live',messages:[]}});
        const input = document.getElementById('input'); input.value = '新问题'; input.dispatchEvent(new Event('input'));
        document.getElementById('send-btn').click(); booksbridge.onState({chatEvent:{kind:'reasoning',text:'流式思考'}});
        document.querySelector('.msg-reasoning summary').click(); undefined;
        """)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await view.evaluateJavaScript("""
        booksbridge.onState({chatEvent:{kind:'finished',text:'新回答'}});
        booksbridge.onState({active:{assetID:'A',conversationID:'live',messages:[{id:'live-q',role:'user',text:'新问题'},{id:'live-a',role:'assistant',text:'新回答',reasoning:'流式思考',canRetry:true}]}}); undefined;
        """)
        try await Task.sleep(for: .milliseconds(50))
        let liveChoice = calls.calls.last { $0["type"] as? String == "setReasoningExpanded" }?["payload"] as? [String: Any]
        XCTAssertEqual(liveChoice?["messageID"] as? String, "live-a")
        XCTAssertEqual(liveChoice?["expanded"] as? Bool, true)

    }
}

@MainActor
extension WebRenderingTests {
    /// Real WKWebView controls + a temporary on-disk store. No model client is created.
    func testReasoningLifecycleAcrossSwitchArchiveReloadAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reasoning-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("store.json")
        var store = ConversationStore(fileURL: file)
        store.addBook(assetID: "A", title: "测试书", author: "")
        let first = try XCTUnwrap(store.createConversation(assetID: "A"))
        let second = try XCTUnwrap(store.createConversation(assetID: "A"))
        store.appendMessage(assetID: "A", conversationID: first.id, message: .init(id: "q", role: .user, text: "问题"))
        store.saveAnswer(assetID: "A", conversationID: first.id, questionID: "q", replacing: nil,
            answer: .init(id: "a", role: .assistant, text: "回答", reasoning: "LOCAL_REASONING_DELETE_MARKER", reasoningExpanded: false))
        store.setActive(assetID: "A", conversationID: first.id)
        let (view, calls) = try await workspaceFixture()
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "booksbridge") }
        calls.calls.removeAll()
        calls.onCall = { call in
            let payload = call["payload"] as? [String: Any] ?? [:]
            let cid = payload["conversationID"] as? String ?? ""
            switch call["type"] as? String {
            case "setReasoningExpanded":
                store.setReasoningExpanded(assetID: "A", conversationID: cid, messageID: payload["messageID"] as? String ?? "", expanded: payload["expanded"] as? Bool ?? false)
            case "selectConversation": store.setActive(assetID: "A", conversationID: cid)
            case "archiveConversation": store.setArchived(assetID: "A", conversationID: cid, archived: true)
            case "restoreConversation":
                store.setArchived(assetID: "A", conversationID: cid, archived: false)
                store.setActive(assetID: "A", conversationID: cid)
            case "deleteMessage": store.changeMessage(assetID: "A", conversationID: cid, messageID: payload["messageID"] as? String ?? "")
            case "ask", "retryMessage", "testAPI", "reprocessBook": XCTFail("Lifecycle audit must not request model work")
            default: break
            }
        }
        func pushPersistedState() async throws {
            let activeID = store.state.lastActive?.conversationID ?? ""
            let c = store.conversation(assetID: "A", conversationID: activeID)
            let messages: [[String: Any]] = (c?.messages ?? []).map { m in
                ["id":m.id, "role":m.role.rawValue, "text":m.text, "reasoning":m.reasoning ?? NSNull() as Any,
                 "reasoningExpanded":m.reasoningExpanded ?? NSNull() as Any, "canRetry":m.role == .assistant]
            }
            let library: [[String: Any]] = [["assetID":"A", "title":"测试书", "conversations":store.book(assetID:"A")!.conversations.map { c in
                ["id":c.id, "title":c.id == first.id ? "第一对话" : "第二对话", "messageCount":c.messages.count, "archived":c.archivedAt != nil] as [String: Any]
            }]]
            let payload: [String: Any] = ["settings":["model":"local-test", "isConfigured":false, "autoExpandReasoning":true],
                "library":library, "active":["assetID":"A", "conversationID":activeID, "archived":c?.archivedAt != nil, "messages":messages]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            _ = try await view.evaluateJavaScript("booksbridge.onState(" + json + "); undefined;")
        }
        func assertReasoning(open: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let result = try await view.evaluateJavaScript("({text:document.querySelector('.reasoning-body')?.textContent, open:document.querySelector('.msg-reasoning')?.open})") as! [String: Any]
            XCTAssertEqual(result["text"] as? String, "LOCAL_REASONING_DELETE_MARKER", file:file,line:line)
            XCTAssertEqual(result["open"] as? Bool, open, file:file,line:line)
        }
        try await pushPersistedState(); try await assertReasoning(open:false)
        // Click then navigate in the same JS turn, before a native details toggle event can run.
        _ = try await view.evaluateJavaScript("document.querySelector('.msg-reasoning summary').click(); [...document.querySelectorAll('.conv-row')].find(b => b.textContent === '第二对话').click(); undefined;")
        try await Task.sleep(for: .milliseconds(100))
        let order = calls.calls.compactMap { $0["type"] as? String }.filter { ["setReasoningExpanded", "selectConversation"].contains($0) }
        XCTAssertEqual(order, ["setReasoningExpanded", "selectConversation"])
        XCTAssertEqual(store.state.lastActive?.conversationID, second.id)
        try await pushPersistedState()
        store.setActive(assetID:"A",conversationID:first.id); try await pushPersistedState(); try await assertReasoning(open:true)
        // Collapse and archive immediately; archiving must keep the whole reply and its preference.
        _ = try await view.evaluateJavaScript("document.querySelector('.msg-reasoning summary').click(); document.querySelector('.conversation-row.active .row-action').click(); document.querySelector('#sidebar-menu button').click(); undefined;")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(store.conversation(assetID:"A",conversationID:first.id)?.archivedAt)
        store = ConversationStore(fileURL:file)
        store.setActive(assetID:"A",conversationID:first.id)
        try await pushPersistedState(); try await assertReasoning(open:false)
        // Reload both persistence and the Web document, as on restart; global auto-expand must not override false.
        let loaded = expectation(description:"reasoning document reloaded")
        let navigation = NavigationReady(loaded); view.navigationDelegate = navigation; view.reload()
        await fulfillment(of:[loaded],timeout:10)
        store = ConversationStore(fileURL:file)
        try await pushPersistedState(); try await assertReasoning(open:false)
        _ = try await view.evaluateJavaScript("document.querySelector('.msg-reasoning summary').click(); undefined;")
        try await Task.sleep(for: .milliseconds(100))
        store = ConversationStore(fileURL:file)
        XCTAssertEqual(store.conversation(assetID:"A",conversationID:first.id)?.messages.last?.reasoningExpanded,true)
        let expandedReload = expectation(description:"expanded archived reasoning reloaded")
        let secondNavigation = NavigationReady(expandedReload); view.navigationDelegate = secondNavigation; view.reload()
        await fulfillment(of:[expandedReload],timeout:10)
        try await pushPersistedState(); try await assertReasoning(open:true)
        // Restoring permits deletion; neither the DOM nor the JSON may retain the reply's reasoning.
        _ = try await view.evaluateJavaScript("document.getElementById('restore-active').click(); undefined;")
        try await Task.sleep(for: .milliseconds(100)); try await pushPersistedState()
        _ = try await view.evaluateJavaScript("document.querySelector('.msg.assistant [data-message-action=delete]').click(); undefined;")
        try await Task.sleep(for: .milliseconds(100))
        store = ConversationStore(fileURL:file); try await pushPersistedState()
        let remaining = try await view.evaluateJavaScript("document.querySelectorAll('.msg-reasoning,.reasoning-body,.msg.assistant').length")
        XCTAssertEqual(remaining as? Int,0)
        XCTAssertFalse(try String(contentsOf:file,encoding:.utf8).contains("LOCAL_REASONING_DELETE_MARKER"))
        XCTAssertFalse(store.setReasoningExpanded(assetID:"A",conversationID:first.id,messageID:"a",expanded:true), "A delayed preference must not recreate a deleted reply")
        XCTAssertEqual(store.conversation(assetID:"A",conversationID:first.id)?.messages.map(\.id),["q"])
    }
}
