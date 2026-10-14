import XCTest

@testable import BooksBridgeCore

/// 验证 `FileWatcher` 的监听与合并机制。
///
/// 用临时文件而不是图书 App 的真实数据库：
/// 既能确定性地验证行为，又不会去写别人的数据库。
final class FileWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("booksbridge-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForExpectation(_ expectation: XCTestExpectation, timeout: TimeInterval = 3) {
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "等待回调超时")
    }

    func testFiresOnFileWrite() throws {
        let file = directory.appendingPathComponent("data.sqlite-wal")
        try Data("initial".utf8).write(to: file)

        let fired = expectation(description: "写入触发回调")
        // debounce 调小，让测试跑得快
        let watcher = FileWatcher(files: [file], debounce: 0.05) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // 给 DispatchSource 一点时间完成注册
        Thread.sleep(forTimeInterval: 0.2)
        try Data("changed".utf8).write(to: file)

        waitForExpectation(fired)
    }

    func testCoalescesRapidWritesIntoSingleCallback() throws {
        let file = directory.appendingPathComponent("data.sqlite-wal")
        try Data("initial".utf8).write(to: file)

        let fired = expectation(description: "合并后只触发一次")
        // 期望恰好一次：既不能 0 次，也不能被 5 次写入打成 5 次
        fired.assertForOverFulfill = true

        let watcher = FileWatcher(files: [file], debounce: 0.2) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        for i in 0..<5 {
            try Data("change-\(i)".utf8).write(to: file)
            Thread.sleep(forTimeInterval: 0.01)
        }

        waitForExpectation(fired)
        // 再多等一会儿，确认没有第二次回调
        Thread.sleep(forTimeInterval: 0.4)
    }

    func testWatchesMultipleFiles() throws {
        let a = directory.appendingPathComponent("a.sqlite-wal")
        let b = directory.appendingPathComponent("b.sqlite-wal")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let first = expectation(description: "第一个文件")
        let second = expectation(description: "第二个文件")
        let counter = Counter()
        let watcher = FileWatcher(files: [a, b], debounce: 0.05) {
            let n = counter.increment()
            if n == 1 { first.fulfill() } else { second.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        try Data("a2".utf8).write(to: a)
        waitForExpectation(first)

        Thread.sleep(forTimeInterval: 0.2)
        try Data("b2".utf8).write(to: b)
        waitForExpectation(second)
    }

    func testMissingFileDoesNotPreventWatch() throws {
        // 场景：用户从未标注过，AEAnnotation 数据库还不存在
        let file = directory.appendingPathComponent("not-yet-created.sqlite-wal")

        let fired = expectation(description: "文件出现后能被监听到")
        let watcher = FileWatcher(files: [file], debounce: 0.05) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        // 先让文件出现（父目录监听应把它接上），再写入
        try Data("created".utf8).write(to: file)
        Thread.sleep(forTimeInterval: 0.4)
        try Data("created-and-changed".utf8).write(to: file)

        waitForExpectation(fired, timeout: 5)
    }

    func testStopPreventsFurtherCallbacks() throws {
        let file = directory.appendingPathComponent("data.sqlite-wal")
        try Data("initial".utf8).write(to: file)

        let fired = expectation(description: "停止后不应再触发")
        fired.isInverted = true

        let watcher = FileWatcher(files: [file], debounce: 0.05) { fired.fulfill() }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()

        try Data("after-stop".utf8).write(to: file)
        wait(for: [fired], timeout: 0.6)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
