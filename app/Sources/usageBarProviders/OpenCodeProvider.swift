import Foundation
import SQLite3
import usageBarCore

/// opencode 本地库直读共享层（provider 日报 + 明细页共用）。
///
/// 数据源 = `$XDG_DATA_HOME/opencode/opencode.db`（默认 `~/.local/share/opencode/`，SQLite WAL）：
///   - `message` 表每条 assistant 消息一行，`data` JSON 含 tokens/cost/modelID
///     （session 表的 tokens_* 聚合列就是从它 SUM 出来的，见 opencode 迁移
///     `20260510033149_session_usage`）。**读 message 才能按消息时间精确归因到天**——
///     session 表只有创建时间，跨天长会话会把后续天的用量全记在创建日。
///   - `session` 表只取 title / parent_id：subagent 子会话（parent_id 非空）沿
///     parent 链收敛到根会话，明细列表不散落子任务行。
enum OpenCodeDB {
    /// 单条 assistant 消息的用量行
    struct MessageRow: Sendable {
        let sessionId: String
        /// 本地日界串（按消息时间归因，非会话创建时间）
        let date: String
        let time: Date
        let modelId: String
        let tokens: TokenBreakdown
        let cost: Double
    }

    struct SessionInfo: Sendable {
        let title: String
        let parentId: String?
    }

    static var dbPath: String {
        // opencode 遵守 XDG 规范；GUI 场景拿不到 shell export 的变量时自然走默认值
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share")
        }
        return base.appendingPathComponent("opencode/opencode.db").path
    }

    /// WAL 库的 (mtime, size)：checkpoint 前主库文件可能不变，必须把 -wal 一起算
    static func metadata(dbPath: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: dbPath) else { return nil }
        let wal = FileMetadata.read(at: dbPath + "-wal")
        let mtime = max(db.mtime, wal?.mtime ?? Date.distantPast)
        let size = db.size + (wal?.size ?? 0)
        return (mtime, size)
    }

    /// 只读打开并解析全部 assistant 消息 + 会话映射。任何失败返回空（UI 显示 0，不崩）。
    static func load(dbPath: String) -> (messages: [MessageRow], sessions: [String: SessionInfo]) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return ([], [:])
        }
        defer { sqlite3_close(db) }
        return (loadMessages(db), loadSessions(db))
    }

    private static func loadMessages(_ db: OpaquePointer) -> [MessageRow] {
        let sql = """
        SELECT m.session_id, m.time_created,
               json_extract(m.data, '$.modelID'),
               json_extract(m.data, '$.tokens.input'),
               json_extract(m.data, '$.tokens.output'),
               json_extract(m.data, '$.tokens.reasoning'),
               json_extract(m.data, '$.tokens.cache.read'),
               json_extract(m.data, '$.tokens.cache.write'),
               json_extract(m.data, '$.cost')
          FROM message m
         WHERE json_extract(m.data, '$.role') = 'assistant'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [MessageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionId = text(stmt, 0) else { continue }
            // opencode 落库口径（getUsage）：input 已减 cache（净输入）；output 已减 reasoning。
            // app 统一口径是 reasoning ⊂ output（同 Codex），故 output 补回 reasoning，否则
            // 推理型模型的思考 token 会漏出 total。
            let reasoning = Int(sqlite3_column_int64(stmt, 5))
            let tokens = TokenBreakdown(
                input: Int(sqlite3_column_int64(stmt, 3)),
                output: Int(sqlite3_column_int64(stmt, 4)) + reasoning,
                cacheCreate5m: Int(sqlite3_column_int64(stmt, 7)),
                cacheCreate1h: 0,
                cacheRead: Int(sqlite3_column_int64(stmt, 6)),
                reasoning: reasoning
            )
            if tokens.total == 0 { continue }

            let time = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000.0)
            let modelId = text(stmt, 2) ?? "unknown"
            // 订阅登录 opencode 记 cost=0（无真实扣费）→ 按模型等效 API 价兜底；
            // API key 用户 cost>0 用真实值
            let dbCost = sqlite3_column_double(stmt, 8)
            rows.append(MessageRow(
                sessionId: sessionId,
                date: DailyAggregator.dateString(for: time),
                time: time,
                modelId: modelId,
                tokens: tokens,
                cost: dbCost > 0 ? dbCost : UnifiedPricing.cost(tokens, modelId: modelId)
            ))
        }
        return rows
    }

    private static func loadSessions(_ db: OpaquePointer) -> [String: SessionInfo] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, title, parent_id FROM session", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: SessionInfo] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0) else { continue }
            map[id] = SessionInfo(title: text(stmt, 1) ?? "", parentId: text(stmt, 2))
        }
        return map
    }

    /// 沿 parent 链找根会话 id（带环保护；链断/查不到就停在当前节点）
    static func rootSessionId(of id: String, in sessions: [String: SessionInfo]) -> String {
        var cur = id
        var seen: Set<String> = [id]
        while let parent = sessions[cur]?.parentId, !parent.isEmpty, !seen.contains(parent) {
            seen.insert(parent)
            cur = parent
        }
        return cur
    }

    /// 消息行 → 按天聚合的日报（provider 用）
    static func dailyRecords(from messages: [MessageRow], providerId: String) -> [FileDailyRecord] {
        var totals: [String: Int] = [:]
        var cached: [String: Int] = [:]
        for m in messages {
            totals[m.date, default: 0] += m.tokens.total
            cached[m.date, default: 0] += m.tokens.cached
        }
        return totals.map { date, token in
            FileDailyRecord(provider: providerId, date: date, token: token, cachedToken: cached[date] ?? 0)
        }
    }

    /// NULL 安全的 text 列读取（sqlite3_column_text 对 NULL 列返回空指针）
    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }
}

public struct OpenCodeProvider: UsageProvider {
    public let id = "opencode"
    public let displayName = "OpenCode"
    public let iconSymbol = "hammer.fill"
    public let brandColor = "#F59E0B"
    public var family: String? { nil }

    public init() {}

    public func fetchDailyRecords() async throws -> [FileDailyRecord] {
        let path = OpenCodeDB.dbPath
        guard let meta = OpenCodeDB.metadata(dbPath: path) else { return [] }

        if let entry = await FileMtimeCache.shared.lookup(filePath: path, mtime: meta.mtime, size: meta.size) {
            return entry.records
        }
        let records = OpenCodeDB.dailyRecords(from: OpenCodeDB.load(dbPath: path).messages, providerId: id)
        await FileMtimeCache.shared.store(
            FileCacheEntry(filePath: path, mtime: meta.mtime, size: meta.size, records: records))
        return records
    }
}
