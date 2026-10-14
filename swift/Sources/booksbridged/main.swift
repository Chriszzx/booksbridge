import BooksBridgeCore
import Foundation

// ─────────────────────────────────────────────────────────────
// booksbridged —— 工程骨架的命令行驱动
//
// 用途：在没有 UI 的情况下验证各层是否工作，并演示"实时跟随"。
// 用法：
//   booksbridged                显示当前状态（权限 / 当前书 / 位置 / 正文）
//   booksbridged --permissions  只检查权限
//   booksbridged --list         列出最近在读的书
//   booksbridged --watch        实时跟随翻页（Ctrl-C 退出）
// ─────────────────────────────────────────────────────────────

let arguments = Set(CommandLine.arguments.dropFirst())

func printHeader(_ text: String) {
    print("\n\u{001B}[1m\(text)\u{001B}[0m")
    print(String(repeating: "─", count: 64))
}

// MARK: - 权限

let paths = BooksPaths()
let permissions = Permissions(paths: paths)

@MainActor
func reportPermissions() -> Bool {
    printHeader("权限状态")
    var allGood = true
    for (permission, status) in permissions.allStatuses() {
        let mark = status.isGranted ? "✅" : "❌"
        print("\(mark) \(permission.title)：\(status.label)")
        if !status.isGranted {
            allGood = false
            print("   用途：\(permission.reason)")
            print("   授权：系统设置 → 隐私与安全性 → \(permission.title)")
        }
    }
    return allGood
}

if arguments.contains("--permissions") {
    _ = reportPermissions()
    exit(0)
}

// MARK: - 最近在读

let store = BooksStore(paths: paths)

if arguments.contains("--list") {
    printHeader("最近在读")
    guard let books = try? store.recentBooks(limit: 15) else {
        print("读取书库失败（检查完全磁盘访问权限）")
        exit(1)
    }
    for (index, book) in books.enumerated() {
        let progress = String(format: "%5.1f%%", book.progress * 100)
        print(String(format: "%2d. %@ [%@ %@]", index + 1, book.displayTitle, book.contentType.label, progress))
    }
    exit(0)
}

// MARK: - 划选调试

if arguments.contains("--debug-selection") {
    printHeader("划选监测")
    print("请在图书 App 里划选一段文字（保持 3 秒）。Ctrl-C 退出。\n")
    let reader = AccessibilityReader()
    var lastSignature = ""
    while true {
        if let snapshot = try? reader.snapshot(), let selection = snapshot.selection {
            let signature = "\(selection)|\(snapshot.selectionRange?.location ?? -1)|\(snapshot.selectionFrame?.origin.x ?? -1)"
            if signature != lastSignature {
                lastSignature = signature
                let stamp = DateFormatter()
                stamp.dateFormat = "HH:mm:ss"
                print("[\(stamp.string(from: Date()))] 划选变化")
                print("  AXSelectedText      : \(selection.prefix(120))")
                if let node = snapshot.selectionNodeText {
                    print("  所在节点全文 (\(node.count) 字) : \(node.prefix(120))")
                }
                if let range = snapshot.selectionRange {
                    print("  AXSelectedTextRange : location=\(range.location) length=\(range.length)")
                    print("  → 精确划选片段      : \(snapshot.preciseSelection?.prefix(120) ?? "无法切分")")
                } else {
                    print("  AXSelectedTextRange : (Books 未上报，只能拿到整段)")
                }
                if let frame = snapshot.selectionFrame {
                    print("  屏幕矩形 (Cocoa)    : x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))")
                } else {
                    print("  屏幕矩形            : (无)")
                }
                print()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
}

// MARK: - 单次状态

let permissionsOK = reportPermissions()

@MainActor
func describe(_ context: ReadingContext, chapter: (href: String, text: String)?) {
    let book = context.book
    printHeader("当前在读")
    print("书名    ：\(book.displayTitle)\(book.displayAuthor.map { " — \($0)" } ?? "")")
    print("类型    ：\(book.contentType.label)    进度：\(String(format: "%.1f%%", book.progress * 100))")

    if let position = context.position {
        print("位置    ：\(position.raw)")
        if let updated = position.updated {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            print("更新于  ：\(formatter.string(from: updated))")
        }
    } else {
        print("位置    ：（无记录）")
    }

    if let chapter {
        print("章节    ：\(chapter.href)（\(chapter.text.count) 字）")
    }

    if let selection = context.selection {
        printHeader("你的划选")
        print(selection)
    }

    if !context.visibleText.isEmpty {
        printHeader("屏幕可见正文（\(context.visibleText.count) 段，来自辅助功能 API）")
        for line in context.visibleText.prefix(6) {
            print("  · \(line.prefix(100))")
        }
    } else {
        print("\n（未读到屏幕正文：可能不在阅读视图，或缺少辅助功能权限）")
    }

    if let chapter {
        printHeader("章节正文开头（可作为 LLM 上下文）")
        print(String(chapter.text.prefix(500)))
    }
    print()
}

let coordinator = ReadingCoordinator(paths: paths)

if arguments.contains("--watch") {
    printHeader("实时跟随已启动")
    print("请在图书 App 里翻页。Ctrl-C 退出。\n")

    coordinator.onIssue = { message in
        FileHandle.standardError.write(Data("⚠️  \(message)\n".utf8))
    }
    coordinator.onUpdate = { context in
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        let time = stamp.string(from: context.capturedAt)
        let cfi = context.position?.cfi ?? context.position?.raw ?? "-"
        let visible = context.visibleText.count
        print("[\(time)] 《\(context.book.title)》 \(String(format: "%.1f%%", context.book.progress * 100))  CFI=\(cfi)  可见段落=\(visible)")
        if let first = context.visibleText.first {
            print("          \(first.prefix(80))")
        }
    }
    coordinator.start()

    // CLI 场景：常驻运行，靠信号退出
    dispatchMain()
}

// 单次模式
guard permissionsOK else {
    print("\n提示：先授予上述权限，再重新运行。")
    exit(1)
}

guard let context = coordinator.makeContext() else {
    print("\n✗ 采集不到阅读上下文（原因见上方提示）")
    exit(1)
}

describe(context, chapter: coordinator.currentChapterText(context: context))
