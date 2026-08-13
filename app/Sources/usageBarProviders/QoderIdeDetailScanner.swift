import Foundation
import SQLite3
import usageBarCore

/// Qoder IDE 明细扫描器（v0.3.22 新增）。
///
/// **唯一一个数据源是 SQLite 单文件数据库的 provider**（其余都是读 jsonl 文本日志）：
/// `~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db` 的 `chat_message` 表。
/// 主行 `QoderIdeProvider` 只取了 `gmt_create` + `token_info` 两列；详情页多取
/// **`session_id`**（分会话）和 **`model_info`**（分模型）。
///
/// 口径与 `QoderIdeProvider.parseTokenInfoTotal` 逐字对齐（cached 已含在 prompt 里）：
/// - 净输入 = `prompt_tokens − cached_tokens`
/// - 缓存读 = `cached_tokens`
/// - 输出   = `completion_tokens`
/// - **缓存写 = 0**（Qoder 协议不暴露这一列）→ 指标区只有 3 块
/// - total = prompt + completion（与主行完全一致）
///
/// ## 金额是「无价格」档
/// `model_info` 里是 `{"model_key":"qmodel"}` —— **厂商把模型名打码了**。价目表按真实模型 id 索引，
/// `qmodel` 永远查不到（连"这是什么模型"都没人知道，发 issue 补价也没用）。
/// 本地也**没有任何 credit / 配额字段**（2026-07-13 全扫：50 张表的列名 + blob 内容、Electron
/// localStorage、HTTP 缓存、各配置文件，只有 i18n 里的「配额用尽」报错文案）。
/// 服务端的 `/api/v2/quota/usage` 是**账号级**配额，拆不到模型/会话。
/// → 金额位显示 `—`（`CostUnit.unavailable`）。
public actor QoderIdeDetailScanner {
    public static let shared = QoderIdeDetailScanner()
    public init() {}

    struct Row {
        let date: String
        let sessionId: String
        let model: String
        let tokens: TokenBreakdown
        let time: Date
        /// 会话标题（来自 `chat_session.session_title`，LEFT JOIN 取回）
        let title: String?
        /// 工程名（`chat_session.project_name`，标题为空时兜底）
        let project: String?
    }

    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let rows: [Row]
    }

    private var cache: CacheEntry?

    private var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Qoder/SharedClientCache/cache/db/local.db")
            .path
    }

    public func detail(window: TimeWindow, weekStartMonday: Bool = true,
                       now: Date = Date()) async -> ProviderDetail {
        Self.compose(rows: load(), window: window, weekStartMonday: weekStartMonday, now: now)
    }

    /// 全量明细 → 写进持久账本（v0.3.33）。详情页从账本读，SQLite 被清理/锁住也能展开。
    public func allDetails() async -> [FileDetailRecord] {
        load().map { r in
            FileDetailRecord(provider: "qoder-ide", date: r.date, sessionId: r.sessionId,
                             title: (r.title?.isEmpty == false ? r.title! : (r.project ?? "")),
                             model: r.model, lastActivity: r.time, tokens: r.tokens)
        }
    }

    static func compose(rows: [Row], window: TimeWindow,
                        weekStartMonday: Bool, now: Date) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(window, weekStartMonday: weekStartMonday, now: now)

        var total = TokenBreakdown()
        var byModel: [String: TokenBreakdown] = [:]
        var bySession: [String: (tb: TokenBreakdown, last: Date, title: String?, project: String?)] = [:]

        for r in rows where inWindow(r.date) {
            total.add(r.tokens)
            byModel[r.model, default: TokenBreakdown()].add(r.tokens)
            var s = bySession[r.sessionId] ?? (TokenBreakdown(), r.time, r.title, r.project)
            s.tb.add(r.tokens); s.last = max(s.last, r.time)
            s.title = s.title ?? r.title
            s.project = s.project ?? r.project
            bySession[r.sessionId] = s
        }

        // cost 恒 0：模型名被打码，等效美元算不出来（`CostUnit.unavailable` → UI 显示 `—`）
        let models = byModel.map { ModelDetailRecord(modelId: $0.key, tokens: $0.value, cost: 0) }
            .sorted { $0.tokens.total > $1.tokens.total }
        // 标题优先级：会话标题（Qoder IDE 侧栏那个名字）> 工程名 > 兜底
        let sessions = bySession.map { sid, v -> SessionDetailRecord in
            let title = v.title?.isEmpty == false ? v.title!
                      : (v.project?.isEmpty == false ? v.project! : "(无标题会话)")
            return SessionDetailRecord(sessionId: sid, title: title,
                                       subtitle: String(sid.prefix(8)),
                                       lastActivity: v.last, tokens: v.tb, cost: 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        return ProviderDetail(providerId: "qoder-ide", windowId: window.id,
                              tokens: total, cost: 0, models: models, sessions: sessions)
    }

    // MARK: - 读库（按 db + wal 的 mtime 缓存）

    private func load() -> [Row] {
        let path = dbPath
        guard let meta = metadataWithWAL(dbPath: path) else { return [] }
        if let c = cache, c.mtime == meta.mtime, c.size == meta.size { return c.rows }
        let rows = Self.query(dbPath: path)
        cache = CacheEntry(mtime: meta.mtime, size: meta.size, rows: rows)
        return rows
    }

    /// WAL 模式下写入先落 `-wal`，主库 mtime 可能不动 → 必须把 wal 一起算进缓存键。
    private func metadataWithWAL(dbPath: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: dbPath) else { return nil }
        let wal = FileMetadata.read(at: dbPath + "-wal")
        let mtime = max(db.mtime, wal?.mtime ?? .distantPast)
        return (mtime, db.size + (wal?.size ?? 0))
    }

    static func query(dbPath: String) -> [Row] {
        let uri = "file:\(dbPath)?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        // LEFT JOIN chat_session 取会话标题 —— Qoder IDE 把侧栏那个会话名存在 `session_title` 里
        // （样例："你好"），还有 `project_name` 可作兜底。主行 `QoderIdeProvider` 只读 chat_message，
        // 详情页要标题就必须 join（v0.3.22 首版漏了，会话名显示成 sessionId 前缀）。
        // LEFT JOIN 而非 INNER：会话记录可能被清理，不能因此丢掉用量。
        let sql = """
        SELECT m.gmt_create, m.token_info, m.session_id, m.model_info,
               s.session_title, s.project_name
          FROM chat_message AS m
          LEFT JOIN chat_session AS s ON s.session_id = m.session_id
         WHERE m.role='assistant'
           AND m.token_info IS NOT NULL
           AND m.token_info != ''
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let gmtMs = sqlite3_column_int64(stmt, 0)
            guard gmtMs > 0, let tokenC = sqlite3_column_text(stmt, 1) else { continue }
            guard let tb = parseTokenInfo(String(cString: tokenC)) else { continue }

            let sid = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let modelJSON = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let project = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let ts = Date(timeIntervalSince1970: Double(gmtMs) / 1000.0)

            rows.append(Row(date: DailyAggregator.dateString(for: ts),
                            sessionId: sid.isEmpty ? "(未知会话)" : sid,
                            model: parseModelKey(modelJSON),
                            tokens: tb, time: ts,
                            title: title, project: project))
        }
        return rows
    }

    /// `{"prompt_tokens":39005,"completion_tokens":67,"cached_tokens":37485,...}`
    /// → Anthropic 四列（cached 已含在 prompt 里，减掉得净输入）
    static func parseTokenInfo(_ jsonStr: String) -> TokenBreakdown? {
        guard let data = jsonStr.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let prompt = (obj["prompt_tokens"] as? Int) ?? 0
        let completion = (obj["completion_tokens"] as? Int) ?? 0
        let cached = min((obj["cached_tokens"] as? Int) ?? 0, prompt)
        if prompt + completion == 0 { return nil }
        return TokenBreakdown(input: prompt - cached, output: completion,
                              cacheCreate5m: 0, cacheCreate1h: 0, cacheRead: cached)
    }

    /// `{"model_key":"qmodel"}` → `qmodel`。**按已定口径原样显示，不做任何厂商命名美化。**
    static func parseModelKey(_ jsonStr: String) -> String {
        guard let data = jsonStr.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = obj["model_key"] as? String, !key.isEmpty else { return "(未知)" }
        return key
    }
}
