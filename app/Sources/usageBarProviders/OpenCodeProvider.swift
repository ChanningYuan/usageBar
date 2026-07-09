import Foundation
import SQLite3
import usageBarCore

public struct OpenCodeProvider: UsageProvider {
    public let id = "opencode"
    public let displayName = "OpenCode"
    public let iconSymbol = "hammer.fill"
    public let brandColor = "#F59E0B"
    public var family: String? { nil }

    public init() {}

    private var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let path = dbPath
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
        SELECT time_created, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write
          FROM session
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
            let timeCreated = sqlite3_column_int64(stmt, 0)
            let input = Int(sqlite3_column_int64(stmt, 1))
            let output = Int(sqlite3_column_int64(stmt, 2))
            let cacheRead = Int(sqlite3_column_int64(stmt, 3))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 4))
            let total = input + output + cacheRead + cacheWrite
            if total == 0 { continue }

            let seconds = Double(timeCreated) / 1000.0
            let date = DailyAggregator.dateString(for: Date(timeIntervalSince1970: seconds))
            dailyTotals[date, default: 0] += total
            dailyCached[date, default: 0] += cacheRead
        }

        return dailyTotals.map { (date, token) in
            FileDailyRecord(provider: id, date: date, token: token, cachedToken: dailyCached[date] ?? 0)
        }
    }
}
