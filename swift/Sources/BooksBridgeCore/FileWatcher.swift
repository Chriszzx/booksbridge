import Foundation

/// 监听一组文件的变化，并在变化后合并触发回调。
///
/// 为什么用 `DispatchSource` 而不是 FSEvents：
/// - 图书 App 每次翻页都会改写 `.sqlite-wal`，这是**文件内容**变化，
///   `DispatchSource.makeFileSystemObjectSource` 的 `.write` 事件最直接；
/// - FSEvents 有合并延迟（默认 0.5~1s），而实测翻页是亚秒级，用它会引入额外延迟；
/// - FSEvents 监听目录也无法区分是哪一个文件被写。
///
/// 一个细节：SQLite 在 checkpoint 时可能**替换**而非改写文件（inode 变化），
/// 所以这里同时监听数据库文件本身与它的 `-wal`，并且在触发后重新挂载。
public final class FileWatcher: @unchecked Sendable {
    private let files: [URL]
    private let queue = DispatchQueue(label: "booksbridge.watcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var handlers: [Int32: DispatchSource.FileSystemEvent] = [:]
    private let onChange: @Sendable () -> Void

    /// 合并窗口：多个文件在同一瞬间被写入时，只触发一次回调。
    private let debounceInterval: TimeInterval
    private var pendingWorkItem: DispatchWorkItem?

    public init(files: [URL], debounce: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.files = files
        self.debounceInterval = debounce
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.attachAll()
        }
    }

    public func stop() {
        queue.sync {
            for source in sources { source.cancel() }
            sources.removeAll()
            handlers.removeAll()
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }

    private func attachAll() {
        for url in files {
            attach(url)
        }
    }

    private func attach(_ url: URL) {
        // 文件可能尚未创建（例如从未标注过），创建后由父目录监听兜底。
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            watchParentDirectory(of: url)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.sources.first(where: { $0.handle == fd }) else { return }
            let flags = source.data
            self.scheduleCallback()
            // 文件被替换或删除时，fd 已失效，需要重新挂载
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reattach(url)
            }
        }
        source.setCancelHandler { close(fd) }
        sources.append(source)
        source.resume()
    }

    private func reattach(_ url: URL) {
        // 让出当前队列栈后再重挂，避免在事件回调里 cancel 自身
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.sources.removeAll { source in
                let dead = source.data.contains(.delete) || source.data.contains(.rename)
                if dead { source.cancel() }
                return dead
            }
            self.attach(url)
        }
    }

    /// 目标文件还不存在时，监听其父目录，等文件出现后再转移过去。
    private func watchParentDirectory(of url: URL) {
        let parent = url.deletingLastPathComponent()
        let fd = open(parent.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                self.sources.removeAll { source in
                    if source.handle == fd { source.cancel(); return true }
                    return false
                }
                self.attach(url)
                self.scheduleCallback()
            }
        }
        source.setCancelHandler { close(fd) }
        sources.append(source)
        source.resume()
    }

    /// 合并短时间内的多次写入，避免一次翻页触发多轮查询。
    private func scheduleCallback() {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
