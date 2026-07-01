import Foundation
import SQLite3
import usageBarCore

/// Hermes Agent provider（纯本地，SQLite）
///
/// Hermes Agent（NousResearch）是自进化 CLI agent（"The agent that grows with you"）。
/// 数据源：`~/.hermes/state.db`（或 `$HERMES_HOME/state.db`），SQLite。
///   - 表 `sessions`，**按 session 聚合**（每行一个 session 的 token 汇总，非逐条 LLM 调用）
///   - 字段：input_tokens / output_tokens / cache_read_tokens / cache_write_tokens /
///           reasoning_tokens / started_at(秒,float) / model / actual_cost_usd / estimated_cost_usd
///
/// 实现参考 tokscale `crates/tokscale-core/src/sessions/hermes.rs`。
/// 与 Qoder IDE 同档：只读 SQLite，纯本地、不联网、精确（粒度按 session，对按日聚合够用）。
public struct HermesProvider: UsageProvider {
    public let id = "hermes"
    public let displayName = "Hermes Agent"
    public let iconSymbol = "wand.and.rays"
    public let brandColor = "#7C3AED"
    public var family: String? { nil }

    public init() {}

    private var dbPath: String {
        if let home = ProcessInfo.processInfo.environment["HERMES_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("state.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/state.db").path
    }

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let path = dbPath
        // 合并 db + db-wal 元数据做 cache key（WAL 模式主 db mtime 不刷新，同 QoderIde）
        guard let meta = sqliteMetadataWithWAL(dbPath: path) else { return [] }

        if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
            return entry.records
        }
        let records = (try? parseDB(path: path)) ?? []
        let entry = FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records)
        await FileMtimeCache.shared.store(entry)
        return records
    }

    private func sqliteMetadataWithWAL(dbPath: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: dbPath) else { return nil }
        let wal = FileMetadata.read(at: dbPath + "-wal")
        let mtime = max(db.mtime, wal?.mtime ?? Date.distantPast)
        let size = db.size + (wal?.size ?? 0)
        return (mtime, size)
    }

    /// 读 sessions 表，按 started_at 日聚合 token。
    private func parseDB(path: String) throws -> [FileDailyRecord] {
        let uri = "file:\(path)?mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
          FROM sessions
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var dailyTotals: [String: Int] = [:]
        var dailyCached: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            // started_at 是秒（float）；tokscale: >1e12 视为毫秒，否则秒
            let startedAt = sqlite3_column_double(stmt, 0)
            let input = Int(sqlite3_column_int64(stmt, 1))
            let output = Int(sqlite3_column_int64(stmt, 2))
            let cacheRead = Int(sqlite3_column_int64(stmt, 3))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 4))
            let total = input + output + cacheRead + cacheWrite
            if total == 0 { continue }

            let seconds = startedAt > 1_000_000_000_000 ? startedAt / 1000.0 : startedAt
            let date = DailyAggregator.dateString(for: Date(timeIntervalSince1970: seconds))
            dailyTotals[date, default: 0] += total
            dailyCached[date, default: 0] += cacheRead   // 浅色：仅命中读取（cache_write 归深色）
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }
}
