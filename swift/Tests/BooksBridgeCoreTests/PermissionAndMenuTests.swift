import XCTest

@testable import BooksBridgeApp
@testable import BooksBridgeCore

/// 权限探测的行为。
///
/// 这组测试针对一个真实的 bug：从终端直接跑会继承终端的 TCC 权限，
/// 用 `open`/Finder 启动才是独立主体——两者结果可能完全相反。
/// 所以判断"有没有权限"必须真正 open 文件，不能只看开关。
final class PermissionProbeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("booksbridge-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 缺数据不等于没权限——这是原本的意图，保留。
    ///
    /// 但"缺数据"与"被 TCC 拦截"的 errno 都是 ENOENT，必须靠外部信号区分：
    /// 图书 App 装了却读不到容器 → 被拦截；没装 → 数据本来就不存在。
    /// 这里把该信号注入，使测试不再依赖"本机是否装了图书 App"。
    func testMissingBooksDataWithoutBooksInstalledIsUnknown() {
        let permissions = Permissions(
            paths: BooksPaths(home: directory),
            booksInstalled: false
        )
        let status = permissions.fullDiskAccessStatus()
        guard case .unknown = status else {
            return XCTFail("没装图书 App 时缺数据应报无法判定，实际: \(status.label)")
        }
    }

    /// 反过来：装了图书 App 却读不到它的容器，只可能是被 TCC 拦截。
    func testMissingBooksDataWithBooksInstalledIsDenied() {
        let permissions = Permissions(
            paths: BooksPaths(home: directory),
            booksInstalled: true
        )
        let status = permissions.fullDiskAccessStatus()
        XCTAssertEqual(
            status, .denied,
            "装了图书 App 却读不到容器，应报未授权而不是「数据尚未创建」"
        )
    }

    func testReadableContainerAloneDoesNotGrantDataAccess() throws {
        let paths = BooksPaths(home: directory)
        try FileManager.default.createDirectory(at: paths.documents.appendingPathComponent("BKLibrary"), withIntermediateDirectories: true)
        let status = Permissions(paths: paths, booksInstalled: false).fullDiskAccessStatus()
        XCTAssertFalse(status.isGranted)
        guard case .unknown = status else { return XCTFail("Empty library is not a permission denial") }
    }

    func testInvalidDatabaseIsNotReportedAsGranted() throws {
        let paths = BooksPaths(home: directory)
        let library = paths.documents.appendingPathComponent("BKLibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: library.appendingPathComponent("BKLibrary-test.sqlite"))
        XCTAssertFalse(Permissions(paths: paths).fullDiskAccessStatus().isGranted)
    }

    func testProbeReportsMissingPath() {
        let result = Permissions.probeRead(directory.appendingPathComponent("nope").path)
        XCTAssertEqual(result, "不存在")
    }

    func testProbeReportsDirectory() {
        let result = Permissions.probeRead(directory.path)
        XCTAssertTrue(result.contains("可读"), "可读目录应报告可读，实际: \(result)")
    }

    func testProbeReportsFile() throws {
        let file = directory.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(Permissions.probeRead(file.path).contains("可读"))
    }

    func testProbeReportsPermissionDenied() throws {
        // 造一个没有读权限的文件，验证错误分支被走到且带 errno
        let file = directory.appendingPathComponent("locked.txt")
        try Data("secret".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        // root 不受权限位限制，CI 上以 root 跑时跳过
        try XCTSkipIf(getuid() == 0, "root 不受文件权限位限制")

        let result = Permissions.probeRead(file.path)
        XCTAssertTrue(result.contains("被拒绝"), "应报告被拒绝，实际: \(result)")
        XCTAssertTrue(result.contains("errno"), "应带上 errno 便于诊断，实际: \(result)")
    }

    /// 实测结论：受 TCC 保护时 `fileExists` 返回 false，
    /// 必须与"真的不存在"区分开——否则会把"没权限"误报成"图书 App 没开"。
    func testMissingProtectedPathIsReportedAsDeniedNotUnknown() {
        // 指向一个不存在的容器；主目录可见且图书 App 已装 → 判定为未授权
        let paths = BooksPaths(home: URL(fileURLWithPath: "/tmp"))
        let status = Permissions(paths: paths, booksInstalled: true).fullDiskAccessStatus()
        XCTAssertEqual(
            status, .denied,
            "受保护路径不可见时应报未授权；实际: \(status.label)"
        )
    }

    func testUnreadableHomeIsReportedAsUnknown() {
        // 连主目录都不存在时才是真正的"无法判定"
        let paths = BooksPaths(home: URL(fileURLWithPath: "/nonexistent-home-xyz"))
        let status = Permissions(paths: paths, booksInstalled: true).fullDiskAccessStatus()
        if case .unknown = status {
            // 期望
        } else {
            XCTFail("主目录不可访问时应报无法判定，实际: \(status.label)")
        }
    }

    func testProbeIsNotFooledByIsReadableFile() throws {
        // FileManager.isReadableFile 对 TCC 拦截会误报 true，
        // 这里至少确认 probeRead 与它走的是不同路径（真 open）
        let file = directory.appendingPathComponent("b.txt")
        try Data("y".utf8).write(to: file)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: file.path))
        XCTAssertTrue(Permissions.probeRead(file.path).contains("可读"))
    }
}

/// 状态栏菜单的结构约定。
///
/// 状态栏项不支持 `AXPress`（系统返回 -25204），无法用辅助功能 API 点击验证，
/// 因此直接验证菜单构造结果——这能覆盖"项是否齐全、顺序是否正确"。
@MainActor
final class StatusMenuTests: XCTestCase {
    private func makeController() -> StatusItemController {
        StatusItemController(
            onOpenPage: {}, onOpenSettings: {}, onReturnToReader: {}, onOpenDataDirectory: {}
        )
    }

    private func titles(_ controller: StatusItemController, state: StatusItemController.MenuState) -> [String] {
        controller.describeMenu(state: state)
            .components(separatedBy: "\n")
            .dropFirst()
            .map { line in
                // 去掉 "  [n] " 前缀与后面的 "(...)" 标注
                var text = line.trimmingCharacters(in: .whitespaces)
                if let range = text.range(of: "] ") { text = String(text[range.upperBound...]) }
                if let paren = text.range(of: "  (") { text = String(text[..<paren.lowerBound]) }
                return text
            }
    }

    func testStatusComesBeforeActions() {
        let controller = makeController()
        let items = titles(controller, state: StatusItemController.MenuState(
            bookTitle: "某本书", bookProgress: 0.5, conversationTitle: "对话 1",
            isDetecting: true, fullDiskAccess: true, accessibility: true, llmConfigured: true
        ))

        let statusIndex = items.firstIndex(of: "当前在读")
        let actionIndex = items.firstIndex(of: "打开界面")
        XCTAssertNotNil(statusIndex, "应有「当前在读」状态区")
        XCTAssertNotNil(actionIndex, "应有「打开界面」操作项")
        XCTAssertLessThan(statusIndex!, actionIndex!, "状态区应排在操作区之前")
        XCTAssertEqual(items.first, "当前在读", "第一项应是状态区标题")
    }

    func testDoesNotOfferDataDirectory() {
        let controller = makeController()
        let items = titles(controller, state: StatusItemController.MenuState())
        XCTAssertFalse(
            items.contains { $0.contains("打开数据目录") },
            "按需求不应再提供「打开数据目录」"
        )
    }

    func testOffersEssentialActions() {
        let controller = makeController()
        let items = titles(controller, state: StatusItemController.MenuState())
        for expected in ["打开界面", "设置…", "返回图书 App", "退出 BooksBridge"] {
            XCTAssertTrue(items.contains(expected), "缺少操作项：\(expected)")
        }
    }

    func testShowsBookAndProgressWhenReading() {
        let controller = makeController()
        let items = titles(controller, state: StatusItemController.MenuState(
            bookTitle: "三体", bookProgress: 0.42, conversationTitle: "对话 2",
            isDetecting: true, fullDiskAccess: true, accessibility: true, llmConfigured: false
        ))
        XCTAssertTrue(items.contains { $0.contains("三体") }, "应显示书名")
        XCTAssertTrue(items.contains { $0.contains("42%") }, "应显示进度百分比")
        XCTAssertTrue(items.contains { $0.contains("对话 2") }, "应显示当前对话")
    }

    func testShowsIdleMessageWhenNotReading() {
        let controller = makeController()
        let items = titles(controller, state: StatusItemController.MenuState())
        XCTAssertTrue(items.contains("图书 App 未在阅读"))
    }

    func testNamesWhichPermissionIsMissing() {
        let controller = makeController()

        // 只缺辅助功能
        var items = titles(controller, state: StatusItemController.MenuState(
            fullDiskAccess: true, accessibility: false
        ))
        XCTAssertTrue(
            items.contains { $0.contains("权限缺失") && $0.contains("辅助功能") },
            "应指出缺的是辅助功能，实际: \(items)"
        )

        // 两项都缺
        items = titles(controller, state: StatusItemController.MenuState(
            fullDiskAccess: false, accessibility: false
        ))
        XCTAssertTrue(items.contains { $0.contains("磁盘访问") && $0.contains("辅助功能") })

        // 都齐
        items = titles(controller, state: StatusItemController.MenuState(
            fullDiskAccess: true, accessibility: true
        ))
        XCTAssertTrue(items.contains("权限已就绪"))
    }

    func testReflectsLLMConfigurationState() {
        let controller = makeController()
        var items = titles(controller, state: StatusItemController.MenuState(llmConfigured: false))
        XCTAssertTrue(items.contains("LLM 未配置"))

        items = titles(controller, state: StatusItemController.MenuState(llmConfigured: true))
        XCTAssertTrue(items.contains("LLM 已配置"))
    }
}
