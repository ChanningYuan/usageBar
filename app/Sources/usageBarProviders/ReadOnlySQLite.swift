import Foundation
import SQLite3

/// 只读查询第三方 App 的 SQLite 库（v0.3.48）。
///
/// WAL 模式的库要靠 App 运行时留下的 `-shm` 才能按普通只读（`mode=ro`）打开；App 一关，`-shm` 没了，
/// 准备语句就报「unable to open database file」。以前读 Qoder IDE 时把这种情况当成空库：IDE 一关，
/// 下一轮刷新把它的主列表清成 0，详情页却还有数（2026-10-19 发 0.3.48 自检时发现）。
///
/// 现在先按普通只读查（App 开着时能看到 WAL 里最新的写入），打不开再按 `immutable=1` 读文件现状——
/// App 关着时库不会再变，读出来就是完整的（千问办公库 10-16 实测同一办法）。
enum ReadOnlySQLite {
    /// 逐行回调。两种方式都打不开返回 false（调用方应保留上次的数，别当成空库）。
    @discardableResult
    static func query(path: String, sql: String, row: (OpaquePointer) -> Void) -> Bool {
        for uri in ["file:\(path)?mode=ro", "file:\(path)?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                continue
            }
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW || rc == SQLITE_DONE else { continue }   // 第一步就失败：换方式重来
            while rc == SQLITE_ROW {
                row(stmt)
                rc = sqlite3_step(stmt)
            }
            return true
        }
        return false
    }
}
