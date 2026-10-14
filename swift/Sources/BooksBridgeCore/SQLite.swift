import CSQLite
import Foundation

/// SQLite 错误的统一表示。
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let context: String

    public var description: String {
        "SQLiteError(\(code)) \(context): \(message)"
    }
}

/// `sqlite3` 的极薄封装。
///
/// 设计约束：
/// - **只读**打开（`SQLITE_OPEN_READONLY`），绝不写入他人的数据库；
/// - 不持有连接，`query` 一次性完成取数后即释放；
/// - 不缓存，因为图书 App 会持续改写 WAL，缓存会读到陈旧数据。
public enum SQLite {
    /// 以只读方式执行查询，把每一行映射为字典数组。
    ///
    /// - Parameters:
    ///   - path: 数据库文件路径。
    ///   - sql: 查询语句。
    ///   - bindings: 按顺序绑定的参数（支持 String / Int / Double / nil）。
    public static func query(
        path: String,
        _ sql: String,
        _ bindings: [Any?] = []
    ) throws -> [[String: Any]] {
        var db: OpaquePointer?
        // immutable=1 让 sqlite 不尝试创建 -journal/-shm；配合只读标志可最大程度避免副作用。
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX

        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: -1, message: msg, context: "open \(path)")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db)),
                context: "prepare"
            )
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil:
                sqlite3_bind_null(stmt, idx)
            case let v as String:
                sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            default:
                sqlite3_bind_text(stmt, idx, String(describing: value!), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }

        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError(
                    code: sqlite3_errcode(db),
                    message: String(cString: sqlite3_errmsg(db)),
                    context: "step"
                )
            }
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_NULL:
                    row[name] = nil
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c) {
                        row[name] = Data(bytes: p, count: n)
                    } else {
                        row[name] = nil
                    }
                default:
                    if let p = sqlite3_column_text(stmt, c) {
                        row[name] = String(cString: p)
                    } else {
                        row[name] = nil
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }
}
