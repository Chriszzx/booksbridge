// returnprobe —— 验证"从我们的 App 切回图书 App"这个动作是否会破坏阅读位置。
//
// 需要回答的问题：
//   1. NSRunningApplication.activate() 能否可靠地把图书 App 唤到前台
//   2. 唤回之后，图书 App 的阅读位置（CFI）是否保持不变
//   3. ibooks:// URL 是否会改变图书 App 的当前书
//
// 用法：
//   returnprobe            只做 activate，报告位置前后是否一致
//   returnprobe --url      额外测试 ibooks:// 的行为

import AppKit
import Foundation

// MARK: - 读取图书 App 状态（直接查数据库，不依赖本包的其它模块）

let home = FileManager.default.homeDirectoryForCurrentUser
let container = home.appendingPathComponent("Library/Containers/com.apple.iBooksX/Data")
let prefsURL = container.appendingPathComponent("Library/Preferences/com.apple.iBooksX.plist")

func currentAssetID() -> String? {
    guard let data = try? Data(contentsOf: prefsURL) else { return nil }
    if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
       let dict = plist as? [String: Any],
       let value = dict["kLastCurrentBookKey"] as? String {
        return value
    }
    // 降级：二进制裸扫描
    guard let key = "kLastCurrentBookKey".data(using: .ascii),
          let range = data.range(of: key) else { return nil }
    let tail = data[range.upperBound...].prefix(48)
    let pattern = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{16,}")
    let ns = String(decoding: tail, as: UTF8.self) as NSString
    return pattern?.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
}

/// 读取阅读位置的原始字符串（不解析，只比较是否变化）
func rawReadingPosition(assetID: String) -> String? {
    let dir = container.appendingPathComponent("Documents/AEAnnotation")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ), let db = entries.first(where: { $0.pathExtension == "sqlite" }) else { return nil }

    // 用 sqlite3 命令行，避免在这里再引一遍 C 接口
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    let escaped = assetID.replacingOccurrences(of: "'", with: "''")
    process.arguments = [
        "file:\(db.path)?mode=ro",
        "SELECT ZANNOTATIONLOCATION FROM ZAEANNOTATION WHERE ZANNOTATIONASSETID='\(escaped)' AND ZANNOTATIONTYPE=3 ORDER BY ZANNOTATIONMODIFICATIONDATE DESC LIMIT 1;",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    } catch {
        return nil
    }
}

func booksApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iBooksX").first
}

func frontmostApp() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
}

// MARK: - 主流程

print("=== 切换前状态 ===")
let beforeAsset = currentAssetID()
let beforePosition = beforeAsset.flatMap(rawReadingPosition)
print("前台 App    : \(frontmostApp())")
print("当前书 ID   : \(beforeAsset ?? "-")")
print("阅读位置    : \(beforePosition ?? "-")")

guard let books = booksApp() else {
    print("\n✗ 图书 App 未运行，无法测试")
    exit(1)
}

print("\n=== 执行 activate（纯前台切换，不打开任何 URL）===")
let activated = books.activate(options: [.activateAllWindows])
print("activate 返回: \(activated)")
Thread.sleep(forTimeInterval: 1.5)

print("\n=== 切换后状态 ===")
let afterAsset = currentAssetID()
let afterPosition = afterAsset.flatMap(rawReadingPosition)
print("前台 App    : \(frontmostApp())")
print("当前书 ID   : \(afterAsset ?? "-")")
print("阅读位置    : \(afterPosition ?? "-")")

print("\n=== 判定 ===")
print("前台已切到图书 App : \(frontmostApp().contains("图书") || frontmostApp().lowercased().contains("books") ? "✅" : "❌ 当前是 \(frontmostApp())")")
print("当前书未变化       : \(beforeAsset == afterAsset ? "✅" : "❌ \(beforeAsset ?? "-") → \(afterAsset ?? "-")")")
print("阅读位置未变化     : \(beforePosition == afterPosition ? "✅" : "❌ \(beforePosition ?? "-") → \(afterPosition ?? "-")")")

if CommandLine.arguments.contains("--url") {
    print("\n=== 额外测试：ibooks:// 打开当前书 ===")
    if let asset = afterAsset, let url = URL(string: "ibooks://assetid/\(asset)") {
        print("尝试 URL: \(url.absoluteString)")
        let ok = NSWorkspace.shared.open(url)
        print("open 返回: \(ok)")
        Thread.sleep(forTimeInterval: 2.0)
        print("之后当前书: \(currentAssetID() ?? "-")")
        print("之后位置  : \(currentAssetID().flatMap(rawReadingPosition) ?? "-")")
    }
}
