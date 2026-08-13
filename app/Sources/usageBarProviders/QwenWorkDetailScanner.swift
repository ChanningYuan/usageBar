import Foundation
import SQLite3
import usageBarCore

struct QwenWorkSessionMeta: Sendable, Equatable {
    var databaseTitle: String?
    var customTitle: String?
    var aiTitle: String?
    var firstUserText: String?
    var cwd: String?
    var lastActivity: Date = .distantPast

    var resolvedTitle: String {
        databaseTitle
            ?? customTitle
            ?? aiTitle
            ?? firstUserText
            ?? cwd.map { ($0 as NSString).lastPathComponent }
            ?? "(无标题会话)"
    }

    mutating func merge(_ other: QwenWorkSessionMeta) {
        databaseTitle = other.databaseTitle ?? databaseTitle
        customTitle = other.customTitle ?? customTitle
        aiTitle = other.aiTitle ?? aiTitle
        firstUserText = firstUserText ?? other.firstUserText
        cwd = cwd ?? other.cwd
        lastActivity = max(lastActivity, other.lastActivity)
    }
}

/// 千问办公详情扫描器。
///
/// token 仍来自 `QwenWorkSegmentParser`（与主列表完全同源同口径）；会话标题只把
/// `agents.db` / transcript 当元数据补充，绝不从数据库的 context snapshot 取 token。
public actor QwenWorkDetailScanner {
    public static let shared = QwenWorkDetailScanner()

    private let sessionsRoot: URL
    private let projectsRoot: URL
    private let databasePath: String?
    private let billingStore: QwenWorkBillingStore

    private struct MetaCacheEntry {
        let mtime: Date
        let size: Int
        let metas: [String: QwenWorkSessionMeta]
    }

    private var transcriptCache: [String: MetaCacheEntry] = [:]
    private var databaseCache: MetaCacheEntry?

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwenworkcn/logs/sessions"),
        projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwenworkcn/projects"),
        databasePath: String? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenWorkCN/data/agents.db").path,
        billingStore: QwenWorkBillingStore = .shared
    ) {
        self.sessionsRoot = sessionsRoot
        self.projectsRoot = projectsRoot
        self.databasePath = databasePath
        self.billingStore = billingStore
    }

    public func detail(
        window: TimeWindow,
        weekStartMonday: Bool = true,
        now: Date = Date()
    ) async -> ProviderDetail {
        let events = await QwenWorkEventStore.shared.events(under: sessionsRoot)
        let creditHistory = await billingStore.cachedHistory()
        var metas = loadTranscriptMetas()
        for (sessionId, databaseMeta) in loadDatabaseMetas() {
            if var current = metas[sessionId] {
                current.merge(databaseMeta)
                metas[sessionId] = current
            } else {
                metas[sessionId] = databaseMeta
            }
        }
        return Self.compose(
            events: events,
            creditLedger: creditHistory.ledger,
            creditsAvailable: creditHistory.isAvailable,
            metas: metas,
            window: window,
            weekStartMonday: weekStartMonday,
            now: now
        )
    }

    /// 全量 **token 明细** → 写进持久账本（v0.3.33）。
    ///
    /// ⚠️ **不含积分**：千问办公的积分来自联网账单（`/user/billings`）+ 与本地会话按时间区间匹配，
    /// 不是逐条日志自带的数（详见 `QwenWorkBillingStore`）。积分保持原链路实时算，
    /// 账本只存 token —— 否则账单一变（同一会话的账单行金额会原地增长），账本里就是陈旧值。
    public func allDetails() async -> [FileDetailRecord] {
        let events = await QwenWorkEventStore.shared.events(under: sessionsRoot)
        var metas = loadTranscriptMetas()
        for (sessionId, databaseMeta) in loadDatabaseMetas() {
            if var current = metas[sessionId] {
                current.merge(databaseMeta)
                metas[sessionId] = current
            } else {
                metas[sessionId] = databaseMeta
            }
        }
        return events.filter { $0.tokens.total > 0 }.map { e in
            FileDetailRecord(provider: "qwen-work", date: e.date, sessionId: e.sessionId,
                             title: metas[e.sessionId]?.resolvedTitle ?? "",
                             model: e.model, lastActivity: e.timestamp, tokens: e.tokens)
        }
    }

    public func invalidate() async {
        await QwenWorkEventStore.shared.invalidate()
        transcriptCache.removeAll()
        databaseCache = nil
    }

    static func compose(
        events: [QwenWorkUsageEvent],
        creditLedger: [QwenWorkCreditLedgerEntry],
        creditsAvailable: Bool = true,
        metas: [String: QwenWorkSessionMeta],
        window: TimeWindow,
        weekStartMonday: Bool,
        now: Date
    ) -> ProviderDetail {
        let inWindow = DailyAggregator.windowPredicate(
            window, weekStartMonday: weekStartMonday, now: now
        )

        var total = TokenBreakdown()
        var totalCredits = 0.0
        var byModel: [String: TokenBreakdown] = [:]
        var bySession: [String: (tokens: TokenBreakdown, last: Date)] = [:]
        /// 会话时间区间，用来把账单行按时间挂回会话（见 `matchCreditsToSessions`）
        var sessionSpan: [String: (first: Date, last: Date)] = [:]

        // token 统计只算真的记到了量的事件；0-token 事件（gate 开启前）只用于算会话区间。
        for event in events where inWindow(event.date) && event.tokens.total > 0 {
            total.add(event.tokens)
            byModel[event.model, default: TokenBreakdown()].add(event.tokens)
            var session = bySession[event.sessionId] ?? (TokenBreakdown(), event.timestamp)
            session.tokens.add(event.tokens)
            session.last = max(session.last, event.timestamp)
            bySession[event.sessionId] = session
        }
        // 区间用**全量**事件算、不受周期过滤影响：跨周期的会话也要能接住落在本周期内的账单行。
        for event in events {
            var span = sessionSpan[event.sessionId] ?? (event.timestamp, event.timestamp)
            span.first = min(span.first, event.timestamp)
            span.last = max(span.last, event.timestamp)
            sessionSpan[event.sessionId] = span
        }

        // 流水来自服务端真实扣减行的差分，且**已只含 `type == 对话`**（见 `QwenWorkBillingRecord`）。
        let windowLedger = creditLedger.filter {
            inWindow(DailyAggregator.dateString(for: $0.occurredAt))
        }
        for entry in windowLedger { totalCredits += entry.credits }
        let creditsBySession = matchCreditsToSessions(windowLedger, spans: sessionSpan)

        // qwork-ultimate 等是套餐/路由别名，不是真实模型 id，无法诚实折算 API 价格。
        // ⚠️ 模型级积分**永远给 0**：账单没有 model 字段，按 token 占比分摊就是编造（spec §1d）。
        let models = byModel.map {
            ModelDetailRecord(modelId: $0.key, tokens: $0.value, cost: 0)
        }.sorted { $0.tokens.total > $1.tokens.total }

        // ⚠️ 会话集合取 token 与积分的**并集**：gate 开启前的会话 token 为 0 却真花了积分，
        // 只按 token 列会话的话，那笔钱就凭空消失 → Hero 总额和「按会话」之和对不上（0804 踩过）。
        let sessionIds = Set(bySession.keys).union(creditsBySession.keys)
        let sessions = sessionIds.map { sessionId -> SessionDetailRecord in
            let meta = metas[sessionId]
            let value = bySession[sessionId]
            return SessionDetailRecord(
                sessionId: sessionId,
                title: meta?.resolvedTitle ?? "(无标题会话)",
                subtitle: String(sessionId.prefix(8)),
                lastActivity: max(value?.last ?? .distantPast, meta?.lastActivity ?? .distantPast),
                tokens: value?.tokens ?? TokenBreakdown(),
                cost: creditsBySession[sessionId] ?? 0
            )
        }.sorted {
            // token 相同（如都是 0）时按积分降序，别让「只有积分」的会话随机排
            $0.tokens.total != $1.tokens.total
                ? $0.tokens.total > $1.tokens.total
                : $0.cost > $1.cost
        }

        return ProviderDetail(
            providerId: "qwen-work",
            windowId: window.id,
            tokens: total,
            cost: totalCredits,
            costAvailable: creditsAvailable,
            models: models,
            sessions: sessions
        )
    }

    // MARK: - 积分归因到会话（时间匹配）

    /// 把账单流水挂回本地会话。
    ///
    /// **为什么只能按时间匹配**：本地日志有 session_id（目录名），但服务端账单行**一个 ID 都没有**
    /// ——字段只有 amount / created_at / detail.title / granularity / source / type。
    /// 佐证：官方「已使用」页的详情列全是「桌面端任务」，官方自己也拿不出会话名。
    /// 两边没有公共键，只能拿时间对。详见 spec §1d。
    ///
    /// 匹配规则（顺序即优先级）：
    /// 1. 账单时间落在某会话的 `[首个请求, 末个请求]` 区间内 → 归它；
    /// 2. 否则取最近邻，且间隔 ≤ `matchTolerance`（2 分钟，覆盖"扣费落库晚于末个请求"的常见情况）；
    /// 3. 都不中 → **不归任何会话**。
    ///
    /// ⚠️ 匹配不中的钱**不会消失**：周期总额（Hero 的积分）始终按全部流水算，与本函数无关。
    /// 所以「各会话积分之和 ≤ 周期总额」，差额就是没匹配上的部分——宁可某行不挂，也不要挂错会话。
    static let matchTolerance: TimeInterval = 120

    static func matchCreditsToSessions(
        _ ledger: [QwenWorkCreditLedgerEntry],
        spans: [String: (first: Date, last: Date)]
    ) -> [String: Double] {
        guard !spans.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        for entry in ledger {
            let at = entry.occurredAt
            // 区间命中优先；同一时刻被多个会话区间覆盖时取区间更短的那个（更"贴身"的会话）
            let containing = spans
                .filter { $0.value.first <= at && at <= $0.value.last }
                .min { lhs, rhs in
                    lhs.value.last.timeIntervalSince(lhs.value.first)
                        < rhs.value.last.timeIntervalSince(rhs.value.first)
                }
            if let hit = containing {
                result[hit.key, default: 0] += entry.credits
                continue
            }
            let nearest = spans
                .map { ($0.key, min(abs($0.value.first.timeIntervalSince(at)),
                                    abs($0.value.last.timeIntervalSince(at)))) }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 <= matchTolerance {
                result[nearest.0, default: 0] += entry.credits
            }
        }
        return result
    }

    // MARK: - 会话标题：transcript fallback

    private func loadTranscriptMetas() -> [String: QwenWorkSessionMeta] {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [:] }
        let files = JSONLReader.findFiles(under: projectsRoot) { $0.pathExtension == "jsonl" }
        var result: [String: QwenWorkSessionMeta] = [:]

        for url in files {
            let path = url.path
            guard let fileMeta = FileMetadata.read(at: path) else { continue }
            let parsed: [String: QwenWorkSessionMeta]
            if let cached = transcriptCache[path],
               cached.mtime == fileMeta.mtime, cached.size == fileMeta.size {
                parsed = cached.metas
            } else {
                parsed = Self.parseTranscriptMeta(url: url)
                transcriptCache[path] = MetaCacheEntry(
                    mtime: fileMeta.mtime, size: fileMeta.size, metas: parsed
                )
            }

            for (sessionId, meta) in parsed {
                if var current = result[sessionId] {
                    current.merge(meta)
                    result[sessionId] = current
                } else {
                    result[sessionId] = meta
                }
            }
        }
        return result
    }

    static func parseTranscriptMeta(url: URL) -> [String: QwenWorkSessionMeta] {
        var metas: [String: QwenWorkSessionMeta] = [:]
        try? JSONLReader.forEachLine(at: url) { obj in
            guard let sessionId = (obj["sessionId"] as? String)
                    ?? (obj["session_id"] as? String),
                  !sessionId.isEmpty
            else { return }

            let timestamp = (obj["timestamp"] as? String).flatMap(ISODateParser.parse)
            var meta = metas[sessionId] ?? QwenWorkSessionMeta()
            if let timestamp { meta.lastActivity = max(meta.lastActivity, timestamp) }
            if meta.cwd == nil { meta.cwd = obj["cwd"] as? String }

            switch obj["type"] as? String {
            case "custom-title":
                if let title = nonEmpty(obj["customTitle"] as? String) {
                    meta.customTitle = title
                }
            case "ai-title":
                if let title = nonEmpty(obj["aiTitle"] as? String) {
                    meta.aiTitle = title
                }
            case "user":
                if meta.firstUserText == nil,
                   (obj["isMeta"] as? Bool) != true,
                   (obj["isSidechain"] as? Bool) != true,
                   let message = obj["message"] as? [String: Any] {
                    meta.firstUserText = plainUserText(message["content"])
                }
            default:
                break
            }
            metas[sessionId] = meta
        }
        return metas
    }

    private static func plainUserText(_ content: Any?) -> String? {
        func clean(_ value: String) -> String? {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
            return String(text.prefix(80))
        }

        if let value = content as? String { return clean(value) }
        if let parts = content as? [[String: Any]] {
            for part in parts where (part["type"] as? String) == "text" {
                if let value = part["text"] as? String, let text = clean(value) {
                    return text
                }
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 会话标题：agents.db（侧栏真实标题，最高优先级）

    private func loadDatabaseMetas() -> [String: QwenWorkSessionMeta] {
        guard let databasePath, let meta = databaseMetadata(path: databasePath) else { return [:] }
        if let cached = databaseCache,
           cached.mtime == meta.mtime, cached.size == meta.size {
            return cached.metas
        }
        let parsed = Self.queryDatabaseMetas(path: databasePath)
        databaseCache = MetaCacheEntry(mtime: meta.mtime, size: meta.size, metas: parsed)
        return parsed
    }

    private func databaseMetadata(path: String) -> (mtime: Date, size: Int)? {
        guard let db = FileMetadata.read(at: path) else { return nil }
        let wal = FileMetadata.read(at: path + "-wal")
        return (
            max(db.mtime, wal?.mtime ?? .distantPast),
            db.size + (wal?.size ?? 0)
        )
    }

    static func queryDatabaseMetas(path: String) -> [String: QwenWorkSessionMeta] {
        let uri = "file:\(path)?mode=ro"
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT s.session_id,
               COALESCE(NULLIF(s.name, ''), NULLIF(c.name, '')),
               s.updated_at
          FROM sub_chats AS s
          LEFT JOIN chats AS c ON c.id = s.chat_id
         WHERE s.session_id IS NOT NULL
           AND s.session_id != ''
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: QwenWorkSessionMeta] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionChars = sqlite3_column_text(statement, 0) else { continue }
            let sessionId = String(cString: sessionChars)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let rawTimestamp = sqlite3_column_int64(statement, 2)
            let seconds = rawTimestamp > 10_000_000_000
                ? Double(rawTimestamp) / 1000.0
                : Double(rawTimestamp)
            result[sessionId] = QwenWorkSessionMeta(
                databaseTitle: nonEmpty(title),
                lastActivity: seconds > 0
                    ? Date(timeIntervalSince1970: seconds)
                    : .distantPast
            )
        }
        return result
    }
}
