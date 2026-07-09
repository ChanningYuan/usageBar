import Foundation
import SQLite3
import usageBarCore

public actor OpenCodeDetailScanner {
    public static let shared = OpenCodeDetailScanner()
    public init() {}

    private struct CacheSnapshot {
        let mtime: Date
        let size: Int
        let sessions: [SessionRow]
    }

    private struct SessionRow {
        let id: String
        let title: String
        let modelId: String
        let date: String
        let lastActivity: Date
        let tokens: TokenBreakdown
        let cost: Double
    }

    private var cache: CacheSnapshot?

    public func detail(window: TimeWindow, weekStartMonday: Bool = true,
                       now: Date = Date()) async -> ProviderDetail {
        let rows = loadRows()
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        let filtered = rows.filter { inWindow($0.date) }

        var totalTokens = TokenBreakdown()
        var totalCost = 0.0

        var bySession: [String: (tokens: TokenBreakdown, cost: Double, title: String, lastActivity: Date)] = [:]
        var byModel: [String: (tokens: TokenBreakdown, cost: Double)] = [:]

        for row in filtered {
            totalTokens.add(row.tokens)
            totalCost += row.cost

            if var s = bySession[row.id] {
                s.tokens.add(row.tokens)
                s.cost += row.cost
                s.lastActivity = max(s.lastActivity, row.lastActivity)
                bySession[row.id] = s
            } else {
                bySession[row.id] = (row.tokens, row.cost, row.title, row.lastActivity)
            }

            if var m = byModel[row.modelId] {
                m.tokens.add(row.tokens)
                m.cost += row.cost
                byModel[row.modelId] = m
            } else {
                byModel[row.modelId] = (row.tokens, row.cost)
            }
        }

        let sessions = bySession.map { (sid, val) in
            SessionDetailRecord(
                sessionId: sid,
                title: val.title.isEmpty ? String(sid.prefix(12)) : val.title,
                subtitle: String(sid.prefix(8)),
                lastActivity: val.lastActivity,
                tokens: val.tokens,
                cost: val.cost
            )
        }.sorted { $0.tokens.total > $1.tokens.total }

        let models = byModel.map { (mid, val) in
            ModelDetailRecord(
                modelId: mid,
                displayName: friendlyModelName(mid),
                tokens: val.tokens,
                cost: val.cost
            )
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(
            providerId: "opencode",
            windowId: window.id,
            tokens: totalTokens,
            cost: totalCost,
            models: models,
            sessions: sessions
        )
    }

    private func loadRows() -> [SessionRow] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path

        guard let meta = sqliteMetadataWithWAL(dbPath: path) else { return [] }

        if let c = cache, c.mtime == meta.mtime, c.size == meta.size {
            return c.sessions
        }

        let rows = parseDB(path: path)
        cache = CacheSnapshot(mtime: meta.mtime, size: meta.size, sessions: rows)
        return rows
    }

    private func sqliteMetadataWithWAL(dbPath: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: dbPath) else { return nil }
        let wal = FileMetadata.read(at: dbPath + "-wal")
        let mtime = max(db.mtime, wal?.mtime ?? Date.distantPast)
        let size = db.size + (wal?.size ?? 0)
        return (mtime, size)
    }

    private func parseDB(path: String) -> [SessionRow] {
        let uri = "file:\(path)?mode=ro"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, title, model, time_created, time_updated,
               tokens_input, tokens_output, tokens_cache_read, tokens_cache_write,
               tokens_reasoning, cost
          FROM session
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let titleRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let modelJson = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let timeCreated = sqlite3_column_int64(stmt, 3)
            let timeUpdated = sqlite3_column_int64(stmt, 4)
            let input = Int(sqlite3_column_int64(stmt, 5))
            let output = Int(sqlite3_column_int64(stmt, 6))
            let cacheRead = Int(sqlite3_column_int64(stmt, 7))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 8))
            let reasoning = Int(sqlite3_column_int64(stmt, 9))
            let cost = sqlite3_column_double(stmt, 10)

            let total = input + output + cacheRead + cacheWrite
            if total == 0 { continue }

            let modelId = parseModelId(modelJson)
            let seconds = Double(timeCreated) / 1000.0
            let date = DailyAggregator.dateString(for: Date(timeIntervalSince1970: seconds))
            let lastActivity = Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0)

            let tokens = TokenBreakdown(
                input: input,
                output: output,
                cacheCreate5m: cacheWrite,
                cacheCreate1h: 0,
                cacheRead: cacheRead,
                reasoning: reasoning
            )

            rows.append(SessionRow(
                id: id, title: titleRaw, modelId: modelId,
                date: date, lastActivity: lastActivity,
                tokens: tokens, cost: cost
            ))
        }
        return rows
    }

    private func parseModelId(_ json: String) -> String {
        // model column is JSON like {"id":"glm-5.2","providerID":"alibaba-cn"}
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            return json.isEmpty ? "unknown" : json
        }
        return id
    }

    private func friendlyModelName(_ modelId: String) -> String {
        modelId.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
