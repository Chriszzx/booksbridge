import Foundation

/// 读取 Apple Books 数据文件的门面。
///
/// 所有方法都是"开库 → 查询 → 关库"的一次性操作，不缓存连接。
/// 原因：图书 App 在阅读过程中会持续改写 WAL，长连接或缓存会读到陈旧数据。
public struct BooksStore: Sendable {
    public let paths: BooksPaths

    public init(paths: BooksPaths = BooksPaths()) {
        self.paths = paths
    }

    // MARK: - 当前在读书

    /// 图书 App 把"当前正在读的书"的 assetID 记在容器偏好设置里，键名 `kLastCurrentBookKey`。
    ///
    /// 坑：这个 plist 里可能存在越界日期字段，会让 `PropertyListSerialization` 整体解析失败。
    /// 因此准备了三级降级：plist 解析 → `plutil` 单键提取 → 二进制裸扫描。
    public func currentAssetID() -> String? {
        let url = paths.preferences
        guard let data = try? Data(contentsOf: url) else { return nil }

        // 1) 首选标准 plist 解析
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = plist as? [String: Any],
           let value = dict["kLastCurrentBookKey"] as? String,
           !value.isEmpty {
            return value
        }

        // 2) 降级：只提取这一个键，绕过坏字段
        if let value = extractViaPlutil(key: "kLastCurrentBookKey", from: url), !value.isEmpty {
            return value
        }

        // 3) 兜底：在二进制 plist 里找键名后面的 32 位十六进制串
        return scanBinaryPlistForAssetID(data: data, key: "kLastCurrentBookKey")
    }

    private func extractViaPlutil(key: String, from url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-extract", key, "raw", "-o", "-", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func scanBinaryPlistForAssetID(data: Data, key: String) -> String? {
        guard let keyData = key.data(using: .ascii),
              let range = data.range(of: keyData) else { return nil }
        let tail = data[range.upperBound...].prefix(48)
        // assetID 是 32 位十六进制（部分书籍会更长）
        let pattern = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{16,}")
        let ns = String(decoding: tail, as: UTF8.self) as NSString
        return pattern?.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - 书籍元数据

    public func allBooks() throws -> [Book] {
        guard let db = paths.libraryDatabase() else { return [] }
        return try SQLite.query(path: db.path, """
            SELECT ZASSETID, ZTITLE, ZAUTHOR, ZREADINGPROGRESS, ZCONTENTTYPE, ZPATH, ZLASTOPENDATE
            FROM ZBKLIBRARYASSET
            """).compactMap(Self.makeBook)
    }

    public func book(assetID: String) throws -> Book? {
        guard let db = paths.libraryDatabase() else { return nil }
        let rows = try SQLite.query(
            path: db.path,
            """
            SELECT ZASSETID, ZTITLE, ZAUTHOR, ZREADINGPROGRESS, ZCONTENTTYPE, ZPATH, ZLASTOPENDATE
            FROM ZBKLIBRARYASSET WHERE ZASSETID = ?
            """,
            [assetID]
        )
        return rows.first.flatMap(Self.makeBook)
    }

    /// Match a live window without depending on the delayed last-opened timestamp.
    public func books(titled title: String) throws -> [Book] {
        guard let db = paths.libraryDatabase() else { return [] }
        return try SQLite.query(path: db.path, """
            SELECT ZASSETID, ZTITLE, ZAUTHOR, ZREADINGPROGRESS, ZCONTENTTYPE, ZPATH, ZLASTOPENDATE
            FROM ZBKLIBRARYASSET WHERE ZTITLE = ?
            """, [title]).compactMap(Self.makeBook)
    }

    /// 最近打开过的书，按最后打开时间倒序。
    public func recentBooks(limit: Int = 15) throws -> [Book] {
        guard let db = paths.libraryDatabase() else { return [] }
        let rows = try SQLite.query(
            path: db.path,
            """
            SELECT ZASSETID, ZTITLE, ZAUTHOR, ZREADINGPROGRESS, ZCONTENTTYPE, ZPATH, ZLASTOPENDATE
            FROM ZBKLIBRARYASSET WHERE ZLASTOPENDATE IS NOT NULL
            ORDER BY ZLASTOPENDATE DESC LIMIT ?
            """,
            [limit]
        )
        return rows.compactMap(Self.makeBook)
    }

    private static func makeBook(_ row: [String: Any]) -> Book? {
        guard let assetID = row["ZASSETID"] as? String else { return nil }
        return Book(
            assetID: assetID,
            title: (row["ZTITLE"] as? String) ?? "(无标题)",
            author: (row["ZAUTHOR"] as? String) ?? "",
            progress: (row["ZREADINGPROGRESS"] as? Double) ?? 0,
            contentType: BookContentType(rawValue: Int((row["ZCONTENTTYPE"] as? Int64) ?? 1)) ?? .epub,
            path: row["ZPATH"] as? String,
            lastOpened: (row["ZLASTOPENDATE"] as? Double).map(Self.date(fromAppleEpoch:))
        )
    }

    // MARK: - 阅读位置

    /// 读取当前阅读位置。
    ///
    /// `ZANNOTATIONTYPE = 3` 是图书 App 自动写入的位置标记；
    /// 每本书只有一条并原地更新，所以取最新一条即为当前位置。
    public func readingPosition(assetID: String) throws -> ReadingPosition? {
        guard let db = paths.annotationDatabase() else { return nil }
        let rows = try SQLite.query(
            path: db.path,
            """
            SELECT ZANNOTATIONLOCATION, ZANNOTATIONMODIFICATIONDATE,
                   ZANNOTATIONSELECTEDTEXT
            FROM ZAEANNOTATION
            WHERE ZANNOTATIONASSETID = ? AND ZANNOTATIONTYPE = 3
              AND ZANNOTATIONLOCATION IS NOT NULL
            ORDER BY ZANNOTATIONMODIFICATIONDATE DESC LIMIT 1
            """,
            [assetID]
        )
        guard let row = rows.first,
              let raw = row["ZANNOTATIONLOCATION"] as? String else { return nil }

        let selected = (row["ZANNOTATIONSELECTEDTEXT"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ReadingPosition(
            kind: Self.classify(location: raw),
            raw: raw,
            updated: (row["ZANNOTATIONMODIFICATIONDATE"] as? Double).map(Self.date(fromAppleEpoch:)),
            selectedText: (selected?.isEmpty ?? true) ? nil : selected
        )
    }

    /// 把 `ZANNOTATIONLOCATION` 归类。
    ///
    /// EPUB 形如 `epubcfi(/6/22[chapter-10]!/4/146/1,:0,:1)`；
    /// PDF 则是一个纯数字页码。
    private static func classify(location: String) -> ReadingPosition.Kind {
        if location.hasPrefix("epubcfi(") {
            let inner = location
                .dropFirst("epubcfi(".count)
                .dropLast(location.hasSuffix(")") ? 1 : 0)
            return .epubCFI(String(inner))
        }
        if let page = Int(location.trimmingCharacters(in: .whitespaces)) {
            return .page(page)
        }
        return location.isEmpty ? .unknown : .other(location)
    }

    /// Core Data 的时间戳以 2001-01-01 为基准，需加 978307200 秒才是 Unix 时间。
    private static func date(fromAppleEpoch value: Double) -> Date {
        Date(timeIntervalSince1970: value + 978_307_200)
    }
}
