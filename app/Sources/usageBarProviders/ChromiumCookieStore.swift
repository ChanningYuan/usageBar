import CryptoKit
import Foundation
import SQLite3

/// Chromium 系 cookie 库（`Cookies` SQLite）的通用只读访问。
///
/// v0.3.45 从 `ChromeCookieReader` 抽出：千问办公读 Chrome 里的一条 `token`，豆包工作读 DoubaoWork 自带
/// Chromium 壳里 doubao.com 的整套登录 cookie——库结构与加密方式完全一样，只是库路径和钥匙串条目不同。
///
/// - 库文件在浏览器运行时被锁着，**先拷到临时目录再只读打开**（连同 `-journal` / `-wal`）。
/// - 值是 `v10` + AES-128-CBC，密钥由各自的「Safe Storage」钥匙串密码派生（`QoderRateLimitReader.deriveKey`）。
/// - ⚠️ Chromium 130 起（cookie 库 `meta.version` ≥ 24）明文前面多 32 字节 SHA256(host_key)。
///   `value(of:key:)` 按这一行自己的 host_key **精确比对**后再剥，不靠「剥了能不能解码」去猜。
enum ChromiumCookieStore {
    struct Row: Sendable, Equatable {
        let host: String
        let name: String
        let encrypted: Data
        /// 明文列（老版本或未加密的 cookie 才有值，Chromium 现在基本都走 encrypted_value）
        let plain: String
        /// Chromium 时间：1601-01-01 起的微秒数；0 = 会话 cookie（浏览器关掉即失效，但库里仍有效）
        let expiresUTC: Int64
    }

    /// 拷贝到临时目录后只读查询 `cookies` 表，按过期时间倒序返回。
    ///
    /// - Parameters:
    ///   - hostLike: SQL `LIKE` 模式，如 `%doubao.com`
    ///   - name: 只取这一个 cookie 名；nil = 该域下全部
    static func rows(in database: URL, hostLike: String, name: String? = nil) -> [Row] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("usagebar-cookies-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("Cookies")
        guard (try? fm.copyItem(at: database, to: copy)) != nil else { return [] }
        for suffix in ["-journal", "-wal"] {
            let side = URL(fileURLWithPath: database.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(copy.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        var sql = "SELECT host_key, name, encrypted_value, value, expires_utc FROM cookies WHERE host_key LIKE ?1"
        if name != nil { sql += " AND name = ?2" }
        sql += " ORDER BY expires_utc DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT：让 SQLite 自己拷一份字符串，Swift 的临时缓冲区出了作用域就失效
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, hostLike, -1, transient)
        if let name { sqlite3_bind_text(stmt, 2, name, -1, transient) }

        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let cookieName = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            var encrypted = Data()
            if let bytes = sqlite3_column_blob(stmt, 2) {
                encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            let plain = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            out.append(Row(host: host, name: cookieName, encrypted: encrypted, plain: plain,
                           expiresUTC: sqlite3_column_int64(stmt, 4)))
        }
        return out
    }

    /// 解出一条 cookie 的值：明文列有值直接用；否则 `v10` 解密，再按 host_key 剥掉 32 字节哈希前缀。
    static func value(of row: Row, key: Data) -> String? {
        if !row.plain.isEmpty { return row.plain }
        guard row.encrypted.count > 3, String(data: row.encrypted.prefix(3), encoding: .ascii) == "v10",
              var plain = QoderRateLimitReader.decrypt(row.encrypted, key: key) else { return nil }
        if plain.count >= 32, plain.prefix(32) == Data(SHA256.hash(data: Data(row.host.utf8))) {
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    /// Chromium 时间（1601 起的微秒）是否已过期。0 = 会话 cookie，视为有效。
    static func isExpired(_ row: Row, now: Date = Date()) -> Bool {
        guard row.expiresUTC > 0 else { return false }
        // 1601-01-01 到 1970-01-01 相差 11_644_473_600 秒
        let unix = Double(row.expiresUTC) / 1_000_000 - 11_644_473_600
        return unix < now.timeIntervalSince1970
    }
}
