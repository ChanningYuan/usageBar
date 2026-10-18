import XCTest
import SQLite3
@testable import usageBarProviders

/// 第三方 App 关掉后，它的 WAL 库按普通只读打不开（v0.3.48 发版自检时 Qoder IDE 主列表被清成 0）。
final class ReadOnlySQLiteTests: XCTestCase {
    func testReadsWALDatabaseAfterOwnerAppQuit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ro-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("local.db").path

        // 模拟 App：WAL 模式写入后关库。Qoder IDE 退出后目录里只剩主库文件（10-19 实测），这里照样删掉 -wal / -shm
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        for sql in ["PRAGMA journal_mode=WAL", "CREATE TABLE chat_message(gmt_create INTEGER, token_info TEXT)",
                    "INSERT INTO chat_message VALUES (1782354000000, '{\"prompt_tokens\":10}')"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }

        // 旧读法：普通只读，准备语句就失败
        var plain: OpaquePointer?
        sqlite3_open_v2("file:\(path)?mode=ro", &plain, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        var stmt: OpaquePointer?
        XCTAssertNotEqual(sqlite3_prepare_v2(plain, "SELECT * FROM chat_message", -1, &stmt, nil), SQLITE_OK,
                          "这条断言不成立说明系统 SQLite 行为变了，回退分支可能已不需要")
        sqlite3_finalize(stmt)
        sqlite3_close(plain)

        var rows = 0
        XCTAssertTrue(ReadOnlySQLite.query(path: path, sql: "SELECT gmt_create FROM chat_message") { _ in rows += 1 })
        XCTAssertEqual(rows, 1, "App 关着时按快照方式读出完整数据")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"), "只读：不能在别人的库旁边留文件")
    }

    func testMissingDatabaseReportsFailure() {
        XCTAssertFalse(ReadOnlySQLite.query(path: "/nonexistent/\(UUID().uuidString).db", sql: "SELECT 1") { _ in })
    }
}
